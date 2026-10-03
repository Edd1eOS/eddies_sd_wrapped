[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DataRoot,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$VersionPath,
    [Parameter(Mandatory = $true)][string]$CheckoutPath,
    [Parameter(Mandatory = $true)][string]$PythonPath,
    [Parameter(Mandatory = $true)][string]$GitPath,
    [Parameter(Mandatory = $true)][string]$ProfileId,
    [Parameter(Mandatory = $true)][string]$UpstreamCommit,
    [Parameter(Mandatory = $true)][ValidateRange(1024, 65535)][int]$Port,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$OwnerToken,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$TorchCommand,
    [string]$LaunchArgsBase64 = 'W10='
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-SupervisorArgument {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    $null = $builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $backslashes++; continue }
        if ($character -eq '"') {
            if ($backslashes -gt 0) { $null = $builder.Append(('\' * ($backslashes * 2))) }
            $null = $builder.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { $null = $builder.Append(('\' * $backslashes)); $backslashes = 0 }
        $null = $builder.Append($character)
    }
    if ($backslashes -gt 0) { $null = $builder.Append(('\' * ($backslashes * 2))) }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Write-StateAtomic {
    param([Parameter(Mandatory = $true)]$Value)
    $directory = Split-Path -Parent $StatePath
    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    $temporary = Join-Path $directory ('.runtime.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    $backup = Join-Path $directory ('.runtime.{0}.bak' -f [Guid]::NewGuid().ToString('N'))
    $encoding = New-Object Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12), $encoding)
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            try {
                [IO.File]::Replace($temporary, $StatePath, $backup, $true)
                if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
            }
            catch { Move-Item -LiteralPath $temporary -Destination $StatePath -Force }
        }
        else { Move-Item -LiteralPath $temporary -Destination $StatePath }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
}

function Ensure-SdwUiSettings {
    param([Parameter(Mandatory = $true)][string]$UserDataRoot, [string]$OutputsRoot, [switch]$DirectML)

    $settingsPath = Join-Path $UserDataRoot 'config.json'
    $settings = New-Object PSObject
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        }
        catch {
            throw "Unable to read A1111 UI settings: $($_.Exception.Message)"
        }
    }

    # Localized Windows / integrated adapters can fail PDH memory queries.
    # Prefer the upstream non-PDH provider for a new DirectML configuration.
    if ($DirectML -and $null -eq $settings.PSObject.Properties['directml_memory_provider']) {
        $settings | Add-Member -NotePropertyName 'directml_memory_provider' -NotePropertyValue 'None'
    }
    $quickSettings = @()
    $property = $settings.PSObject.Properties['quicksettings_list']
    if ($null -ne $property) {
        if ($property.Value -is [string]) {
            $quickSettings = @([string]$property.Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        else {
            $quickSettings = @($property.Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }
    foreach ($requiredSetting in @('sd_model_checkpoint', 'sd_vae')) {
        if ($quickSettings -notcontains $requiredSetting) {
            $quickSettings += $requiredSetting
        }
    }
    if ($null -eq $property) {
        $settings | Add-Member -NotePropertyName 'quicksettings_list' -NotePropertyValue $quickSettings
    }
    else {
        $settings.quicksettings_list = $quickSettings
    }

    if ($OutputsRoot) {
        foreach ($entry in @{ outdir_txt2img_samples='txt2img-images'; outdir_img2img_samples='img2img-images'; outdir_extras_samples='extras-images'; outdir_txt2img_grids='txt2img-grids'; outdir_img2img_grids='img2img-grids'; outdir_save='saved' }.GetEnumerator()) {
            $existing = $settings.PSObject.Properties[$entry.Key]
            if ($null -eq $existing -or [string]::IsNullOrWhiteSpace([string]$existing.Value) -or -not [IO.Path]::IsPathRooted([string]$existing.Value)) {
                $settings | Add-Member -NotePropertyName $entry.Key -NotePropertyValue (Join-Path $OutputsRoot $entry.Value) -Force
            }
        }
    }
    $temporaryPath = Join-Path $UserDataRoot ('.config.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    $backupPath = Join-Path $UserDataRoot ('.config.{0}.bak' -f [Guid]::NewGuid().ToString('N'))
    $encoding = New-Object Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($temporaryPath, ($settings | ConvertTo-Json -Depth 100), $encoding)
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            try {
                [IO.File]::Replace($temporaryPath, $settingsPath, $backupPath, $true)
                if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
            }
            catch {
                Move-Item -LiteralPath $temporaryPath -Destination $settingsPath -Force
            }
        }
        else {
            [IO.File]::Move($temporaryPath, $settingsPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
    }
}

function Write-LogLine {
    param([string]$Line, [string]$Stream = 'stdout')
    $stamp = [DateTime]::UtcNow.ToString('o')
    $text = '[{0}] [{1}] {2}' -f $stamp, $Stream, $Line
    $script:LogWriter.WriteLine($text)
    $script:LogWriter.Flush()
}

function Test-ChildPath {
    param([string]$Parent, [string]$Child)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $childFull = [IO.Path]::GetFullPath($Child)
    return $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)
}

$DataRoot = [IO.Path]::GetFullPath($DataRoot)
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$VersionPath = [IO.Path]::GetFullPath($VersionPath)
$CheckoutPath = [IO.Path]::GetFullPath($CheckoutPath)
$PythonPath = [IO.Path]::GetFullPath($PythonPath)
$GitPath = [IO.Path]::GetFullPath($GitPath)
$LogPath = [IO.Path]::GetFullPath($LogPath)
$StatePath = [IO.Path]::GetFullPath($StatePath)

if (-not (Test-ChildPath -Parent $DataRoot -Child $VersionPath)) { throw 'VersionPath must be inside DataRoot.' }
if (-not (Test-ChildPath -Parent $VersionPath -Child $CheckoutPath)) { throw 'CheckoutPath must be inside VersionPath.' }
if (-not (Test-ChildPath -Parent $VersionPath -Child $PythonPath)) { throw 'PythonPath must be inside VersionPath.' }
if (-not (Test-ChildPath -Parent $VersionPath -Child $GitPath)) { throw 'GitPath must be inside VersionPath.' }
if (-not (Test-ChildPath -Parent $DataRoot -Child $LogPath)) { throw 'LogPath must be inside DataRoot.' }
if (-not (Test-ChildPath -Parent $DataRoot -Child $StatePath)) { throw 'StatePath must be inside DataRoot.' }
if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) { throw "Bundled Python was not found: $PythonPath" }
if (-not (Test-Path -LiteralPath $GitPath -PathType Leaf)) { throw "Bundled Git was not found: $GitPath" }
if (-not (Test-Path -LiteralPath (Join-Path $CheckoutPath 'launch.py') -PathType Leaf)) { throw "A1111 launch.py was not found: $CheckoutPath" }

try {
    $launchArgsJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($LaunchArgsBase64))
    $decodedArguments = $launchArgsJson | ConvertFrom-Json
    $profileArguments = @()
    foreach ($decodedArgument in @($decodedArguments)) {
        if ($null -eq $decodedArgument) { continue }
        $textArgument = [string]$decodedArgument
        if ([string]::IsNullOrWhiteSpace($textArgument)) { throw 'Profile launch arguments cannot contain an empty value.' }
        $profileArguments += $textArgument
    }
}
catch { throw 'LaunchArgsBase64 is not valid UTF-8 JSON.' }

$forbidden = @(
    '--listen', '--share', '--enable-insecure-extension-access', '--api-auth', '--gradio-auth',
    '--tls-keyfile', '--tls-certfile', '--port', '--data-dir', '--server-name', '--api',
    '--api-server-stop', '--no-download-sd-model', '--disable-extra-extensions', '--allow-code',
    '--disable-safe-unpickle', '--autolaunch', '--ckpt-dir', '--vae-dir', '--lora-dir',
    '--hypernetwork-dir', '--embeddings-dir'
)
foreach ($argument in $profileArguments) {
    $lower = $argument.ToLowerInvariant()
    foreach ($item in $forbidden) {
        if ($lower -eq $item -or $lower.StartsWith($item + '=')) { throw "Unsafe or supervisor-owned launch argument: $argument" }
    }
}

$userDataRoot = Join-Path $DataRoot 'userdata'
if (-not (Test-Path -LiteralPath $userDataRoot)) { $null = New-Item -ItemType Directory -Path $userDataRoot -Force }
Import-Module (Join-Path $RepositoryRoot 'src\StableDiffusionWorkbench.Core.psm1') -Force -DisableNameChecking
$managedPaths = Get-SdwPaths -RepositoryRoot $RepositoryRoot -DataRoot $DataRoot
$modelsRoot = $managedPaths.ModelsRoot
$checkpointsRoot = Join-Path $modelsRoot 'Checkpoints'
$vaeRoot = Join-Path $modelsRoot 'VAE'
$loraRoot = Join-Path $modelsRoot 'Lora'
$hypernetworksRoot = Join-Path $modelsRoot 'Hypernetworks'
$embeddingsRoot = $managedPaths.EmbeddingsRoot
foreach ($managedDirectory in @($modelsRoot, $checkpointsRoot, $vaeRoot, $loraRoot, $hypernetworksRoot, $embeddingsRoot)) {
    if (-not (Test-Path -LiteralPath $managedDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $managedDirectory -Force
    }
}
$logDirectory = Split-Path -Parent $LogPath
if (-not (Test-Path -LiteralPath $logDirectory)) { $null = New-Item -ItemType Directory -Path $logDirectory -Force }
$logEncoding = New-Object Text.UTF8Encoding($false)
$script:LogWriter = New-Object IO.StreamWriter($LogPath, $true, $logEncoding)
$script:LogWriter.AutoFlush = $true
Ensure-SdwUiSettings -UserDataRoot $userDataRoot -OutputsRoot $managedPaths.OutputsRoot -DirectML:($profileArguments -contains '--use-directml')
Write-LogLine -Stream 'supervisor' -Line 'Ensured checkpoint and VAE selectors are visible in A1111 quick settings.'

$supervisorProcess = Get-Process -Id $PID
$supervisorStartedAtUtc = $supervisorProcess.StartTime.ToUniversalTime().ToString('o')
$state = [ordered]@{
    schemaVersion = 1
    instanceId = 'default'
    ownerToken = $OwnerToken
    status = 'starting'
    supervisorPid = $PID
    supervisorStartedAtUtc = $supervisorStartedAtUtc
    supervisorPath = $MyInvocation.MyCommand.Path
    childPid = $null
    childStartedAtUtc = $null
    pythonPath = $PythonPath
    gitPath = $GitPath
    versionPath = $VersionPath
    checkoutPath = $CheckoutPath
    dataRoot = $DataRoot
    port = $Port
    url = ('http://127.0.0.1:{0}' -f $Port)
    profileId = $ProfileId
    upstreamCommit = $UpstreamCommit
    logPath = $LogPath
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    exitCode = $null
}

$child = $null
try {
    Write-LogLine -Stream 'supervisor' -Line ("Starting profile {0} at commit {1}." -f $ProfileId, $UpstreamCommit)
    Write-StateAtomic -Value $state
    $arguments = @(
        'launch.py',
        '--api',
        '--api-server-stop',
        '--no-download-sd-model',
        '--disable-extra-extensions',
        '--server-name', '127.0.0.1',
        '--data-dir', $userDataRoot,
        '--models-dir', $modelsRoot,
        '--ckpt-dir', $checkpointsRoot,
        '--vae-dir', $vaeRoot,
        '--lora-dir', $loraRoot,
        '--hypernetwork-dir', $hypernetworksRoot,
        '--embeddings-dir', $embeddingsRoot,
        '--port', [string]$Port
    ) + $profileArguments

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $PythonPath
    $info.Arguments = (($arguments | ForEach-Object { ConvertTo-SupervisorArgument -Value ([string]$_) }) -join ' ')
    $info.WorkingDirectory = $CheckoutPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $pythonDirectory = Split-Path -Parent $PythonPath
    $gitDirectory = Split-Path -Parent $GitPath
    $gitCmdDirectory = Join-Path (Split-Path -Parent $gitDirectory) 'cmd'
    $info.EnvironmentVariables['PYTHON'] = $PythonPath
    $info.EnvironmentVariables['GIT'] = $GitPath
    $info.EnvironmentVariables['TORCH_COMMAND'] = $TorchCommand
    $info.EnvironmentVariables['SKIP_VENV'] = '1'
    $info.EnvironmentVariables['VENV_DIR'] = '-'
    $info.EnvironmentVariables['WEBUI_LAUNCH_LIVE_OUTPUT'] = '1'
    $info.EnvironmentVariables['PIP_DISABLE_PIP_VERSION_CHECK'] = '1'
    $info.EnvironmentVariables['PYTHONUTF8'] = '1'
    $info.EnvironmentVariables['PYTHONNOUSERSITE'] = '1'
    $info.EnvironmentVariables['PYTHONUNBUFFERED'] = '1'
    if ($profileArguments -contains '--use-directml') { $info.EnvironmentVariables['PIP_NO_BUILD_ISOLATION'] = '0' }
    $info.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $info.EnvironmentVariables['PATH'] = ($pythonDirectory + ';' + (Join-Path $pythonDirectory 'Scripts') + ';' + $gitDirectory + ';' + $gitCmdDirectory + ';' + $env:PATH)

    Write-LogLine -Stream 'supervisor' -Line ("Executing bundled Python with locked checkout on port {0}." -f $Port)
    $child = New-Object Diagnostics.Process
    $child.StartInfo = $info
    if (-not $child.Start()) { throw 'Process.Start returned false for bundled Python.' }
    $state.childPid = $child.Id
    $state.childStartedAtUtc = $child.StartTime.ToUniversalTime().ToString('o')
    $state.status = 'running'
    Write-StateAtomic -Value $state

    $stdoutClosed = $false
    $stderrClosed = $false
    $stdoutTask = $child.StandardOutput.ReadLineAsync()
    $stderrTask = $child.StandardError.ReadLineAsync()
    while (-not $child.HasExited -or -not $stdoutClosed -or -not $stderrClosed) {
        if (-not $stdoutClosed -and $stdoutTask.IsCompleted) {
            $line = $stdoutTask.Result
            if ($null -eq $line) { $stdoutClosed = $true }
            else { Write-LogLine -Stream 'stdout' -Line $line; $stdoutTask = $child.StandardOutput.ReadLineAsync() }
        }
        if (-not $stderrClosed -and $stderrTask.IsCompleted) {
            $line = $stderrTask.Result
            if ($null -eq $line) { $stderrClosed = $true }
            else { Write-LogLine -Stream 'stderr' -Line $line; $stderrTask = $child.StandardError.ReadLineAsync() }
        }
        if (-not $child.HasExited) { Start-Sleep -Milliseconds 50 }
        elseif (($stdoutClosed -or $stdoutTask.IsCompleted) -and ($stderrClosed -or $stderrTask.IsCompleted)) { Start-Sleep -Milliseconds 10 }
    }
    $child.WaitForExit()
    $state.exitCode = [int]$child.ExitCode
    $state.status = 'exited'
    $state.exitedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-LogLine -Stream 'supervisor' -Line ("WebUI process exited with code {0}." -f $child.ExitCode)
    Write-StateAtomic -Value $state
    exit $child.ExitCode
}
catch {
    $state.status = 'exited'
    $state.exitCode = 1
    $state.exitedAtUtc = [DateTime]::UtcNow.ToString('o')
    $state.error = $_.Exception.Message
    try { Write-LogLine -Stream 'supervisor-error' -Line $_.Exception.ToString() } catch { }
    try { Write-StateAtomic -Value $state } catch { }
    exit 1
}
finally {
    if ($null -ne $child) { $child.Dispose() }
    if ($null -ne $script:LogWriter) { $script:LogWriter.Dispose() }
}
