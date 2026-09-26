Set-StrictMode -Version 2.0

$script:SdwRepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:SdwStateSchemaVersion = 1
$script:SdwDefaultPort = 7860

function New-SdwException {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$ExitCode = 10
    )

    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['SdwExitCode'] = $ExitCode
    return $exception
}

function Throw-SdwError {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$ExitCode = 10
    )

    throw (New-SdwException -Message $Message -ExitCode $ExitCode)
}

function Get-SdwExitCode {
    param([Parameter(Mandatory = $true)]$Exception)

    if ($null -ne $Exception.Data -and $Exception.Data.Contains('SdwExitCode')) {
        return [int]$Exception.Data['SdwExitCode']
    }
    return 10
}

function Resolve-SdwDataRoot {
    [CmdletBinding()]
    param([string]$DataRoot)

    if ([string]::IsNullOrWhiteSpace($DataRoot)) {
        $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($local)) {
            $local = $env:LOCALAPPDATA
        }
        if ([string]::IsNullOrWhiteSpace($local)) {
            Throw-SdwError -Message 'LOCALAPPDATA is unavailable. Specify -DataRoot explicitly.' -ExitCode 2
        }
        $DataRoot = Join-Path $local 'StableDiffusionWorkbench'
    }

    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($DataRoot))
}

function Get-SdwPaths {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = $script:SdwRepositoryRoot,
        [string]$DataRoot
    )

    $repo = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $root = Resolve-SdwDataRoot -DataRoot $DataRoot
    $runtime = Join-Path $root 'runtime'
    $userdata = Join-Path $root 'userdata'
    $models = Join-Path $userdata 'models'
    $stateDirectory = Join-Path $root 'state'
    $logs = Join-Path $root 'logs'

    return [pscustomobject]@{
        RepositoryRoot = $repo
        DataRoot = $root
        ConfigPath = Join-Path $root 'config.json'
        ActivePath = Join-Path $runtime 'active.json'
        RuntimeRoot = $runtime
        VersionsRoot = Join-Path $runtime 'versions'
        StagingRoot = Join-Path $runtime 'staging'
        DownloadsRoot = Join-Path $root 'downloads'
        StateDirectory = $stateDirectory
        StatePath = Join-Path $stateDirectory 'runtime.json'
        StartLockPath = Join-Path $stateDirectory 'start.lock'
        LogsRoot = $logs
        SetupLogPath = Join-Path $logs 'setup.log'
        RuntimeLogPath = Join-Path $logs 'webui.log'
        UserDataRoot = $userdata
        ModelsRoot = $models
        CheckpointsRoot = Join-Path $models 'Stable-diffusion'
        LoraRoot = Join-Path $models 'Lora'
        VaeRoot = Join-Path $models 'VAE'
        EmbeddingsRoot = Join-Path $userdata 'embeddings'
        OutputsRoot = Join-Path $userdata 'outputs'
        UpstreamLockPath = Join-Path $repo 'configs\upstream-lock.json'
        ProfilesRoot = Join-Path $repo 'profiles'
        StarterModelsPath = Join-Path $repo 'asset-manifests\starter-models.json'
        SupervisorPath = Join-Path $repo 'scripts\supervisor.ps1'
    }
}

function Initialize-SdwLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths)

    $directories = @(
        $Paths.DataRoot, $Paths.RuntimeRoot, $Paths.VersionsRoot, $Paths.StagingRoot,
        $Paths.DownloadsRoot, $Paths.StateDirectory, $Paths.LogsRoot,
        $Paths.UserDataRoot, $Paths.ModelsRoot, $Paths.CheckpointsRoot,
        $Paths.LoraRoot, $Paths.VaeRoot, $Paths.EmbeddingsRoot, $Paths.OutputsRoot
    )
    foreach ($directory in $directories) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
    }
}

function Read-SdwJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Optional
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($Optional) { return $null }
        Throw-SdwError -Message ("Required JSON file was not found: {0}" -f $Path) -ExitCode 3
    }
    $content = $null
    $readError = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            $content = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
            $readError = $null
            break
        }
        catch [IO.IOException] {
            $readError = $_.Exception
            Start-Sleep -Milliseconds 50
        }
    }
    if ($null -ne $readError) {
        Throw-SdwError -Message ("Unable to read JSON file {0}: {1}" -f $Path, $readError.Message) -ExitCode 6
    }
    try { return ($content | ConvertFrom-Json) }
    catch { Throw-SdwError -Message ("Invalid JSON in {0}: {1}" -f $Path, $_.Exception.Message) -ExitCode 2 }
}

function Write-SdwJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $temporary = Join-Path $directory ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)), [Guid]::NewGuid().ToString('N'))
    $backup = Join-Path $directory ('.{0}.{1}.bak' -f ([IO.Path]::GetFileName($Path)), [Guid]::NewGuid().ToString('N'))
    $json = $Value | ConvertTo-Json -Depth 20
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($temporary, $json, $encoding)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                [IO.File]::Replace($temporary, $Path, $backup, $true)
                if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
            }
            catch {
                Move-Item -LiteralPath $temporary -Destination $Path -Force
            }
        }
        else {
            Move-Item -LiteralPath $temporary -Destination $Path
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
    }
}

function ConvertTo-SdwCommandLineArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object Text.StringBuilder
    $null = $builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            if ($backslashes -gt 0) { $null = $builder.Append(('\' * ($backslashes * 2))) }
            $null = $builder.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            $null = $builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        $null = $builder.Append($character)
    }
    if ($backslashes -gt 0) { $null = $builder.Append(('\' * ($backslashes * 2))) }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Join-SdwCommandLine {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { ConvertTo-SdwCommandLineArgument -Value ([string]$_) }) -join ' ')
}

function Invoke-SdwNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [hashtable]$Environment,
        [string]$LogPath,
        [switch]$AllowFailure,
        [int]$ExitCodeOnFailure = 6
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Throw-SdwError -Message ("Executable was not found: {0}" -f $FilePath) -ExitCode 3
    }

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = Join-SdwCommandLine -Arguments $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $info.WorkingDirectory = $WorkingDirectory }
    if ($null -ne $Environment) {
        foreach ($key in $Environment.Keys) {
            $info.EnvironmentVariables[[string]$key] = [string]$Environment[$key]
        }
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) {
            Throw-SdwError -Message ("Unable to start: {0}" -f $FilePath) -ExitCode $ExitCodeOnFailure
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            $logDirectory = Split-Path -Parent $LogPath
            if (-not (Test-Path -LiteralPath $logDirectory)) { $null = New-Item -ItemType Directory -Path $logDirectory -Force }
            $stamp = [DateTime]::UtcNow.ToString('o')
            Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ("`r`n[{0}] {1} {2}`r`n{3}{4}" -f $stamp, $FilePath, $info.Arguments, $stdout, $stderr)
        }
        $result = [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            StandardOutput = [string]$stdout
            StandardError = [string]$stderr
            FilePath = $FilePath
            Arguments = $Arguments
        }
        if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
            $detail = $stderr.Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $stdout.Trim() }
            if ($detail.Length -gt 1600) { $detail = $detail.Substring($detail.Length - 1600) }
            Throw-SdwError -Message ("Command failed with exit code {0}: {1}`n{2}" -f $result.ExitCode, $FilePath, $detail) -ExitCode $ExitCodeOnFailure
        }
        return $result
    }
    finally {
        $process.Dispose()
    }
}

function Get-SdwFileHashValue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($stream)
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Test-SdwFileIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Int64]$SizeBytes,
        [Parameter(Mandatory = $true)][string]$Sha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $file = Get-Item -LiteralPath $Path
    if ($SizeBytes -gt 0 -and $file.Length -ne $SizeBytes) { return $false }
    return ((Get-SdwFileHashValue -Path $Path) -eq $Sha256.ToLowerInvariant())
}

function Move-SdwInvalidAside {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $suffix = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $destination = '{0}.invalid-{1}' -f $Path, $suffix
    Move-Item -LiteralPath $Path -Destination $destination
}

function Invoke-SdwDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Int64]$ExpectedSize = 0,
        [string]$ExpectedSha256,
        [string]$Label = 'file'
    )

    $directory = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }

    if ((Test-Path -LiteralPath $Destination -PathType Leaf) -and
        (Test-SdwFileIntegrity -Path $Destination -SizeBytes $ExpectedSize -Sha256 $ExpectedSha256)) {
        Write-Output ("Already downloaded and verified: {0}" -f $Destination)
        return $Destination
    }
    if (Test-Path -LiteralPath $Destination) { Move-SdwInvalidAside -Path $Destination }

    $partial = '{0}.partial.{1}' -f $Destination, [Guid]::NewGuid().ToString('N')
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.UserAgent = 'StableDiffusionWorkbench/1.0'
        $request.AllowAutoRedirect = $true
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 30000
        $response = $request.GetResponse()
        $length = [Int64]$response.ContentLength
        if ($ExpectedSize -gt 0 -and $length -gt 0 -and $length -ne $ExpectedSize) {
            Throw-SdwError -Message ("The server reported an unexpected size for {0}: expected {1}, received {2}." -f $Label, $ExpectedSize, $length) -ExitCode 8
        }
        $inputStream = $response.GetResponseStream()
        $outputStream = New-Object IO.FileStream($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 1048576, [IO.FileOptions]::SequentialScan)
        $buffer = New-Object byte[] 1048576
        [Int64]$received = 0
        $lastPercent = -1
        while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $count)
            $received += $count
            if ($ExpectedSize -gt 0) {
                $percent = [int][Math]::Floor(($received * 100.0) / $ExpectedSize)
                if ($percent -ge ($lastPercent + 5)) {
                    Write-Output ("Downloading {0}: {1}% ({2:N1} / {3:N1} MiB)" -f $Label, $percent, ($received / 1MB), ($ExpectedSize / 1MB))
                    $lastPercent = $percent
                }
            }
        }
        $outputStream.Flush()
        $outputStream.Dispose(); $outputStream = $null
        $inputStream.Dispose(); $inputStream = $null
        $response.Dispose(); $response = $null

        if (-not (Test-SdwFileIntegrity -Path $partial -SizeBytes $ExpectedSize -Sha256 $ExpectedSha256)) {
            $actualSize = (Get-Item -LiteralPath $partial).Length
            $actualHash = Get-SdwFileHashValue -Path $partial
            Throw-SdwError -Message ("Integrity check failed for {0}. Size={1}; SHA256={2}." -f $Label, $actualSize, $actualHash) -ExitCode 8
        }
        Move-Item -LiteralPath $partial -Destination $Destination
        Write-Output ("Downloaded and verified: {0}" -f $Destination)
        return $Destination
    }
    catch {
        if ($_.Exception.Data.Contains('SdwExitCode')) { throw }
        Throw-SdwError -Message ("Download failed for {0}: {1}" -f $Label, $_.Exception.Message) -ExitCode 7
    }
    finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}

function Test-SdwChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Child
    )

    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $childFull = [IO.Path]::GetFullPath($Child)
    return $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)
}

function Test-SdwPathEncrypted {
    param([Parameter(Mandatory = $true)][string]$Path)
    $candidate = [IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $candidate) -and -not [string]::IsNullOrWhiteSpace($candidate)) {
        $parent = Split-Path -Parent $candidate
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) { break }
        $candidate = $parent
    }
    if (-not (Test-Path -LiteralPath $candidate)) { return $false }
    try {
        $attributes = (Get-Item -LiteralPath $candidate -Force).Attributes
        return (($attributes -band [IO.FileAttributes]::Encrypted) -eq [IO.FileAttributes]::Encrypted)
    }
    catch { return $false }
}

function Expand-SdwPortableSystem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $systemRoot = Join-Path $DestinationRoot 'system'
    if (-not (Test-Path -LiteralPath $systemRoot)) { $null = New-Item -ItemType Directory -Path $systemRoot -Force }
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $count = 0
    try {
        foreach ($entry in $archive.Entries) {
            $normalized = $entry.FullName.Replace('\', '/')
            $isDirectory = $normalized.EndsWith('/')
            if ($isDirectory) { $normalized = $normalized.TrimEnd('/') }
            $parts = $normalized.Split('/')
            $systemIndex = -1
            for ($index = 0; $index -lt $parts.Length; $index++) {
                if ($parts[$index].Equals('system', [StringComparison]::OrdinalIgnoreCase)) {
                    $systemIndex = $index
                    break
                }
            }
            if ($systemIndex -lt 0 -or $systemIndex -ge ($parts.Length - 1)) { continue }
            $relativeParts = @($parts[($systemIndex + 1)..($parts.Length - 1)])
            if ($relativeParts.Count -eq 0) { continue }
            foreach ($part in $relativeParts) {
                if ([string]::IsNullOrWhiteSpace($part) -or $part -eq '.' -or $part -eq '..' -or $part.IndexOf(':') -ge 0) {
                    Throw-SdwError -Message ("Unsafe archive entry rejected: {0}" -f $entry.FullName) -ExitCode 8
                }
            }
            $relative = [string]::Join([IO.Path]::DirectorySeparatorChar, $relativeParts)
            $destination = Join-Path $systemRoot $relative
            if (-not (Test-SdwChildPath -Parent $systemRoot -Child $destination)) {
                Throw-SdwError -Message ("Archive entry escaped the system directory: {0}" -f $entry.FullName) -ExitCode 8
            }
            if ($isDirectory) {
                if (-not (Test-Path -LiteralPath $destination)) { $null = New-Item -ItemType Directory -Path $destination -Force }
                continue
            }
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
            $source = $entry.Open()
            $target = New-Object IO.FileStream($destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $source.CopyTo($target) }
            finally { $target.Dispose(); $source.Dispose() }
            $count++
        }
    }
    finally {
        $archive.Dispose()
    }
    if ($count -eq 0) {
        Throw-SdwError -Message 'The portable archive did not contain a system/ directory.' -ExitCode 8
    }
    return $systemRoot
}

function Get-SdwGpuInfo {
    [CmdletBinding()]
    param()

    $names = New-Object Collections.Generic.List[string]
    $nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    $driver = $null
    $memoryMiB = $null
    if ($null -ne $nvidiaSmi) {
        try {
            $result = Invoke-SdwNativeCommand -FilePath $nvidiaSmi.Source -Arguments @('--query-gpu=name,driver_version,memory.total', '--format=csv,noheader,nounits') -AllowFailure
            if ($result.ExitCode -eq 0) {
                $line = ($result.StandardOutput -split "`r?`n" | Select-Object -First 1)
                $columns = @($line -split ',' | ForEach-Object { $_.Trim() })
                if ($columns.Count -ge 1 -and -not $names.Contains($columns[0])) { $names.Add($columns[0]) }
                if ($columns.Count -ge 2) { $driver = $columns[1] }
                if ($columns.Count -ge 3) { $memoryMiB = [int]$columns[2] }
            }
        }
        catch { }
    }
    if ($names.Count -eq 0) {
        try {
            if ($PSVersionTable.PSVersion.Major -le 5) { $controllers = Get-WmiObject -Class Win32_VideoController -ErrorAction Stop }
            else { $controllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop }
            foreach ($controller in $controllers) {
                if (-not [string]::IsNullOrWhiteSpace($controller.Name)) { $names.Add([string]$controller.Name) }
            }
        }
        catch { }
    }

    $joined = $names -join '; '
    return [pscustomobject]@{
        Names = @($names)
        DisplayName = $joined
        HasNvidia = ($joined -match '(?i)NVIDIA|GeForce|Quadro|RTX')
        IsBlackwell = ($joined -match '(?i)RTX\s*50\d{2}|Blackwell')
        DriverVersion = $driver
        MemoryMiB = $memoryMiB
    }
}

function Get-SdwProfile {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = $script:SdwRepositoryRoot,
        [string]$ProfileId
    )

    if ([string]::IsNullOrWhiteSpace($ProfileId) -or $ProfileId -eq 'auto') {
        $gpu = Get-SdwGpuInfo
        if ($gpu.IsBlackwell) { $ProfileId = 'windows-nvidia-blackwell' }
        else { $ProfileId = 'windows-nvidia-standard' }
    }
    if ($ProfileId -notmatch '^[a-z0-9][a-z0-9-]{1,63}$') {
        Throw-SdwError -Message ("Invalid profile id: {0}" -f $ProfileId) -ExitCode 2
    }
    $path = Join-Path (Join-Path $RepositoryRoot 'profiles') ($ProfileId + '.json')
    $profile = Read-SdwJson -Path $path
    if (-not $profile.PSObject.Properties['id']) { Throw-SdwError -Message ("Profile file is missing its internal id: {0}" -f $path) -ExitCode 2 }
    $internalId = [string]$profile.id
    if ($internalId -notmatch '^[a-z0-9][a-z0-9-]{1,63}$' -or -not $internalId.Equals($ProfileId, [StringComparison]::Ordinal)) {
        Throw-SdwError -Message ("Profile internal id must be safe and exactly match its file name: {0}" -f $path) -ExitCode 2
    }
    return $profile
}

function Get-SdwProfileId {
    param([Parameter(Mandatory = $true)]$Profile)
    if ($Profile.PSObject.Properties['id']) { return [string]$Profile.id }
    if ($Profile.PSObject.Properties['profileId']) { return [string]$Profile.profileId }
    Throw-SdwError -Message 'Profile is missing id.' -ExitCode 2
}

function Get-SdwProfileCommit {
    param([Parameter(Mandatory = $true)]$Profile)
    foreach ($name in @('upstreamCommit', 'commit', 'webuiCommit')) {
        if ($Profile.PSObject.Properties[$name] -and -not [string]::IsNullOrWhiteSpace([string]$Profile.$name)) { return [string]$Profile.$name }
    }
    Throw-SdwError -Message 'Profile is missing upstreamCommit.' -ExitCode 2
}

function Get-SdwProfileTorchCommand {
    param([Parameter(Mandatory = $true)]$Profile)
    if ($Profile.PSObject.Properties['torchCommand']) { return [string]$Profile.torchCommand }
    if ($Profile.PSObject.Properties['environment'] -and $Profile.environment.PSObject.Properties['TORCH_COMMAND']) { return [string]$Profile.environment.TORCH_COMMAND }
    Throw-SdwError -Message 'Profile is missing torchCommand.' -ExitCode 2
}

function Get-SdwProfileLaunchArgs {
    param([Parameter(Mandatory = $true)]$Profile)
    if ($Profile.PSObject.Properties['launchArgs']) { return @($Profile.launchArgs | ForEach-Object { [string]$_ }) }
    return @()
}

function Get-SdwProfileDisplayName {
    param([Parameter(Mandatory = $true)]$Profile)
    if ($Profile.PSObject.Properties['displayName']) { return [string]$Profile.displayName }
    return Get-SdwProfileId -Profile $Profile
}

function Assert-SdwSafeProfileArguments {
    param([string[]]$Arguments)
    $forbidden = @(
        '--listen', '--share', '--enable-insecure-extension-access', '--api-auth', '--gradio-auth',
        '--tls-keyfile', '--tls-certfile', '--port', '--data-dir', '--server-name', '--api',
        '--api-server-stop', '--no-download-sd-model', '--disable-extra-extensions', '--allow-code',
        '--disable-safe-unpickle', '--autolaunch'
    )
    foreach ($argument in $Arguments) {
        $lower = $argument.ToLowerInvariant()
        foreach ($item in $forbidden) {
            if ($lower -eq $item -or $lower.StartsWith($item + '=')) {
                Throw-SdwError -Message ("Unsafe or launcher-owned profile argument rejected: {0}" -f $argument) -ExitCode 2
            }
        }
    }
}

function Get-SdwConfiguration {
    param([Parameter(Mandatory = $true)]$Paths)
    $config = Read-SdwJson -Path $Paths.ConfigPath -Optional
    if ($null -eq $config) {
        return [pscustomobject]@{
            schemaVersion = 1
            dataRoot = $Paths.DataRoot
            port = $script:SdwDefaultPort
            profileId = 'auto'
        }
    }
    return $config
}

function Set-SdwConfiguration {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = $script:SdwRepositoryRoot,
        [string]$DataRoot,
        [int]$Port,
        [string]$ProfileId
    )

    $paths = Get-SdwPaths -RepositoryRoot $RepositoryRoot -DataRoot $DataRoot
    Initialize-SdwLayout -Paths $paths
    $current = Get-SdwConfiguration -Paths $paths
    if ($Port -le 0) { $Port = [int]$current.port }
    if ($Port -lt 1024 -or $Port -gt 65535) { Throw-SdwError -Message 'Port must be between 1024 and 65535.' -ExitCode 2 }
    if ([string]::IsNullOrWhiteSpace($ProfileId)) { $ProfileId = [string]$current.profileId }
    $null = Get-SdwProfile -RepositoryRoot $RepositoryRoot -ProfileId $ProfileId
    $value = [ordered]@{
        schemaVersion = 1
        dataRoot = $paths.DataRoot
        port = $Port
        profileId = $ProfileId
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-SdwJsonAtomic -Path $paths.ConfigPath -Value $value
    return [pscustomobject]$value
}

function Get-SdwPortableDefinition {
    param([Parameter(Mandatory = $true)]$Lock)
    if ($Lock.PSObject.Properties['portable']) { return $Lock.portable }
    if ($Lock.PSObject.Properties['runtime'] -and $Lock.runtime.PSObject.Properties['portable']) { return $Lock.runtime.portable }
    Throw-SdwError -Message 'upstream-lock.json is missing portable definition.' -ExitCode 2
}

function Get-SdwPropertyValue {
    param($Object, [string[]]$Names)
    foreach ($name in $Names) {
        if ($null -ne $Object -and $Object.PSObject.Properties[$name]) { return $Object.$name }
    }
    return $null
}

function Get-SdwRuntimeExecutables {
    param([Parameter(Mandatory = $true)][string]$VersionPath)
    $python = Join-Path $VersionPath 'system\python\python.exe'
    $git = Join-Path $VersionPath 'system\git\bin\git.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        $pythonItem = Get-ChildItem -LiteralPath (Join-Path $VersionPath 'system') -Filter python.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $pythonItem) { $python = $pythonItem.FullName }
    }
    if (-not (Test-Path -LiteralPath $git -PathType Leaf)) {
        $gitItem = Get-ChildItem -LiteralPath (Join-Path $VersionPath 'system') -Filter git.exe -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '(?i)[\\/]git[\\/](cmd|bin)[\\/]git\.exe$' } | Select-Object -First 1
        if ($null -ne $gitItem) { $git = $gitItem.FullName }
    }
    return [pscustomobject]@{
        PythonPath = $python
        GitPath = $git
        CheckoutPath = Join-Path $VersionPath 'webui'
    }
}

function New-SdwEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$GitPath,
        [Parameter(Mandatory = $true)][string]$TorchCommand
    )
    $pythonDirectory = Split-Path -Parent $PythonPath
    $gitDirectory = Split-Path -Parent $GitPath
    return @{
        PYTHON = $PythonPath
        GIT = $GitPath
        TORCH_COMMAND = $TorchCommand
        SKIP_VENV = '1'
        VENV_DIR = '-'
        WEBUI_LAUNCH_LIVE_OUTPUT = '1'
        PIP_DISABLE_PIP_VERSION_CHECK = '1'
        PYTHONUTF8 = '1'
        PYTHONIOENCODING = 'utf-8'
        PATH = ($pythonDirectory + ';' + $gitDirectory + ';' + $env:PATH)
    }
}

function Initialize-SdwPip {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    $check = Invoke-SdwNativeCommand -FilePath $PythonPath -Arguments @('-m', 'pip', '--version') -WorkingDirectory $WorkingDirectory -Environment $Environment -LogPath $LogPath -AllowFailure
    if ($check.ExitCode -ne 0) {
        $ensure = Invoke-SdwNativeCommand -FilePath $PythonPath -Arguments @('-m', 'ensurepip', '--upgrade') -WorkingDirectory $WorkingDirectory -Environment $Environment -LogPath $LogPath -AllowFailure
        if ($ensure.ExitCode -ne 0) {
            # The hash-locked A1111 portable archive ships get-pip.py next to its
            # embedded Python, while the embedded standard library omits ensurepip.
            $getPip = Join-Path (Split-Path -Parent $PythonPath) 'get-pip.py'
            if (-not (Test-Path -LiteralPath $getPip -PathType Leaf)) {
                Throw-SdwError -Message 'The bundled Python runtime has neither ensurepip nor its hash-covered get-pip.py bootstrap.' -ExitCode 6
            }
            $bootstrap = Invoke-SdwNativeCommand -FilePath $PythonPath -Arguments @($getPip, '--disable-pip-version-check') -WorkingDirectory $WorkingDirectory -Environment $Environment -LogPath $LogPath -AllowFailure
            if ($bootstrap.ExitCode -ne 0) {
                Throw-SdwError -Message 'The bundled get-pip.py bootstrap failed. Check setup.log and network access.' -ExitCode 6
            }
        }
        $verify = Invoke-SdwNativeCommand -FilePath $PythonPath -Arguments @('-m', 'pip', '--version') -WorkingDirectory $WorkingDirectory -Environment $Environment -LogPath $LogPath -AllowFailure
        if ($verify.ExitCode -ne 0) { Throw-SdwError -Message 'pip is unavailable after bootstrap.' -ExitCode 6 }
    }

    # get-pip.py intentionally tracks current packaging releases. A1111's
    # pinned CLIP dependency still imports pkg_resources, which was removed
    # from newer setuptools releases. Normalize the bootstrap toolchain to a
    # known Python 3.10-compatible set before launch.py installs anything.
    $packaging = Invoke-SdwNativeCommand -FilePath $PythonPath -Arguments @(
        '-m', 'pip', 'install', '--disable-pip-version-check', '--no-warn-script-location',
        'pip==24.0', 'setuptools==69.5.1', 'wheel==0.43.0'
    ) -WorkingDirectory $WorkingDirectory -Environment $Environment -LogPath $LogPath -AllowFailure
    if ($packaging.ExitCode -ne 0) {
        Throw-SdwError -Message 'Unable to install the pinned pip/setuptools/wheel bootstrap toolchain.' -ExitCode 6
    }
    $packagingVerify = Invoke-SdwNativeCommand -FilePath $PythonPath -Arguments @(
        '-c', 'import importlib.metadata as m; print(m.version("pip")); print(m.version("setuptools")); print(m.version("wheel"))'
    ) -WorkingDirectory $WorkingDirectory -Environment $Environment -LogPath $LogPath -AllowFailure
    $packagingVersions = (($packagingVerify.StandardOutput.Trim() -split "`r?`n") | ForEach-Object { $_.Trim() }) -join ','
    if ($packagingVerify.ExitCode -ne 0 -or $packagingVersions -ne '24.0,69.5.1,0.43.0') {
        Throw-SdwError -Message 'Pinned Python packaging toolchain validation failed.' -ExitCode 6
    }
    $pkgResourcesVerify = Invoke-SdwNativeCommand -FilePath $PythonPath -Arguments @(
        '-c', 'import pkg_resources; print(pkg_resources.__file__)'
    ) -WorkingDirectory $WorkingDirectory -Environment $Environment -LogPath $LogPath -AllowFailure
    if ($pkgResourcesVerify.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($pkgResourcesVerify.StandardOutput)) {
        Throw-SdwError -Message 'pkg_resources is unavailable after pinning setuptools 69.5.1.' -ExitCode 6
    }
}

function Initialize-SdwA1111Compatibility {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    # open-clip's unconstrained resolution can currently select the unrelated
    # httpx2/httpcore2 compatibility packages. Preinstall the last compatible
    # 0.x Hub release so A1111's old HTTP stack remains internally consistent.
    $hub = Invoke-SdwNativeCommand -FilePath $PythonPath -Arguments @(
        '-m', 'pip', 'install', '--disable-pip-version-check', '--no-warn-script-location',
        'huggingface-hub==0.36.2'
    ) -WorkingDirectory $WorkingDirectory -Environment $Environment -LogPath $LogPath -AllowFailure
    if ($hub.ExitCode -ne 0) { Throw-SdwError -Message 'Unable to install the pinned huggingface-hub compatibility dependency.' -ExitCode 6 }
}

function Complete-SdwA1111Dependencies {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    # Clean up orphan compatibility packages produced by older/incomplete
    # installs. Exact A1111 dependencies use httpx/httpcore, not these names.
    $cleanup = Invoke-SdwNativeCommand -FilePath $PythonPath -Arguments @(
        '-m', 'pip', 'uninstall', '-y', 'httpx2', 'httpcore2'
    ) -WorkingDirectory $WorkingDirectory -Environment $Environment -LogPath $LogPath -AllowFailure
    if ($cleanup.ExitCode -ne 0) { Throw-SdwError -Message 'Unable to remove orphan httpx2/httpcore2 packages.' -ExitCode 6 }
    $check = Invoke-SdwNativeCommand -FilePath $PythonPath -Arguments @('-m', 'pip', 'check') -WorkingDirectory $WorkingDirectory -Environment $Environment -LogPath $LogPath -AllowFailure
    if ($check.ExitCode -ne 0) {
        Throw-SdwError -Message ("A1111 dependency validation failed: {0}" -f (($check.StandardOutput + $check.StandardError).Trim())) -ExitCode 6
    }
}

function Test-SdwInstalledVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VersionPath,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit
    )

    if (-not (Test-Path -LiteralPath $VersionPath -PathType Container)) { return $false }
    $executables = Get-SdwRuntimeExecutables -VersionPath $VersionPath
    if (-not (Test-Path -LiteralPath $executables.PythonPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $executables.GitPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $executables.CheckoutPath 'launch.py') -PathType Leaf)) { return $false }
    try {
        $head = Invoke-SdwNativeCommand -FilePath $executables.GitPath -Arguments @('-C', $executables.CheckoutPath, 'rev-parse', 'HEAD') -AllowFailure
        if ($head.ExitCode -ne 0 -or -not $head.StandardOutput.Trim().Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $dirty = Invoke-SdwNativeCommand -FilePath $executables.GitPath -Arguments @('-C', $executables.CheckoutPath, 'status', '--porcelain') -AllowFailure
        return ($dirty.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($dirty.StandardOutput))
    }
    catch { return $false }
}

function Get-SdwValidatedActiveRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Paths,
        $Active,
        [switch]$ThrowOnFailure
    )

    try {
        if ($null -eq $Active) { throw 'No active runtime record exists.' }
        foreach ($propertyName in @('profileId', 'upstreamCommit', 'versionPath', 'checkoutPath', 'pythonPath', 'gitPath')) {
            if (-not $Active.PSObject.Properties[$propertyName] -or [string]::IsNullOrWhiteSpace([string]$Active.$propertyName)) {
                throw ("Active runtime record is missing {0}." -f $propertyName)
            }
        }
        $profileId = [string]$Active.profileId
        if ($profileId -notmatch '^[a-z0-9][a-z0-9-]{1,63}$') { throw 'Active runtime profile id is unsafe.' }
        $profile = Get-SdwProfile -RepositoryRoot $Paths.RepositoryRoot -ProfileId $profileId
        $profileCommit = Get-SdwProfileCommit -Profile $profile
        $commit = [string]$Active.upstreamCommit
        if ($commit -notmatch '^[0-9a-fA-F]{40}$' -or -not $commit.Equals($profileCommit, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Active runtime commit does not match its bundled profile.'
        }
        $lock = Read-SdwJson -Path $Paths.UpstreamLockPath
        if (-not $lock.PSObject.Properties['upstream'] -or -not $lock.upstream.PSObject.Properties['profiles']) { throw 'Upstream lock profile map is missing.' }
        $lockedProfileProperty = $lock.upstream.profiles.PSObject.Properties[$profileId]
        if ($null -eq $lockedProfileProperty -or -not $lockedProfileProperty.Value.PSObject.Properties['commit'] -or
            -not ([string]$lockedProfileProperty.Value.commit).Equals($commit, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Active runtime commit does not match upstream-lock.json.'
        }

        $versionPath = [IO.Path]::GetFullPath([string]$Active.versionPath)
        if (-not (Test-SdwChildPath -Parent $Paths.VersionsRoot -Child $versionPath)) { throw 'Active runtime version path is outside the managed versions root.' }
        $expectedCheckout = [IO.Path]::GetFullPath((Join-Path $versionPath 'webui'))
        $expectedPython = [IO.Path]::GetFullPath((Join-Path $versionPath 'system\python\python.exe'))
        $expectedGit = [IO.Path]::GetFullPath((Join-Path $versionPath 'system\git\bin\git.exe'))
        $pathPairs = @(
            @([string]$Active.checkoutPath, $expectedCheckout, 'checkoutPath'),
            @([string]$Active.pythonPath, $expectedPython, 'pythonPath'),
            @([string]$Active.gitPath, $expectedGit, 'gitPath')
        )
        foreach ($pair in $pathPairs) {
            $actual = [IO.Path]::GetFullPath([string]$pair[0])
            if (-not $actual.Equals([string]$pair[1], [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-SdwChildPath -Parent $versionPath -Child $actual)) {
                throw ("Active runtime {0} is inconsistent with its managed version path." -f $pair[2])
            }
        }
        if (-not (Test-SdwInstalledVersion -VersionPath $versionPath -ExpectedCommit $commit)) {
            throw 'Active runtime files, commit, or tracked checkout state failed validation.'
        }
        $trustedLaunchArguments = Get-SdwProfileLaunchArgs -Profile $profile
        Assert-SdwSafeProfileArguments -Arguments $trustedLaunchArguments
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            profileId = $profileId
            profileName = Get-SdwProfileDisplayName -Profile $profile
            upstreamCommit = $commit
            versionPath = $versionPath
            checkoutPath = $expectedCheckout
            pythonPath = $expectedPython
            gitPath = $expectedGit
            torchCommand = Get-SdwProfileTorchCommand -Profile $profile
            launchArgs = @($trustedLaunchArguments)
            activatedAtUtc = $(if ($Active.PSObject.Properties['activatedAtUtc']) { [string]$Active.activatedAtUtc } else { $null })
        }
    }
    catch {
        if ($ThrowOnFailure) { Throw-SdwError -Message ("Active runtime validation failed: {0}" -f $_.Exception.Message) -ExitCode 9 }
        return $null
    }
}

function Invoke-SdwSetup {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = $script:SdwRepositoryRoot,
        [string]$DataRoot,
        [string]$ProfileId,
        [switch]$Repair
    )

    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        Throw-SdwError -Message 'Stable Diffusion Workbench currently supports Windows x64 only.' -ExitCode 3
    }
    if (-not [Environment]::Is64BitOperatingSystem) { Throw-SdwError -Message 'A 64-bit Windows installation is required.' -ExitCode 3 }
    $gpu = Get-SdwGpuInfo
    if (-not $gpu.HasNvidia) {
        Throw-SdwError -Message 'This MVP requires a supported NVIDIA GPU and driver; no NVIDIA GPU was detected.' -ExitCode 3
    }

    $paths = Get-SdwPaths -RepositoryRoot $RepositoryRoot -DataRoot $DataRoot
    if (Test-SdwPathEncrypted -Path $paths.DataRoot) {
        Throw-SdwError -Message ("The selected data root inherits Windows EFS encryption, which is incompatible with pip atomic installs on this host: {0}. Choose an unencrypted local folder in Settings (for example D:\StableDiffusionWorkbench)." -f $paths.DataRoot) -ExitCode 3
    }
    Initialize-SdwLayout -Paths $paths
    $operationMutex = New-Object Threading.Mutex($false, (Get-SdwOperationMutexName -DataRoot $paths.DataRoot))
    $operationLocked = $false
    try {
    $operationLocked = $operationMutex.WaitOne(15000)
    if (-not $operationLocked) { Throw-SdwError -Message 'Another setup, start, or stop operation is already in progress.' -ExitCode 5 }
    $liveState = Read-SdwJson -Path $paths.StatePath -Optional
    if ($null -ne $liveState -and (Test-SdwManagedRuntimeState -Paths $paths -State $liveState)) {
        Throw-SdwError -Message 'Stop the launcher-owned WebUI before running setup or repair.' -ExitCode 5
    }
    $configuration = Get-SdwConfiguration -Paths $paths
    if ([string]::IsNullOrWhiteSpace($ProfileId)) { $ProfileId = [string]$configuration.profileId }
    $profile = Get-SdwProfile -RepositoryRoot $RepositoryRoot -ProfileId $ProfileId
    $profileIdResolved = Get-SdwProfileId -Profile $profile
    $commit = Get-SdwProfileCommit -Profile $profile
    if ($commit -notmatch '^[0-9a-fA-F]{40}$') { Throw-SdwError -Message 'The profile upstream commit must be a full 40-character SHA.' -ExitCode 2 }
    $torchCommand = Get-SdwProfileTorchCommand -Profile $profile
    $launchArguments = Get-SdwProfileLaunchArgs -Profile $profile
    Assert-SdwSafeProfileArguments -Arguments $launchArguments

    $baseName = '{0}-{1}' -f $profileIdResolved, $commit.Substring(0, 12).ToLowerInvariant()
    $versionPath = Join-Path $paths.VersionsRoot $baseName
    if (-not (Test-SdwChildPath -Parent $paths.VersionsRoot -Child $versionPath)) { Throw-SdwError -Message 'Resolved version path escaped the managed versions root.' -ExitCode 9 }
    $recordedActive = Read-SdwJson -Path $paths.ActivePath -Optional
    $validatedRecordedActive = Get-SdwValidatedActiveRecord -Paths $paths -Active $recordedActive
    if ($null -ne $validatedRecordedActive -and
        [string]$validatedRecordedActive.profileId -eq $profileIdResolved -and
        [string]$validatedRecordedActive.upstreamCommit -eq $commit) {
        # A prior repair may intentionally be active beside a preserved broken
        # base version. Prefer that verified active runtime over the base name.
        $versionPath = [string]$validatedRecordedActive.versionPath
    }
    $existingVersionValid = Test-SdwInstalledVersion -VersionPath $versionPath -ExpectedCommit $commit
    if ($existingVersionValid -and $Repair) {
        $repairSucceeded = $false
        try {
            $repairExecutables = Get-SdwRuntimeExecutables -VersionPath $versionPath
            $dirty = Invoke-SdwNativeCommand -FilePath $repairExecutables.GitPath -Arguments @('-C', $repairExecutables.CheckoutPath, 'status', '--porcelain') -AllowFailure
            if ($dirty.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($dirty.StandardOutput)) {
                throw 'The managed upstream checkout is dirty; it will be replaced by a fresh isolated version.'
            }
            $repairEnvironment = New-SdwEnvironment -PythonPath $repairExecutables.PythonPath -GitPath $repairExecutables.GitPath -TorchCommand $torchCommand
            Write-Output 'Repairing pip and A1111 dependencies in the existing locked runtime...'
            Initialize-SdwPip -PythonPath $repairExecutables.PythonPath -WorkingDirectory $versionPath -Environment $repairEnvironment -LogPath $paths.SetupLogPath
            Initialize-SdwA1111Compatibility -PythonPath $repairExecutables.PythonPath -WorkingDirectory $versionPath -Environment $repairEnvironment -LogPath $paths.SetupLogPath
            $null = Invoke-SdwNativeCommand -FilePath $repairExecutables.PythonPath -Arguments @('launch.py', '--exit') -WorkingDirectory $repairExecutables.CheckoutPath -Environment $repairEnvironment -LogPath $paths.SetupLogPath -ExitCodeOnFailure 6
            Complete-SdwA1111Dependencies -PythonPath $repairExecutables.PythonPath -WorkingDirectory $repairExecutables.CheckoutPath -Environment $repairEnvironment -LogPath $paths.SetupLogPath
            $repairTorch = Invoke-SdwNativeCommand -FilePath $repairExecutables.PythonPath -Arguments @('-c', 'import torch; print(torch.__version__); print(torch.version.cuda or "none"); print(torch.cuda.is_available())') -WorkingDirectory $repairExecutables.CheckoutPath -Environment $repairEnvironment -LogPath $paths.SetupLogPath -AllowFailure
            if ($repairTorch.ExitCode -ne 0 -or $repairTorch.StandardOutput -notmatch '(?im)^True\s*$') {
                throw 'CUDA validation failed after repairing the existing runtime.'
            }
            $repairSucceeded = $true
        }
        catch {
            Write-Output ("Existing runtime could not be repaired safely in place: {0}" -f $_.Exception.Message)
            Write-Output 'A fresh isolated repair version will be staged; the existing runtime will be preserved.'
        }
        if ($repairSucceeded) {
            $active = [ordered]@{
                schemaVersion = 1; profileId = $profileIdResolved; profileName = (Get-SdwProfileDisplayName -Profile $profile)
                upstreamCommit = $commit; versionPath = $versionPath; checkoutPath = $repairExecutables.CheckoutPath
                pythonPath = $repairExecutables.PythonPath; gitPath = $repairExecutables.GitPath; torchCommand = $torchCommand
                launchArgs = @($launchArguments); torchValidation = $repairTorch.StandardOutput.Trim(); activatedAtUtc = [DateTime]::UtcNow.ToString('o')
            }
            Write-SdwJsonAtomic -Path $paths.ActivePath -Value $active
            $null = Set-SdwConfiguration -RepositoryRoot $RepositoryRoot -DataRoot $paths.DataRoot -Port ([int]$configuration.port) -ProfileId $profileIdResolved
            Write-Output ("Runtime repair and CUDA validation completed: {0}" -f $versionPath)
            return [pscustomobject]$active
        }
        $versionPath = Join-Path $paths.VersionsRoot ('{0}-repair-{1}' -f $baseName, [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
    }
    elseif ($existingVersionValid) {
        $executables = Get-SdwRuntimeExecutables -VersionPath $versionPath
        $active = [ordered]@{
            schemaVersion = 1; profileId = $profileIdResolved; profileName = (Get-SdwProfileDisplayName -Profile $profile)
            upstreamCommit = $commit; versionPath = $versionPath; checkoutPath = $executables.CheckoutPath
            pythonPath = $executables.PythonPath; gitPath = $executables.GitPath; torchCommand = $torchCommand
            launchArgs = @($launchArguments); activatedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-SdwJsonAtomic -Path $paths.ActivePath -Value $active
        $null = Set-SdwConfiguration -RepositoryRoot $RepositoryRoot -DataRoot $paths.DataRoot -Port ([int]$configuration.port) -ProfileId $profileIdResolved
        Write-Output ("Runtime is already installed and verified: {0}" -f $versionPath)
        return [pscustomobject]$active
    }
    if ((Test-Path -LiteralPath $versionPath) -and -not $Repair) {
        Throw-SdwError -Message ("The managed version directory exists but failed validation: {0}. Run repair." -f $versionPath) -ExitCode 3
    }
    if ($Repair -and (Test-Path -LiteralPath $versionPath) -and $versionPath -eq (Join-Path $paths.VersionsRoot $baseName)) {
        $versionPath = Join-Path $paths.VersionsRoot ('{0}-repair-{1}' -f $baseName, [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
    }

    $lock = Read-SdwJson -Path $paths.UpstreamLockPath
    $portable = Get-SdwPortableDefinition -Lock $lock
    $portableUrl = [string](Get-SdwPropertyValue -Object $portable -Names @('url', 'downloadUrl'))
    $portableSize = [Int64](Get-SdwPropertyValue -Object $portable -Names @('sizeBytes', 'bytes'))
    $portableHash = [string](Get-SdwPropertyValue -Object $portable -Names @('sha256', 'sha256Hex'))
    if ([string]::IsNullOrWhiteSpace($portableUrl) -or $portableSize -le 0 -or $portableHash -notmatch '^[0-9a-fA-F]{64}$') {
        Throw-SdwError -Message 'The portable runtime lock is incomplete.' -ExitCode 2
    }
    $archivePath = Join-Path $paths.DownloadsRoot 'sd.webui-v1.0.0-pre.zip'
    $downloadOutput = @(Invoke-SdwDownload -Url $portableUrl -Destination $archivePath -ExpectedSize $portableSize -ExpectedSha256 $portableHash -Label 'A1111 portable runtime')
    foreach ($line in $downloadOutput) { if ($line -is [string]) { Write-Output $line } }

    # Keep the staging leaf deliberately short. Some pip wheel installers still
    # hit legacy Windows path limits deep under Lib\site-packages.
    $staging = Join-Path $paths.StagingRoot ('s-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
    if (-not (Test-SdwChildPath -Parent $paths.StagingRoot -Child $staging)) { Throw-SdwError -Message 'Resolved staging path escaped the managed staging root.' -ExitCode 9 }
    if (-not (Test-SdwChildPath -Parent $paths.VersionsRoot -Child $versionPath)) { Throw-SdwError -Message 'Resolved destination escaped the managed versions root.' -ExitCode 9 }
    $null = New-Item -ItemType Directory -Path $staging
    $moved = $false
    try {
        Write-Output 'Extracting the locked portable Python/Git runtime...'
        $null = Expand-SdwPortableSystem -ArchivePath $archivePath -DestinationRoot $staging
        $executables = Get-SdwRuntimeExecutables -VersionPath $staging
        if (-not (Test-Path -LiteralPath $executables.PythonPath -PathType Leaf)) { Throw-SdwError -Message 'Bundled Python was not found after extraction.' -ExitCode 8 }
        if (-not (Test-Path -LiteralPath $executables.GitPath -PathType Leaf)) { Throw-SdwError -Message 'Bundled Git was not found after extraction.' -ExitCode 8 }
        $environment = New-SdwEnvironment -PythonPath $executables.PythonPath -GitPath $executables.GitPath -TorchCommand $torchCommand
        Write-Output 'Checking pip in the isolated runtime...'
        Initialize-SdwPip -PythonPath $executables.PythonPath -WorkingDirectory $staging -Environment $environment -LogPath $paths.SetupLogPath
        Initialize-SdwA1111Compatibility -PythonPath $executables.PythonPath -WorkingDirectory $staging -Environment $environment -LogPath $paths.SetupLogPath

        Write-Output ("Cloning AUTOMATIC1111 at exact commit {0}..." -f $commit)
        $null = New-Item -ItemType Directory -Path $executables.CheckoutPath
        $null = Invoke-SdwNativeCommand -FilePath $executables.GitPath -Arguments @('-C', $executables.CheckoutPath, 'init') -Environment $environment -LogPath $paths.SetupLogPath
        $null = Invoke-SdwNativeCommand -FilePath $executables.GitPath -Arguments @('-C', $executables.CheckoutPath, 'remote', 'add', 'origin', 'https://github.com/AUTOMATIC1111/stable-diffusion-webui.git') -Environment $environment -LogPath $paths.SetupLogPath
        $null = Invoke-SdwNativeCommand -FilePath $executables.GitPath -Arguments @('-C', $executables.CheckoutPath, 'fetch', '--depth', '1', 'origin', $commit) -Environment $environment -LogPath $paths.SetupLogPath
        $null = Invoke-SdwNativeCommand -FilePath $executables.GitPath -Arguments @('-C', $executables.CheckoutPath, 'checkout', '--detach', 'FETCH_HEAD') -Environment $environment -LogPath $paths.SetupLogPath
        $head = Invoke-SdwNativeCommand -FilePath $executables.GitPath -Arguments @('-C', $executables.CheckoutPath, 'rev-parse', 'HEAD') -Environment $environment -LogPath $paths.SetupLogPath
        if (-not $head.StandardOutput.Trim().Equals($commit, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-SdwError -Message 'Git checkout did not resolve to the locked upstream commit.' -ExitCode 8
        }

        Write-Output 'Installing and validating A1111 dependencies. This can take several minutes...'
        $null = Invoke-SdwNativeCommand -FilePath $executables.PythonPath -Arguments @('launch.py', '--exit') -WorkingDirectory $executables.CheckoutPath -Environment $environment -LogPath $paths.SetupLogPath -ExitCodeOnFailure 6
        Complete-SdwA1111Dependencies -PythonPath $executables.PythonPath -WorkingDirectory $executables.CheckoutPath -Environment $environment -LogPath $paths.SetupLogPath
        $torch = Invoke-SdwNativeCommand -FilePath $executables.PythonPath -Arguments @('-c', 'import torch; print(torch.__version__); print(torch.version.cuda or "none"); print(torch.cuda.is_available())') -WorkingDirectory $executables.CheckoutPath -Environment $environment -LogPath $paths.SetupLogPath -AllowFailure
        if ($torch.ExitCode -ne 0) { Throw-SdwError -Message 'PyTorch validation failed after setup.' -ExitCode 6 }
        if ($torch.StandardOutput -notmatch '(?im)^True\s*$') { Throw-SdwError -Message 'PyTorch installed, but CUDA is not available to the bundled runtime. Check the NVIDIA driver and selected profile.' -ExitCode 6 }
        if (-not (Test-SdwInstalledVersion -VersionPath $staging -ExpectedCommit $commit)) {
            Throw-SdwError -Message 'The staged A1111 checkout changed or failed exact-lock validation during dependency installation; activation was refused.' -ExitCode 8
        }

        Move-Item -LiteralPath $staging -Destination $versionPath
        $moved = $true
        $installedExecutables = Get-SdwRuntimeExecutables -VersionPath $versionPath
        $active = [ordered]@{
            schemaVersion = 1; profileId = $profileIdResolved; profileName = (Get-SdwProfileDisplayName -Profile $profile)
            upstreamCommit = $commit; versionPath = $versionPath; checkoutPath = $installedExecutables.CheckoutPath
            pythonPath = $installedExecutables.PythonPath; gitPath = $installedExecutables.GitPath; torchCommand = $torchCommand
            launchArgs = @($launchArguments); torchValidation = $torch.StandardOutput.Trim(); activatedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-SdwJsonAtomic -Path $paths.ActivePath -Value $active
        $null = Set-SdwConfiguration -RepositoryRoot $RepositoryRoot -DataRoot $paths.DataRoot -Port ([int]$configuration.port) -ProfileId $profileIdResolved
        Write-Output ("Setup completed successfully: {0}" -f $versionPath)
        return [pscustomobject]$active
    }
    finally {
        if (-not $moved -and (Test-Path -LiteralPath $staging) -and (Test-SdwChildPath -Parent $paths.StagingRoot -Child $staging)) {
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
    }
    }
    finally {
        if ($operationLocked) { $operationMutex.ReleaseMutex() }
        $operationMutex.Dispose()
    }
}

function Get-SdwCheckpointFiles {
    param([Parameter(Mandatory = $true)]$Paths)
    if (-not (Test-Path -LiteralPath $Paths.CheckpointsRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Paths.CheckpointsRoot -Filter '*.safetensors' -File -ErrorAction SilentlyContinue)
}

function Import-SdwModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$RepositoryRoot = $script:SdwRepositoryRoot,
        [string]$DataRoot
    )

    $source = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { Throw-SdwError -Message ("Model file was not found: {0}" -f $source) -ExitCode 2 }
    if (-not [IO.Path]::GetExtension($source).Equals('.safetensors', [StringComparison]::OrdinalIgnoreCase)) {
        Throw-SdwError -Message 'Only .safetensors checkpoint files can be imported.' -ExitCode 2
    }
    $paths = Get-SdwPaths -RepositoryRoot $RepositoryRoot -DataRoot $DataRoot
    Initialize-SdwLayout -Paths $paths
    $destination = Join-Path $paths.CheckpointsRoot ([IO.Path]::GetFileName($source))
    $sourceHash = Get-SdwFileHashValue -Path $source
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $destinationHash = Get-SdwFileHashValue -Path $destination
        if ($destinationHash -eq $sourceHash) {
            Write-Output ("Model is already imported: {0}" -f $destination)
            return [pscustomobject]@{ path = $destination; sha256 = $sourceHash; imported = $false }
        }
        Throw-SdwError -Message ("A different model with the same file name already exists: {0}" -f $destination) -ExitCode 5
    }
    $partial = '{0}.partial.{1}' -f $destination, [Guid]::NewGuid().ToString('N')
    try {
        $input = [IO.File]::OpenRead($source)
        $output = New-Object IO.FileStream($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 1048576, [IO.FileOptions]::SequentialScan)
        try { $input.CopyTo($output); $output.Flush() }
        finally { $output.Dispose(); $input.Dispose() }
        $copiedHash = Get-SdwFileHashValue -Path $partial
        if ($copiedHash -ne $sourceHash) { Throw-SdwError -Message 'The imported model failed SHA-256 verification.' -ExitCode 8 }
        Move-Item -LiteralPath $partial -Destination $destination
        Write-Output ("Imported model: {0}" -f $destination)
        Write-Output ("SHA256: {0}" -f $copiedHash)
        return [pscustomobject]@{ path = $destination; sha256 = $copiedHash; imported = $true }
    }
    finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}

function Get-SdwStarterModelDefinition {
    param([Parameter(Mandatory = $true)]$Manifest)
    if ($Manifest.PSObject.Properties['models']) {
        $models = @($Manifest.models)
        if ($models.Count -eq 0) { Throw-SdwError -Message 'Starter model manifest contains no models.' -ExitCode 2 }
        return $models[0]
    }
    if ($Manifest.PSObject.Properties['assets']) {
        $assets = @($Manifest.assets)
        if ($assets.Count -eq 0) { Throw-SdwError -Message 'Starter model manifest contains no assets.' -ExitCode 2 }
        return $assets[0]
    }
    if ($Manifest.PSObject.Properties['starterModels']) { return @($Manifest.starterModels)[0] }
    return $Manifest
}

function Install-SdwStarterModel {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = $script:SdwRepositoryRoot,
        [string]$DataRoot,
        [switch]$AcceptLicense
    )

    $paths = Get-SdwPaths -RepositoryRoot $RepositoryRoot -DataRoot $DataRoot
    $manifest = Read-SdwJson -Path $paths.StarterModelsPath
    $model = Get-SdwStarterModelDefinition -Manifest $manifest
    $licenseValue = Get-SdwPropertyValue -Object $model -Names @('licenseUrl', 'license')
    if ($null -ne $licenseValue -and $licenseValue -isnot [string] -and $licenseValue.PSObject.Properties['url']) {
        $licenseUrl = [string]$licenseValue.url
    }
    else {
        $licenseUrl = [string]$licenseValue
    }
    if (-not $AcceptLicense) {
        Throw-SdwError -Message ("Downloading this model requires explicit -AcceptLicense. Review: {0}" -f $licenseUrl) -ExitCode 2
    }
    $url = [string](Get-SdwPropertyValue -Object $model -Names @('url', 'downloadUrl'))
    $fileName = [string](Get-SdwPropertyValue -Object $model -Names @('fileName', 'filename'))
    $size = [Int64](Get-SdwPropertyValue -Object $model -Names @('sizeBytes', 'bytes'))
    $sha = [string](Get-SdwPropertyValue -Object $model -Names @('sha256', 'sha256Hex'))
    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = [IO.Path]::GetFileName(([Uri]$url).AbsolutePath) }
    if ([IO.Path]::GetFileName($fileName) -ne $fileName -or -not $fileName.EndsWith('.safetensors', [StringComparison]::OrdinalIgnoreCase)) {
        Throw-SdwError -Message 'Starter model manifest contains an unsafe file name.' -ExitCode 2
    }
    Initialize-SdwLayout -Paths $paths
    Write-Output ("License accepted for this download: {0}" -f $licenseUrl)
    $destination = Join-Path $paths.CheckpointsRoot $fileName
    $output = @(Invoke-SdwDownload -Url $url -Destination $destination -ExpectedSize $size -ExpectedSha256 $sha -Label $fileName)
    foreach ($line in $output) { if ($line -is [string]) { Write-Output $line } }
    return [pscustomobject]@{ path = $destination; sha256 = $sha.ToLowerInvariant(); licenseUrl = $licenseUrl }
}

function Test-SdwPortAvailable {
    param([Parameter(Mandatory = $true)][int]$Port)
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    try { $listener.Start(); return $true }
    catch { return $false }
    finally { try { $listener.Stop() } catch { } }
}

function Test-SdwHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Url)
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri ($Url.TrimEnd('/') + '/internal/ping') -Method Get -TimeoutSec 3 -ErrorAction Stop
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
    }
    catch { return $false }
}

function Get-SdwProcessRecord {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    try {
        if ($PSVersionTable.PSVersion.Major -le 5) { return Get-WmiObject -Class Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction Stop }
        return Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction Stop
    }
    catch { return $null }
}

function Convert-SdwCimDate {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    try { return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Value).ToUniversalTime() }
    catch { return $null }
}

function Test-SdwProcessOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [switch]$Child
    )

    if ($Child) {
        $pidValue = [int]$State.childPid
        $expectedStart = $State.childStartedAtUtc
        $expectedPath = [string]$State.pythonPath
        $requiredCommands = @('launch.py')
    }
    else {
        $pidValue = [int]$State.supervisorPid
        $expectedStart = $State.supervisorStartedAtUtc
        $expectedPath = $null
        $requiredCommands = @([string]$State.ownerToken, [string]$State.supervisorPath)
    }
    $record = Get-SdwProcessRecord -ProcessId $pidValue
    if ($null -eq $record) { return $false }
    $created = Convert-SdwCimDate -Value $record.CreationDate
    try {
        # PowerShell 7 ConvertFrom-Json materializes ISO timestamps as DateTime,
        # while Windows PowerShell 5.1 leaves them as strings. Avoid converting a
        # DateTime to a culture-formatted string because that drops its UTC kind.
        if ($expectedStart -is [DateTime]) {
            $expectedUtc = ([DateTime]$expectedStart).ToUniversalTime()
        }
        elseif ($expectedStart -is [DateTimeOffset]) {
            $expectedUtc = ([DateTimeOffset]$expectedStart).UtcDateTime
        }
        else {
            $expectedUtc = [DateTimeOffset]::Parse(
                [string]$expectedStart,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).UtcDateTime
        }
    }
    catch { return $false }
    if ($null -eq $created -or [Math]::Abs(($created - $expectedUtc).TotalSeconds) -gt 5) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($expectedPath) -and
        -not [string]::IsNullOrWhiteSpace([string]$record.ExecutablePath) -and
        -not ([IO.Path]::GetFullPath([string]$record.ExecutablePath).Equals([IO.Path]::GetFullPath($expectedPath), [StringComparison]::OrdinalIgnoreCase))) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$record.CommandLine)) { return $false }
    foreach ($requiredCommand in $requiredCommands) {
        if ([string]::IsNullOrWhiteSpace($requiredCommand) -or ([string]$record.CommandLine).IndexOf($requiredCommand, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Test-SdwManagedRuntimeState {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        $State
    )
    if ($null -eq $State) { return $false }
    foreach ($propertyName in @('supervisorPath', 'dataRoot', 'port', 'ownerToken', 'supervisorPid', 'supervisorStartedAtUtc')) {
        if (-not $State.PSObject.Properties[$propertyName]) { return $false }
    }
    try {
        $recordedSupervisor = [IO.Path]::GetFullPath([string]$State.supervisorPath)
        $expectedSupervisor = [IO.Path]::GetFullPath([string]$Paths.SupervisorPath)
        $recordedDataRoot = [IO.Path]::GetFullPath([string]$State.dataRoot)
        if (-not $recordedSupervisor.Equals($expectedSupervisor, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not $recordedDataRoot.Equals([IO.Path]::GetFullPath([string]$Paths.DataRoot), [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ([int]$State.port -lt 1024 -or [int]$State.port -gt 65535) { return $false }
        return (Test-SdwProcessOwnership -State $State)
    }
    catch { return $false }
}

function Start-SdwSupervisorProcess {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)]$Active,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$OwnerToken
    )

    $powershell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) {
        $powershell = (Get-Process -Id $PID).Path
    }
    $trustedLaunchArgs = @($Active.launchArgs)
    if ($trustedLaunchArgs.Count -eq 0) { $launchArgsJson = '[]' }
    else { $launchArgsJson = $trustedLaunchArgs | ConvertTo-Json -Compress }
    $launchArgsBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($launchArgsJson))
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Paths.SupervisorPath,
        '-DataRoot', $Paths.DataRoot, '-RepositoryRoot', $Paths.RepositoryRoot,
        '-VersionPath', [string]$Active.versionPath, '-CheckoutPath', [string]$Active.checkoutPath,
        '-PythonPath', [string]$Active.pythonPath, '-GitPath', [string]$Active.gitPath,
        '-ProfileId', [string]$Active.profileId, '-UpstreamCommit', [string]$Active.upstreamCommit,
        '-Port', [string]$Port, '-OwnerToken', $OwnerToken, '-LogPath', $Paths.RuntimeLogPath,
        '-StatePath', $Paths.StatePath, '-TorchCommand', [string]$Active.torchCommand,
        '-LaunchArgsBase64', $launchArgsBase64
    )
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $powershell
    $info.Arguments = Join-SdwCommandLine -Arguments $arguments
    $info.WorkingDirectory = $Paths.RepositoryRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { Throw-SdwError -Message 'Failed to start the WebUI supervisor.' -ExitCode 6 }
    return $process
}

function Get-SdwOperationMutexName {
    param([Parameter(Mandatory = $true)][string]$DataRoot)
    $bytes = [Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($DataRoot)).ToLowerInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $suffix = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 24) }
    finally { $sha.Dispose() }
    return ('Local\StableDiffusionWorkbench-' + $suffix)
}

function Invoke-SdwStart {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = $script:SdwRepositoryRoot,
        [string]$DataRoot,
        [int]$Port,
        [int]$HealthTimeoutSeconds = 300
    )

    $paths = Get-SdwPaths -RepositoryRoot $RepositoryRoot -DataRoot $DataRoot
    $config = Get-SdwConfiguration -Paths $paths
    if ($Port -le 0) { $Port = [int]$config.port }
    if ($Port -lt 1024 -or $Port -gt 65535) { Throw-SdwError -Message 'Port must be between 1024 and 65535.' -ExitCode 2 }
    $activeRecord = Read-SdwJson -Path $paths.ActivePath -Optional
    $active = Get-SdwValidatedActiveRecord -Paths $paths -Active $activeRecord
    if ($null -eq $active) {
        Throw-SdwError -Message 'The runtime is not installed or failed validation. Run setup or repair first.' -ExitCode 3
    }
    $models = @(Get-SdwCheckpointFiles -Paths $paths)
    if ($models.Count -eq 0) { Throw-SdwError -Message 'No .safetensors checkpoint is installed. Import or download a model before starting.' -ExitCode 4 }

    Initialize-SdwLayout -Paths $paths
    $mutex = New-Object Threading.Mutex($false, (Get-SdwOperationMutexName -DataRoot $paths.DataRoot))
    $locked = $false
    try {
        $locked = $mutex.WaitOne(15000)
        if (-not $locked) { Throw-SdwError -Message 'Another start or stop operation is already in progress.' -ExitCode 5 }
        $existing = Read-SdwJson -Path $paths.StatePath -Optional
        if ($null -ne $existing -and (Test-SdwManagedRuntimeState -Paths $paths -State $existing)) {
            if ([int]$existing.port -ne $Port) {
                Throw-SdwError -Message ("A launcher-owned WebUI is already using port {0}. Stop it before changing to port {1}." -f $existing.port, $Port) -ExitCode 5
            }
            $existingUrl = 'http://127.0.0.1:{0}' -f [int]$existing.port
            if (Test-SdwHealth -Url $existingUrl) {
                Write-Output ("WebUI is already running at {0}" -f $existingUrl)
                return Get-SdwSummary -RepositoryRoot $RepositoryRoot -DataRoot $paths.DataRoot -Port $Port
            }
            Write-Output 'A launcher-owned WebUI is already starting; waiting for it to become healthy...'
        }
        else {
            if (-not (Test-SdwPortAvailable -Port $Port)) {
                Throw-SdwError -Message ("Port {0} is already in use. The launcher will not stop or replace an unrelated process." -f $Port) -ExitCode 5
            }
            $ownerToken = [Guid]::NewGuid().ToString('D')
            $process = Start-SdwSupervisorProcess -Paths $paths -Active $active -Port $Port -OwnerToken $ownerToken
            $supervisorPid = $process.Id
            $stateDeadline = [DateTime]::UtcNow.AddSeconds(10)
            $registered = $false
            while ([DateTime]::UtcNow -lt $stateDeadline) {
                $registeredState = Read-SdwJson -Path $paths.StatePath -Optional
                if ($null -ne $registeredState -and [string]$registeredState.ownerToken -eq $ownerToken) { $registered = $true; break }
                if ($process.HasExited) { break }
                Start-Sleep -Milliseconds 100
            }
            $process.Dispose()
            if (-not $registered) { Throw-SdwError -Message ("The WebUI supervisor (PID {0}) did not register its owned state. See {1}" -f $supervisorPid, $paths.RuntimeLogPath) -ExitCode 6 }
            Write-Output ("Starting WebUI on http://127.0.0.1:{0} ..." -f $Port)
        }
    }
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($HealthTimeoutSeconds)
    $url = 'http://127.0.0.1:{0}' -f $Port
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-SdwHealth -Url $url) {
            Write-Output ("WebUI is ready: {0}" -f $url)
            return Get-SdwSummary -RepositoryRoot $RepositoryRoot -DataRoot $paths.DataRoot -Port $Port
        }
        $state = Read-SdwJson -Path $paths.StatePath -Optional
        if ($null -ne $state -and $state.status -eq 'exited') {
            Throw-SdwError -Message ("WebUI exited during startup (exit code {0}). See {1}" -f $state.exitCode, $paths.RuntimeLogPath) -ExitCode 6
        }
        Start-Sleep -Seconds 2
    }
    Throw-SdwError -Message ("WebUI did not become healthy within {0} seconds. See {1}" -f $HealthTimeoutSeconds, $paths.RuntimeLogPath) -ExitCode 6
}

function Invoke-SdwApiPost {
    param([string]$Url)
    try {
        $null = Invoke-WebRequest -UseBasicParsing -Uri $Url -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 5 -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

function Invoke-SdwStop {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = $script:SdwRepositoryRoot,
        [string]$DataRoot,
        [int]$GraceSeconds = 25
    )

    $paths = Get-SdwPaths -RepositoryRoot $RepositoryRoot -DataRoot $DataRoot
    $mutex = New-Object Threading.Mutex($false, (Get-SdwOperationMutexName -DataRoot $paths.DataRoot))
    $locked = $false
    try {
        $locked = $mutex.WaitOne(15000)
        if (-not $locked) { Throw-SdwError -Message 'Another start or stop operation is already in progress.' -ExitCode 5 }
        $state = Read-SdwJson -Path $paths.StatePath -Optional
        if ($null -eq $state) { Write-Output 'WebUI is not running.'; return }
        if (-not (Test-SdwManagedRuntimeState -Paths $paths -State $state)) {
            if ($state.status -eq 'exited' -or $state.status -eq 'stopped') { Write-Output 'WebUI is not running.'; return }
            if ($state.PSObject.Properties['supervisorPid'] -and $null -eq (Get-SdwProcessRecord -ProcessId ([int]$state.supervisorPid))) {
                $state.status = 'stopped'
                $state | Add-Member -MemberType NoteProperty -Name stoppedAtUtc -Value ([DateTime]::UtcNow.ToString('o')) -Force
                Write-SdwJsonAtomic -Path $paths.StatePath -Value $state
                Write-Output 'WebUI process has already exited; stale runtime state was reconciled.'
                return
            }
            Throw-SdwError -Message 'Refusing to stop: the recorded supervisor identity does not match the live process. Run doctor.' -ExitCode 9
        }
        if (-not $state.PSObject.Properties['port'] -or [int]$state.port -lt 1024 -or [int]$state.port -gt 65535) {
            Throw-SdwError -Message 'Refusing to stop: runtime state contains an invalid port.' -ExitCode 9
        }

        $baseUrl = 'http://127.0.0.1:{0}' -f [int]$state.port
        Write-Output 'Requesting WebUI interrupt...'
        $null = Invoke-SdwApiPost -Url ($baseUrl + '/sdapi/v1/interrupt')
        Write-Output 'Requesting graceful WebUI shutdown...'
        $null = Invoke-SdwApiPost -Url ($baseUrl + '/sdapi/v1/server-stop')
        $deadline = [DateTime]::UtcNow.AddSeconds($GraceSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($null -eq (Get-SdwProcessRecord -ProcessId ([int]$state.supervisorPid))) {
                $state.status = 'stopped'
                $state | Add-Member -MemberType NoteProperty -Name stoppedAtUtc -Value ([DateTime]::UtcNow.ToString('o')) -Force
                Write-SdwJsonAtomic -Path $paths.StatePath -Value $state
                Write-Output 'WebUI stopped cleanly.'
                return
            }
            Start-Sleep -Milliseconds 500
        }

        if (-not (Test-SdwManagedRuntimeState -Paths $paths -State $state)) {
            Throw-SdwError -Message 'Refusing forced termination because process ownership changed while stopping.' -ExitCode 9
        }
        $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        Write-Output 'Graceful shutdown timed out; terminating the validated launcher-owned process tree...'
        $result = Invoke-SdwNativeCommand -FilePath $taskkill -Arguments @('/PID', [string]$state.supervisorPid, '/T', '/F') -AllowFailure
        if ($result.ExitCode -ne 0 -and $null -ne (Get-SdwProcessRecord -ProcessId ([int]$state.supervisorPid))) {
            Throw-SdwError -Message ("Unable to stop the validated process tree: {0}" -f $result.StandardError.Trim()) -ExitCode 6
        }
        $state.status = 'stopped'
        $state | Add-Member -MemberType NoteProperty -Name stoppedAtUtc -Value ([DateTime]::UtcNow.ToString('o')) -Force
        Write-SdwJsonAtomic -Path $paths.StatePath -Value $state
        Write-Output 'WebUI stopped.'
    }
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-SdwSummary {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = $script:SdwRepositoryRoot,
        [string]$DataRoot,
        [int]$Port,
        [string]$ProfileId
    )

    $paths = Get-SdwPaths -RepositoryRoot $RepositoryRoot -DataRoot $DataRoot
    $config = Get-SdwConfiguration -Paths $paths
    if ($Port -le 0) { $Port = [int]$config.port }
    if ([string]::IsNullOrWhiteSpace($ProfileId)) { $ProfileId = [string]$config.profileId }
    $profileName = $ProfileId
    try { $profile = Get-SdwProfile -RepositoryRoot $RepositoryRoot -ProfileId $ProfileId; $profileName = Get-SdwProfileDisplayName -Profile $profile; $ProfileId = Get-SdwProfileId -Profile $profile }
    catch { }
    $activeRecord = Read-SdwJson -Path $paths.ActivePath -Optional
    $active = Get-SdwValidatedActiveRecord -Paths $paths -Active $activeRecord
    $installed = ($null -ne $active)
    $models = @(Get-SdwCheckpointFiles -Paths $paths)
    $state = Read-SdwJson -Path $paths.StatePath -Optional
    $running = $false; $healthy = $false; $url = 'http://127.0.0.1:{0}' -f $Port
    $supervisorPid = $null; $childPid = $null; $status = 'notInstalled'; $message = 'Run setup to install the runtime.'
    if ($null -ne $state) {
        if ($state.PSObject.Properties['port'] -and [int]$state.port -ge 1024 -and [int]$state.port -le 65535) {
            $url = 'http://127.0.0.1:{0}' -f [int]$state.port
        }
        if ($state.PSObject.Properties['supervisorPid']) { $supervisorPid = $state.supervisorPid }
        if ($state.PSObject.Properties['childPid']) { $childPid = $state.childPid }
        $running = Test-SdwManagedRuntimeState -Paths $paths -State $state
        if ($running) { $healthy = Test-SdwHealth -Url $url }
    }
    if (-not $installed) { $status = 'notInstalled'; $message = 'Runtime is not installed or failed validation.' }
    elseif ($models.Count -eq 0) { $status = 'missingModel'; $message = 'Import or download a .safetensors checkpoint.' }
    elseif ($running -and $healthy) { $status = 'running'; $message = 'WebUI is running.' }
    elseif ($running) { $status = 'starting'; $message = 'WebUI process is starting but not healthy yet.' }
    elseif ($null -ne $state -and $state.status -eq 'exited' -and [int]$state.exitCode -ne 0) { $status = 'faulted'; $message = 'WebUI exited with an error. Check the log.' }
    elseif ($null -ne $state -and $state.status -eq 'running') { $status = 'stale'; $message = 'Runtime state is stale; run doctor.' }
    else { $status = 'ready'; $message = 'Ready to start.' }
    return [pscustomobject][ordered]@{
        schemaVersion = $script:SdwStateSchemaVersion
        status = $status
        message = $message
        dataRoot = $paths.DataRoot
        profileId = $ProfileId
        profileName = $profileName
        installed = $installed
        modelCount = $models.Count
        hasModel = ($models.Count -gt 0)
        running = $running
        healthy = $healthy
        port = $Port
        url = $url
        logPath = $paths.RuntimeLogPath
        activeVersion = $(if ($null -ne $active) { [string]$active.versionPath } else { $null })
        upstreamCommit = $(if ($null -ne $active) { [string]$active.upstreamCommit } else { $null })
        supervisorPid = $supervisorPid
        childPid = $childPid
    }
}

function New-SdwDoctorCheck {
    param([string]$Id, [string]$Status, [string]$Severity, [string]$Message, [string]$Fix)
    return [pscustomobject][ordered]@{ id = $Id; status = $Status; severity = $Severity; message = $Message; fix = $Fix }
}

function Invoke-SdwDoctor {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = $script:SdwRepositoryRoot,
        [string]$DataRoot,
        [int]$Port,
        [string]$ProfileId
    )
    $paths = Get-SdwPaths -RepositoryRoot $RepositoryRoot -DataRoot $DataRoot
    $config = Get-SdwConfiguration -Paths $paths
    if ($Port -le 0) { $Port = [int]$config.port }
    if ([string]::IsNullOrWhiteSpace($ProfileId)) { $ProfileId = [string]$config.profileId }
    $checks = New-Object Collections.Generic.List[object]

    $isWindows = $true
    if ($PSVersionTable.PSVersion.Major -ge 6) { $isWindows = [bool]$IsWindows }
    if ($isWindows -and [Environment]::Is64BitOperatingSystem) { $checks.Add((New-SdwDoctorCheck 'platform' 'pass' 'info' 'Windows x64 detected.' '')) }
    else { $checks.Add((New-SdwDoctorCheck 'platform' 'fail' 'error' 'Windows x64 is required.' 'Use a 64-bit Windows 10 or 11 host.')) }

    $gpu = Get-SdwGpuInfo
    if ($gpu.HasNvidia) { $checks.Add((New-SdwDoctorCheck 'nvidia' 'pass' 'info' ("NVIDIA GPU: {0}; driver {1}; VRAM {2} MiB." -f $gpu.DisplayName, $gpu.DriverVersion, $gpu.MemoryMiB) '')) }
    else { $checks.Add((New-SdwDoctorCheck 'nvidia' 'fail' 'error' 'No NVIDIA GPU was detected.' 'Install a supported NVIDIA GPU and current driver.')) }
    try {
        $profile = Get-SdwProfile -RepositoryRoot $RepositoryRoot -ProfileId $ProfileId
        $checks.Add((New-SdwDoctorCheck 'profile' 'pass' 'info' ("Selected profile: {0}." -f (Get-SdwProfileDisplayName -Profile $profile)) ''))
    }
    catch { $checks.Add((New-SdwDoctorCheck 'profile' 'fail' 'error' $_.Exception.Message 'Choose a valid bundled profile.')); $profile = $null }

    $existing = $paths.DataRoot
    while (-not (Test-Path -LiteralPath $existing) -and -not [string]::IsNullOrWhiteSpace($existing)) { $existing = Split-Path -Parent $existing }
    try {
        $root = [IO.Path]::GetPathRoot($existing)
        $drive = New-Object IO.DriveInfo($root)
        $freeGiB = [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        $diskStatus = $(if ($freeGiB -ge 15) { 'pass' } else { 'warn' })
        $checks.Add((New-SdwDoctorCheck 'disk' $diskStatus $(if ($diskStatus -eq 'pass') { 'info' } else { 'warning' }) ("Data disk free space: {0} GiB." -f $freeGiB) 'Keep at least 15 GiB free for runtime and one checkpoint.'))
    }
    catch { $checks.Add((New-SdwDoctorCheck 'disk' 'warn' 'warning' 'Could not determine available disk space.' 'Verify the selected data drive manually.')) }

    if (Test-SdwPathEncrypted -Path $paths.DataRoot) {
        $checks.Add((New-SdwDoctorCheck 'data-root-efs' 'fail' 'error' ("The selected data root inherits Windows EFS encryption: {0}. pip cannot reliably perform atomic package installs there." -f $paths.DataRoot) 'Choose an unencrypted local folder in Settings, such as D:\StableDiffusionWorkbench.'))
    }
    else {
        $checks.Add((New-SdwDoctorCheck 'data-root-efs' 'pass' 'info' 'The selected data root does not inherit Windows EFS encryption.' ''))
    }

    $activeRecord = Read-SdwJson -Path $paths.ActivePath -Optional
    $active = Get-SdwValidatedActiveRecord -Paths $paths -Active $activeRecord
    if ($null -eq $active) {
        $checks.Add((New-SdwDoctorCheck 'runtime' 'fail' 'error' 'No active runtime is installed.' 'Run setup.'))
    }
    else {
        $checks.Add((New-SdwDoctorCheck 'runtime' 'pass' 'info' 'Active runtime paths, profile, lock, exact commit, and tracked state are valid.' ''))
        if (Test-Path -LiteralPath ([string]$active.gitPath) -PathType Leaf) {
            $dirty = Invoke-SdwNativeCommand -FilePath ([string]$active.gitPath) -Arguments @('-C', [string]$active.checkoutPath, 'status', '--porcelain') -AllowFailure
            if ($dirty.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($dirty.StandardOutput)) { $checks.Add((New-SdwDoctorCheck 'upstream-dirty' 'pass' 'info' 'Upstream checkout is clean.' '')) }
            else { $checks.Add((New-SdwDoctorCheck 'upstream-dirty' 'warn' 'warning' 'Upstream checkout has local changes or could not be inspected.' 'Do not edit the managed upstream checkout; run repair if needed.')) }
        }
        if (Test-Path -LiteralPath ([string]$active.pythonPath) -PathType Leaf) {
            $python = Invoke-SdwNativeCommand -FilePath ([string]$active.pythonPath) -Arguments @('-c', 'import sys,pip,torch; print(sys.version.split()[0]); print(torch.__version__); print(torch.version.cuda or "none"); print(torch.cuda.is_available())') -WorkingDirectory ([string]$active.checkoutPath) -AllowFailure
            if ($python.ExitCode -eq 0 -and $python.StandardOutput -match '(?im)^True\s*$') {
                $checks.Add((New-SdwDoctorCheck 'python-torch' 'pass' 'info' ("Python/pip/Torch with CUDA: {0}" -f (($python.StandardOutput.Trim() -split "`r?`n") -join ', ')) ''))
            }
            else { $checks.Add((New-SdwDoctorCheck 'python-torch' 'fail' 'error' 'Python, pip, Torch, or CUDA validation failed.' 'Run repair and inspect setup.log; verify the NVIDIA driver.')) }

            $pipCheck = Invoke-SdwNativeCommand -FilePath ([string]$active.pythonPath) -Arguments @('-m', 'pip', 'check') -WorkingDirectory ([string]$active.checkoutPath) -AllowFailure
            if ($pipCheck.ExitCode -eq 0) {
                $checks.Add((New-SdwDoctorCheck 'python-dependencies' 'pass' 'info' 'Python package dependencies are consistent (pip check passed).' ''))
            }
            else {
                $dependencyMessage = (($pipCheck.StandardOutput + "`n" + $pipCheck.StandardError).Trim() -replace '\s+', ' ')
                if ([string]::IsNullOrWhiteSpace($dependencyMessage)) { $dependencyMessage = 'pip check returned a nonzero exit code.' }
                $checks.Add((New-SdwDoctorCheck 'python-dependencies' 'fail' 'error' ("Python package dependency validation failed: {0}" -f $dependencyMessage) 'Run repair and inspect setup.log.'))
            }
        }
    }

    $models = @(Get-SdwCheckpointFiles -Paths $paths)
    if ($models.Count -gt 0) { $checks.Add((New-SdwDoctorCheck 'model' 'pass' 'info' ("{0} .safetensors checkpoint(s) found." -f $models.Count) '')) }
    else { $checks.Add((New-SdwDoctorCheck 'model' 'fail' 'error' 'No .safetensors checkpoint was found.' 'Import a model or download the reviewed starter model.')) }

    $state = Read-SdwJson -Path $paths.StatePath -Optional
    if ($null -ne $state -and (Test-SdwManagedRuntimeState -Paths $paths -State $state)) {
        $healthUrl = 'http://127.0.0.1:{0}' -f [int]$state.port
        $healthy = Test-SdwHealth -Url $healthUrl
        $checks.Add((New-SdwDoctorCheck 'state' 'pass' 'info' 'Runtime state belongs to a live launcher supervisor.' ''))
        $checks.Add((New-SdwDoctorCheck 'health' $(if ($healthy) { 'pass' } else { 'warn' }) $(if ($healthy) { 'info' } else { 'warning' }) $(if ($healthy) { 'A1111 /internal/ping is healthy.' } else { 'Launcher process is alive but /internal/ping is not healthy.' }) 'Check webui.log.'))
    }
    elseif ($null -ne $state -and $state.status -eq 'running') {
        $checks.Add((New-SdwDoctorCheck 'state' 'warn' 'warning' 'Runtime state is stale; no matching supervisor process exists.' 'Start WebUI again; do not terminate processes by port.'))
    }
    else { $checks.Add((New-SdwDoctorCheck 'state' 'pass' 'info' 'No live launcher-owned runtime is recorded.' '')) }

    $portAvailable = Test-SdwPortAvailable -Port $Port
    $portOwned = ($null -ne $state -and (Test-SdwManagedRuntimeState -Paths $paths -State $state) -and [int]$state.port -eq $Port)
    if ($portAvailable -or $portOwned) { $checks.Add((New-SdwDoctorCheck 'port' 'pass' 'info' ("Port {0} is available or owned by this workbench." -f $Port) '')) }
    else { $checks.Add((New-SdwDoctorCheck 'port' 'fail' 'error' ("Port {0} is occupied by an unrelated process." -f $Port) 'Choose another port; the workbench will never kill by port alone.')) }

    $failCount = @($checks | Where-Object { $_.status -eq 'fail' }).Count
    $warnCount = @($checks | Where-Object { $_.status -eq 'warn' }).Count
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        ok = ($failCount -eq 0)
        failCount = $failCount
        warningCount = $warnCount
        dataRoot = $paths.DataRoot
        checks = $checks.ToArray()
    }
}

function Open-SdwLocation {
    [CmdletBinding()]
    param(
        [ValidateSet('ui', 'data', 'models', 'outputs', 'logs')][string]$Target,
        [string]$RepositoryRoot = $script:SdwRepositoryRoot,
        [string]$DataRoot
    )
    $paths = Get-SdwPaths -RepositoryRoot $RepositoryRoot -DataRoot $DataRoot
    if ($Target -ne 'ui') { Initialize-SdwLayout -Paths $paths }
    switch ($Target) {
        'ui' {
            $summary = Get-SdwSummary -RepositoryRoot $RepositoryRoot -DataRoot $paths.DataRoot
            if (-not $summary.healthy) { Throw-SdwError -Message 'WebUI is not healthy. Start it before opening the UI.' -ExitCode 6 }
            Start-Process $summary.url
            return $summary.url
        }
        'data' { $path = $paths.DataRoot }
        'models' { $path = $paths.ModelsRoot }
        'outputs' { $path = $paths.OutputsRoot }
        'logs' { $path = $paths.LogsRoot }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { Throw-SdwError -Message ("Directory does not exist yet: {0}" -f $path) -ExitCode 3 }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $path.Replace('"', ''))
    return $path
}

function Get-SdwLogs {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = $script:SdwRepositoryRoot,
        [string]$DataRoot,
        [int]$Tail = 200
    )
    $paths = Get-SdwPaths -RepositoryRoot $RepositoryRoot -DataRoot $DataRoot
    $files = @($paths.RuntimeLogPath, $paths.SetupLogPath) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    if ($files.Count -eq 0) { return 'No logs have been created yet.' }
    $result = New-Object Collections.Generic.List[string]
    foreach ($file in $files) {
        $result.Add(('===== {0} =====' -f $file))
        foreach ($line in (Get-Content -LiteralPath $file -Tail $Tail -ErrorAction SilentlyContinue)) { $result.Add($line) }
    }
    return ($result -join [Environment]::NewLine)
}

Export-ModuleMember -Function @(
    'New-SdwException', 'Get-SdwExitCode', 'Resolve-SdwDataRoot', 'Get-SdwPaths', 'Initialize-SdwLayout',
    'Read-SdwJson', 'Write-SdwJsonAtomic', 'ConvertTo-SdwCommandLineArgument',
    'Join-SdwCommandLine', 'Invoke-SdwNativeCommand', 'Get-SdwFileHashValue',
    'Test-SdwFileIntegrity', 'Invoke-SdwDownload', 'Expand-SdwPortableSystem',
    'Get-SdwGpuInfo', 'Get-SdwProfile', 'Set-SdwConfiguration', 'Get-SdwConfiguration',
    'Invoke-SdwSetup', 'Import-SdwModel', 'Install-SdwStarterModel',
    'Test-SdwPortAvailable', 'Test-SdwHealth', 'Test-SdwProcessOwnership',
    'Invoke-SdwStart', 'Invoke-SdwStop', 'Get-SdwSummary', 'Invoke-SdwDoctor',
    'Open-SdwLocation', 'Get-SdwLogs'
)
