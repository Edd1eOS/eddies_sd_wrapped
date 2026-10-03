[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('setup', 'repair', 'start', 'stop', 'status', 'doctor', 'configure', 'import-model', 'download-starter-model', 'open-ui', 'open-data', 'open-models', 'open-outputs', 'logs', 'training-setup', 'training-open', 'training-stop', 'training-status', 'training-data', 'training-output', 'training-logs')]
    [string]$Command,
    [string]$DataRoot,
    [ValidateRange(0, 65535)][int]$Port = 0,
    [string]$ProfileId,
    [string]$Path,
    [switch]$AcceptLicense,
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
try { [Console]::InputEncoding = $utf8 } catch { }
$OutputEncoding = $utf8

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$modulePath = Join-Path $repositoryRoot 'src\StableDiffusionWorkbench.Core.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

function Write-HumanResult {
    param([object[]]$Items)
    foreach ($item in $Items) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) { [Console]::Out.WriteLine($item); continue }
        if ($item.PSObject.Properties['status'] -and $item.PSObject.Properties['message']) {
            [Console]::Out.WriteLine(('[{0}] {1}' -f $item.status, $item.message))
            if ($item.PSObject.Properties['url'] -and -not [string]::IsNullOrWhiteSpace([string]$item.url)) { [Console]::Out.WriteLine(('URL: {0}' -f $item.url)) }
            continue
        }
        if ($item.PSObject.Properties['versionPath']) {
            [Console]::Out.WriteLine(('Active runtime: {0}' -f $item.versionPath))
            continue
        }
        if ($item.PSObject.Properties['path']) {
            [Console]::Out.WriteLine(('Path: {0}' -f $item.path))
            continue
        }
        [Console]::Out.WriteLine(($item | Out-String).TrimEnd())
    }
}

try {
    if ($Command.StartsWith('training-')) {
        & (Join-Path $PSScriptRoot 'training.ps1') -Command $Command -DataRoot $DataRoot -ProfileId $ProfileId -Json:$Json
        exit $LASTEXITCODE
    }
    switch ($Command) {
        'setup' {
            if ($Json) {
                $items = @(Invoke-SdwSetup -RepositoryRoot $repositoryRoot -DataRoot $DataRoot -ProfileId $ProfileId)
                ($items | Where-Object { $_ -isnot [string] } | Select-Object -Last 1) | ConvertTo-Json -Depth 12 -Compress
            }
            else { Invoke-SdwSetup -RepositoryRoot $repositoryRoot -DataRoot $DataRoot -ProfileId $ProfileId | ForEach-Object { Write-HumanResult -Items @($_) } }
        }
        'repair' {
            if ($Json) {
                $items = @(Invoke-SdwSetup -RepositoryRoot $repositoryRoot -DataRoot $DataRoot -ProfileId $ProfileId -Repair)
                ($items | Where-Object { $_ -isnot [string] } | Select-Object -Last 1) | ConvertTo-Json -Depth 12 -Compress
            }
            else { Invoke-SdwSetup -RepositoryRoot $repositoryRoot -DataRoot $DataRoot -ProfileId $ProfileId -Repair | ForEach-Object { Write-HumanResult -Items @($_) } }
        }
        'start' {
            if ($Json) {
                $items = @(Invoke-SdwStart -RepositoryRoot $repositoryRoot -DataRoot $DataRoot -Port $Port)
                ($items | Where-Object { $_ -isnot [string] } | Select-Object -Last 1) | ConvertTo-Json -Depth 12 -Compress
            }
            else { Invoke-SdwStart -RepositoryRoot $repositoryRoot -DataRoot $DataRoot -Port $Port | ForEach-Object { Write-HumanResult -Items @($_) } }
        }
        'stop' {
            $items = @(Invoke-SdwStop -RepositoryRoot $repositoryRoot -DataRoot $DataRoot)
            if ($Json) { (Get-SdwSummary -RepositoryRoot $repositoryRoot -DataRoot $DataRoot -Port $Port) | ConvertTo-Json -Depth 12 -Compress }
            else { Write-HumanResult -Items $items }
        }
        'status' {
            $summary = Get-SdwSummary -RepositoryRoot $repositoryRoot -DataRoot $DataRoot -Port $Port -ProfileId $ProfileId
            if ($Json) { $summary | ConvertTo-Json -Depth 12 -Compress }
            else { Write-HumanResult -Items @($summary) }
        }
        'doctor' {
            $doctor = Invoke-SdwDoctor -RepositoryRoot $repositoryRoot -DataRoot $DataRoot -Port $Port -ProfileId $ProfileId
            if ($Json) { $doctor | ConvertTo-Json -Depth 12 -Compress }
            else {
                foreach ($check in $doctor.checks) {
                    [Console]::Out.WriteLine(('[{0}] {1}: {2}' -f $check.status.ToUpperInvariant(), $check.id, $check.message))
                    if (-not [string]::IsNullOrWhiteSpace([string]$check.fix) -and $check.status -ne 'pass') { [Console]::Out.WriteLine(('  Fix: {0}' -f $check.fix)) }
                }
                [Console]::Out.WriteLine(('Doctor result: {0} failure(s), {1} warning(s).' -f $doctor.failCount, $doctor.warningCount))
            }
        }
        'configure' {
            $configuration = Set-SdwConfiguration -RepositoryRoot $repositoryRoot -DataRoot $DataRoot -Port $Port -ProfileId $ProfileId
            if ($Json) { $configuration | ConvertTo-Json -Depth 12 -Compress }
            else {
                [Console]::Out.WriteLine(('Configuration saved under {0}' -f $configuration.dataRoot))
                [Console]::Out.WriteLine(('Port: {0}; profile: {1}' -f $configuration.port, $configuration.profileId))
            }
        }
        'import-model' {
            if ([string]::IsNullOrWhiteSpace($Path)) { throw (New-SdwException -Message 'import-model requires -Path <checkpoint.safetensors>.' -ExitCode 2) }
            if ($Json) {
                $items = @(Import-SdwModel -Path $Path -RepositoryRoot $repositoryRoot -DataRoot $DataRoot)
                ($items | Where-Object { $_ -isnot [string] } | Select-Object -Last 1) | ConvertTo-Json -Depth 12 -Compress
            }
            else { Import-SdwModel -Path $Path -RepositoryRoot $repositoryRoot -DataRoot $DataRoot | ForEach-Object { Write-HumanResult -Items @($_) } }
        }
        'download-starter-model' {
            if ($Json) {
                $items = @(Install-SdwStarterModel -RepositoryRoot $repositoryRoot -DataRoot $DataRoot -AcceptLicense:$AcceptLicense)
                ($items | Where-Object { $_ -isnot [string] } | Select-Object -Last 1) | ConvertTo-Json -Depth 12 -Compress
            }
            else { Install-SdwStarterModel -RepositoryRoot $repositoryRoot -DataRoot $DataRoot -AcceptLicense:$AcceptLicense | ForEach-Object { Write-HumanResult -Items @($_) } }
        }
        'open-ui' { $null = Open-SdwLocation -Target ui -RepositoryRoot $repositoryRoot -DataRoot $DataRoot; [Console]::Out.WriteLine('Opened WebUI in the default browser.') }
        'open-data' { $opened = Open-SdwLocation -Target data -RepositoryRoot $repositoryRoot -DataRoot $DataRoot; [Console]::Out.WriteLine(('Opened: {0}' -f $opened)) }
        'open-models' { $opened = Open-SdwLocation -Target models -RepositoryRoot $repositoryRoot -DataRoot $DataRoot; [Console]::Out.WriteLine(('Opened: {0}' -f $opened)) }
        'open-outputs' { $opened = Open-SdwLocation -Target outputs -RepositoryRoot $repositoryRoot -DataRoot $DataRoot; [Console]::Out.WriteLine(('Opened: {0}' -f $opened)) }
        'logs' {
            $text = Get-SdwLogs -RepositoryRoot $repositoryRoot -DataRoot $DataRoot
            if ($Json) { [pscustomobject]@{ logs = $text } | ConvertTo-Json -Compress }
            else { [Console]::Out.WriteLine($text) }
        }
    }
    exit 0
}
catch {
    $code = Get-SdwExitCode -Exception $_.Exception
    if ($Json) {
        [pscustomobject][ordered]@{ ok = $false; exitCode = $code; error = $_.Exception.Message } | ConvertTo-Json -Compress
    }
    else {
        [Console]::Error.WriteLine(('ERROR [{0}]: {1}' -f $code, $_.Exception.Message))
    }
    exit $code
}
