[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$modulePath = Join-Path $repositoryRoot 'src\StableDiffusionWorkbench.Core.psm1'
$script:Passed = 0

function Assert-SdwTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw "TEST FAILED: $Message" }
    $script:Passed++
    Write-Host ("PASS {0,2}: {1}" -f $script:Passed, $Message)
}

function Remove-SdwTestRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $parent = [IO.Path]::GetFullPath((Split-Path -Parent $full)).TrimEnd('\', '/')
    $leaf = Split-Path -Leaf $full
    if (-not $parent.Equals($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^sdw-tests-[0-9a-f]{32}$') {
        throw "Refusing to remove an unexpected test path: $full"
    }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}

Write-Host 'Stable Diffusion Workbench local test suite'
Write-Host ("PowerShell {0}; repository {1}" -f $PSVersionTable.PSVersion, $repositoryRoot)

$parseErrors = New-Object Collections.Generic.List[object]
$powerShellFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File | Where-Object {
    $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1'
})
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($errorRecord in $errors) {
        $parseErrors.Add(('{0}:{1}: {2}' -f $file.FullName, $errorRecord.Extent.StartLineNumber, $errorRecord.Message))
    }
}
Assert-SdwTest ($parseErrors.Count -eq 0) 'all PowerShell files parse without errors'

$jsonFiles = @(
    'configs\upstream-lock.json',
    'profiles\windows-nvidia-standard.json',
    'profiles\windows-nvidia-blackwell.json',
    'asset-manifests\starter-models.json'
)
$json = @{}
foreach ($relative in $jsonFiles) {
    $fullPath = Join-Path $repositoryRoot $relative
    $json[$relative] = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
Assert-SdwTest ($json.Count -eq $jsonFiles.Count) 'all locked manifests parse as JSON'

$lock = $json['configs\upstream-lock.json']
$standard = $json['profiles\windows-nvidia-standard.json']
$blackwell = $json['profiles\windows-nvidia-blackwell.json']
$starter = @($json['asset-manifests\starter-models.json'].assets)[0]
Assert-SdwTest ($standard.upstreamCommit -match '^[0-9a-f]{40}$' -and $blackwell.upstreamCommit -match '^[0-9a-f]{40}$') 'profiles use full Git commit locks'
Assert-SdwTest ($lock.upstream.profiles.'windows-nvidia-standard'.commit -eq $standard.upstreamCommit -and
    $lock.upstream.profiles.'windows-nvidia-blackwell'.commit -eq $blackwell.upstreamCommit) 'profile commits match the upstream lock'
Assert-SdwTest ($lock.portable.sha256 -match '^[0-9A-Fa-f]{64}$' -and [Int64]$lock.portable.sizeBytes -gt 0) 'portable runtime has size and SHA-256 integrity locks'
Assert-SdwTest ($starter.sha256 -match '^[0-9a-f]{64}$' -and [Int64]$starter.sizeBytes -gt 0 -and
    [string]$starter.license.url -match '^https://') 'starter model records integrity and license metadata'
Assert-SdwTest (@($standard.launchArgs).Count -eq 0 -and @($blackwell.launchArgs).Count -eq 0) 'profiles cannot override launcher-owned network or data arguments'

Import-Module -Name $modulePath -Force -ErrorAction Stop
Assert-SdwTest ($null -ne (Get-Command Get-SdwSummary -ErrorAction SilentlyContinue)) 'core module imports under the active PowerShell runtime'

$quotedValues = @('path with spaces', '中文路径', 'quote"inside', 'trailing\')
$echoFixture = Join-Path $PSScriptRoot 'fixtures\echo-arguments.ps1'
$powerShellExecutable = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf)) {
    $powerShellExecutable = (Get-Process -Id $PID).Path
}
$echoResult = Invoke-SdwNativeCommand -FilePath $powerShellExecutable -Arguments (@(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $echoFixture
) + $quotedValues) -WorkingDirectory $repositoryRoot
$echoValues = @(($echoResult.StandardOutput.Trim() | ConvertFrom-Json).values)
Assert-SdwTest (($echoValues -join "`n") -ceq ($quotedValues -join "`n")) 'native command quoting preserves spaces, Unicode, quotes, and trailing slashes'

$readOnlyRoot = Join-Path ([IO.Path]::GetTempPath()) ('sdw-tests-' + [Guid]::NewGuid().ToString('N'))
try {
    $summary = Get-SdwSummary -RepositoryRoot $repositoryRoot -DataRoot $readOnlyRoot
    Assert-SdwTest ($summary.status -eq 'notInstalled' -and -not $summary.installed) 'status reports an uninstalled runtime without failing'
    Assert-SdwTest (-not (Test-Path -LiteralPath $readOnlyRoot)) 'status is read-only for a nonexistent data root'
    $doctor = Invoke-SdwDoctor -RepositoryRoot $repositoryRoot -DataRoot $readOnlyRoot
    Assert-SdwTest ($doctor.failCount -ge 1 -and @($doctor.checks).Count -ge 5) 'doctor returns structured checks for an uninstalled runtime'
    Assert-SdwTest (-not (Test-Path -LiteralPath $readOnlyRoot)) 'doctor is read-only for a nonexistent data root'
}
finally {
    Remove-SdwTestRoot -Path $readOnlyRoot
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sdw-tests-' + [Guid]::NewGuid().ToString('N'))
$ownedProcess = $null
try {
    $configuration = Set-SdwConfiguration -RepositoryRoot $repositoryRoot -DataRoot $testRoot -Port 17860 -ProfileId 'windows-nvidia-standard'
    $paths = Get-SdwPaths -RepositoryRoot $repositoryRoot -DataRoot $testRoot
    $roundTrip = Get-SdwConfiguration -Paths $paths
    Assert-SdwTest ([int]$roundTrip.port -eq 17860 -and $roundTrip.profileId -eq 'windows-nvidia-standard') 'configuration writes atomically and round-trips'

    $invalidModel = Join-Path $testRoot 'not-a-model.ckpt'
    [IO.File]::WriteAllBytes($invalidModel, [byte[]](1, 2, 3))
    $invalidRejected = $false
    try { $null = Import-SdwModel -Path $invalidModel -RepositoryRoot $repositoryRoot -DataRoot $testRoot }
    catch { $invalidRejected = $_.Exception.Message -match 'safetensors' }
    Assert-SdwTest ($invalidRejected -and (Test-Path -LiteralPath $invalidModel -PathType Leaf)) 'model import rejects .ckpt without moving the source'

    $sourceModel = Join-Path $testRoot '测试 model.safetensors'
    [IO.File]::WriteAllBytes($sourceModel, [byte[]](10, 20, 30, 40, 50))
    $importItems = @(Import-SdwModel -Path $sourceModel -RepositoryRoot $repositoryRoot -DataRoot $testRoot)
    $imported = @($importItems | Where-Object { $_ -isnot [string] })[-1]
    Assert-SdwTest ($imported.imported -and (Test-Path -LiteralPath $imported.path -PathType Leaf)) 'model import copies a .safetensors file into managed storage'
    $secondImportItems = @(Import-SdwModel -Path $sourceModel -RepositoryRoot $repositoryRoot -DataRoot $testRoot)
    $secondImport = @($secondImportItems | Where-Object { $_ -isnot [string] })[-1]
    Assert-SdwTest (-not $secondImport.imported -and $secondImport.sha256 -eq $imported.sha256) 'model import is idempotent for identical content'

    $licenseRejected = $false
    try { $null = Install-SdwStarterModel -RepositoryRoot $repositoryRoot -DataRoot $testRoot }
    catch { $licenseRejected = $_.Exception.Message -match 'AcceptLicense' }
    Assert-SdwTest $licenseRejected 'starter-model download requires explicit license acceptance'

    $ownerToken = [Guid]::NewGuid().ToString('D')
    $sleepFixture = Join-Path $PSScriptRoot 'fixtures\sleep-owned.ps1'
    $processInfo = New-Object Diagnostics.ProcessStartInfo
    $processInfo.FileName = $powerShellExecutable
    $processInfo.Arguments = Join-SdwCommandLine -Arguments @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sleepFixture, '-OwnerToken', $ownerToken
    )
    $processInfo.WorkingDirectory = $repositoryRoot
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $ownedProcess = New-Object Diagnostics.Process
    $ownedProcess.StartInfo = $processInfo
    Assert-SdwTest ($ownedProcess.Start()) 'ownership fixture process starts'
    Start-Sleep -Milliseconds 350
    $ownedState = [pscustomobject]@{
        supervisorPid = $ownedProcess.Id
        supervisorStartedAtUtc = $ownedProcess.StartTime.ToUniversalTime().ToString('o')
        ownerToken = $ownerToken
        supervisorPath = $sleepFixture
    }
    Assert-SdwTest (Test-SdwProcessOwnership -State $ownedState) 'process ownership accepts matching PID, start time, and owner token'
    $ownedState.ownerToken = [Guid]::NewGuid().ToString('D')
    Assert-SdwTest (-not (Test-SdwProcessOwnership -State $ownedState)) 'process ownership rejects a mismatched owner token'
}
finally {
    if ($null -ne $ownedProcess) {
        try {
            if (-not $ownedProcess.HasExited) { Stop-Process -Id $ownedProcess.Id -Force -ErrorAction SilentlyContinue }
        }
        finally { $ownedProcess.Dispose() }
    }
    Remove-SdwTestRoot -Path $testRoot
}

$supervisorSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'scripts\supervisor.ps1') -Raw -Encoding UTF8
Assert-SdwTest ($supervisorSource -match "'--api'" -and $supervisorSource -match "'--api-server-stop'" -and
    $supervisorSource -match "'--server-name', '127\.0\.0\.1'" -and $supervisorSource -match "'--no-download-sd-model'") 'supervisor owns API, loopback, stop, and no-implicit-model arguments'
Assert-SdwTest ($supervisorSource -match 'Ensure-SdwUiSettings' -and
    $supervisorSource -match "'sd_model_checkpoint',\s*'sd_vae'") 'supervisor exposes checkpoint and VAE selectors without requiring manual A1111 settings'

$entrypoint = Get-Content -LiteralPath (Join-Path $repositoryRoot 'Start Stable Diffusion.cmd') -Raw -Encoding UTF8
Assert-SdwTest ($entrypoint -match '(?i)start\s+"".*powershell' -and $entrypoint -match '(?i)-WindowStyle\s+Hidden') 'double-click entry point launches the GUI without a lingering console'

$launcherSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'launcher\StableDiffusionWorkbench.ps1') -Raw -Encoding UTF8
Assert-SdwTest ($launcherSource -match 'Show-SdwSettingsDialog\s+-InstallMode' -and
    $launcherSource -match '(?s)Queue-SdwAction\s+-Command\s+''setup''.*?DataRoot\s*=\s*\$selectedRoot' -and
    $launcherSource -match '\$Command\s+-eq\s+''setup''\s+-or\s+\$Command\s+-eq\s+''repair''') 'first install requires an explicitly confirmed data root'
Assert-SdwTest ($launcherSource -match 'Test-SdwLauncherPathEncrypted' -and
    $launcherSource -match 'Windows EFS') 'launcher rejects an EFS-encrypted install destination before setup'
Assert-SdwTest ($launcherSource -match '\$actionGroup\.Text\s*=\s*if\s*\(\$busy\)') 'launcher visibly explains the locked action state during a long-running task'
Assert-SdwTest ($launcherSource -match 'Join-Path\s+\$script:RepositoryRoot\s+''data''' -and
    $launcherSource -match '\$settingsButton\s*=\s*New-SdwButton' -and
    $launcherSource -match '\$settingsButton\.Add_Click') 'launcher defaults to a portable git-ignored data directory and exposes a path picker'
Assert-SdwTest ($launcherSource -match '\$startButton\.Enabled\s*=\s*\$true' -and
    $launcherSource -match '\$stopButton\.Enabled\s*=\s*\$true' -and
    $launcherSource -match '\$openUiButton\.Enabled\s*=\s*\$true') 'primary lifecycle controls remain clickable and explain unmet prerequisites'
Assert-SdwTest ($launcherSource -match '\$importButton\.Enabled\s*=\s*\$true' -and
    $launcherSource -match '\$downloadButton\.Enabled\s*=\s*\$true') 'model add and base-model download controls remain clickable'
Assert-SdwTest ($launcherSource -match 'OpenUiAfterStart' -and
    $launcherSource -match "(?s)function\s+Invoke-SdwOpenUiFromUi.*?Queue-SdwAction\s+-Command\s+'start'") 'open WebUI can start a ready backend before opening the browser'

$bootstrapSources = @(
    (Get-Content -LiteralPath (Join-Path $repositoryRoot 'Start Stable Diffusion.cmd') -Raw -Encoding UTF8),
    (Get-Content -LiteralPath (Join-Path $repositoryRoot 'scripts\sdw.ps1') -Raw -Encoding UTF8),
    (Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\StableDiffusionWorkbench.Core.psm1') -Raw -Encoding UTF8)
) -join "`n"
Assert-SdwTest ($bootstrapSources -notmatch '(?im)\bsetx(?:\.exe)?\b|\[Environment\]::SetEnvironmentVariable\s*\(') 'bootstrap never writes user or machine environment variables'
Assert-SdwTest ($entrypoint -notmatch '(?im)\bpython(?:3|\.exe)?\b|\bpip(?:\.exe)?\b|\bgit(?:\.exe)?\b') 'double-click entry point has no dependency on system Python, pip, or Git'

Write-Host ("All {0} tests passed." -f $script:Passed) -ForegroundColor Green
