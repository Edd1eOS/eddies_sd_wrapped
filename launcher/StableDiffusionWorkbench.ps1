[CmdletBinding()]
param([string]$PreviewPath, [int]$PreviewWidth = 1160, [int]$PreviewHeight = 820, [switch]$PreviewLogs, [switch]$LiveStatusPreview)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Management
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    if (-not ('SdwNativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class SdwNativeMethods
{
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetProcessDPIAware();
}

public sealed class SdwProcessOutputItem
{
    public string Id { get; private set; }
    public bool Error { get; private set; }
    public string Text { get; private set; }

    public SdwProcessOutputItem(string id, bool error, string text)
    {
        Id = id;
        Error = error;
        Text = text;
    }
}

// DataReceived callbacks run on thread-pool threads where PowerShell has no
// runspace. Keep those callbacks entirely in managed code and let the WinForms
// dispatcher consume this thread-safe queue on the UI thread.
public sealed class SdwProcessOutputPump
{
    private readonly ConcurrentQueue<object> queue;
    private readonly string id;

    public SdwProcessOutputPump(ConcurrentQueue<object> queue, string id)
    {
        this.queue = queue;
        this.id = id;
    }

    public void Attach(Process process)
    {
        process.OutputDataReceived += OnOutput;
        process.ErrorDataReceived += OnError;
    }

    public void Detach(Process process)
    {
        process.OutputDataReceived -= OnOutput;
        process.ErrorDataReceived -= OnError;
    }

    private void OnOutput(object sender, DataReceivedEventArgs args)
    {
        if (args.Data != null)
            queue.Enqueue(new SdwProcessOutputItem(id, false, args.Data));
    }

    private void OnError(object sender, DataReceivedEventArgs args)
    {
        if (args.Data != null)
            queue.Enqueue(new SdwProcessOutputItem(id, true, args.Data));
    }
}
'@
    }
    [void][SdwNativeMethods]::SetProcessDPIAware()
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    $script:RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:CliPath = Join-Path $script:RepositoryRoot 'scripts\sdw.ps1'
    $script:WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:LauncherStateDirectory = Join-Path $script:RepositoryRoot 'data\launcher'
    $script:LauncherStatePath = Join-Path $script:LauncherStateDirectory 'settings.json'
    $script:LauncherDataRoot = $null
    $script:LauncherSettingsWarning = $null

    if (-not (Test-Path -LiteralPath $script:WindowsPowerShell -PathType Leaf)) {
        throw "找不到 Windows PowerShell 5.1：$script:WindowsPowerShell"
    }
    if (-not (Test-Path -LiteralPath $script:CliPath -PathType Leaf)) {
        throw "找不到统一命令入口：$script:CliPath"
    }

    $script:AllowedCommands = @(
        'setup', 'repair', 'start', 'stop', 'status', 'doctor', 'configure',
        'import-model', 'download-starter-model', 'open-ui', 'open-data',
        'open-models', 'open-outputs', 'logs'
    )
    $script:OutputQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:LogHistory = New-Object 'System.Collections.Generic.Queue[string]'
    $script:MaximumLogLines = 600
    $script:ActiveProcess = $null
    $script:ActiveRunId = $null
    $script:ActivePurpose = $null
    $script:ActiveCommand = $null
    $script:ActiveDisplayName = $null
    $script:ActiveParameters = $null
    $script:ActiveOutput = $null
    $script:ActiveOutputPump = $null
    $script:PendingAction = $null
    $script:LastStatusStarted = [datetime]::MinValue
    $script:LastStatusErrorShown = [datetime]::MinValue
    $script:CurrentSummary = $null
    $script:DetectedGpu = '正在检测…'
    $script:GpuProbe = $null
    $script:GpuProbeAsync = $null
    $script:LogDirty = $false
    $script:Closing = $false
    $script:OpenUiAfterStart = $false

    function ConvertTo-SdwProcessArgument {
        param([AllowEmptyString()][string]$Value)

        if ($null -eq $Value -or $Value.Length -eq 0) {
            return '""'
        }
        if ($Value -notmatch '[\s"]') {
            return $Value
        }

        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $backslashes = 0
        foreach ($character in $Value.ToCharArray()) {
            if ($character -eq '\') {
                $backslashes++
                continue
            }
            if ($character -eq '"') {
                [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
                [void]$builder.Append('"')
                $backslashes = 0
                continue
            }
            if ($backslashes -gt 0) {
                [void]$builder.Append(('\' * $backslashes))
                $backslashes = 0
            }
            [void]$builder.Append($character)
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * ($backslashes * 2)))
        }
        [void]$builder.Append('"')
        return $builder.ToString()
    }

    function Join-SdwProcessArguments {
        param([string[]]$Tokens)
        return (($Tokens | ForEach-Object { ConvertTo-SdwProcessArgument -Value $_ }) -join ' ')
    }

    function Add-SdwLogLine {
        param([string]$Text)

        if ([string]::IsNullOrWhiteSpace($Text)) {
            return
        }
        $stamp = [datetime]::Now.ToString('HH:mm:ss')
        $script:LogHistory.Enqueue("[$stamp] $Text")
        while ($script:LogHistory.Count -gt $script:MaximumLogLines) {
            [void]$script:LogHistory.Dequeue()
        }
        $script:LogDirty = $true
    }

    function Import-SdwLauncherSettings {
        if (-not (Test-Path -LiteralPath $script:LauncherStatePath -PathType Leaf)) {
            return $null
        }
        try {
            $json = [System.IO.File]::ReadAllText($script:LauncherStatePath)
            $settings = $json | ConvertFrom-Json
            $dataRoot = [string]$settings.dataRoot
            if ([string]::IsNullOrWhiteSpace($dataRoot) -or -not [System.IO.Path]::IsPathRooted($dataRoot)) {
                throw 'settings.json 中的数据目录不是绝对路径。'
            }
            return [System.IO.Path]::GetFullPath($dataRoot)
        }
        catch {
            $script:LauncherSettingsWarning = "无法读取启动器设置：$($_.Exception.Message)"
            return $null
        }
    }

    function Save-SdwLauncherSettings {
        param([string]$DataRoot)

        if ([string]::IsNullOrWhiteSpace($DataRoot) -or -not [System.IO.Path]::IsPathRooted($DataRoot)) {
            throw '无法保存非绝对数据目录。'
        }
        $normalizedRoot = [System.IO.Path]::GetFullPath($DataRoot)
        [void][System.IO.Directory]::CreateDirectory($script:LauncherStateDirectory)
        $settings = [ordered]@{
            schemaVersion = 1
            dataRoot = $normalizedRoot
        }
        $json = $settings | ConvertTo-Json
        $temporaryPath = Join-Path $script:LauncherStateDirectory (
            'settings.{0}.tmp' -f [guid]::NewGuid().ToString('N')
        )
        try {
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8)
            if (Test-Path -LiteralPath $script:LauncherStatePath -PathType Leaf) {
                [System.IO.File]::Replace($temporaryPath, $script:LauncherStatePath, $null)
            }
            else {
                [System.IO.File]::Move($temporaryPath, $script:LauncherStatePath)
            }
            $script:LauncherDataRoot = $normalizedRoot
            $script:LauncherSettingsWarning = $null
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                [System.IO.File]::Delete($temporaryPath)
            }
        }
    }

    function Test-SdwLauncherPathEncrypted {
        param([Parameter(Mandatory = $true)][string]$Path)

        $candidate = [System.IO.Path]::GetFullPath($Path)
        while (-not (Test-Path -LiteralPath $candidate) -and -not [string]::IsNullOrWhiteSpace($candidate)) {
            $parent = Split-Path -Parent $candidate
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
                break
            }
            $candidate = $parent
        }
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $false
        }
        try {
            $attributes = (Get-Item -LiteralPath $candidate -Force).Attributes
            return (($attributes -band [System.IO.FileAttributes]::Encrypted) -eq [System.IO.FileAttributes]::Encrypted)
        }
        catch {
            return $false
        }
    }

    function Get-SdwObjectValue {
        param(
            [AllowNull()][object]$InputObject,
            [string[]]$Names,
            [AllowNull()][object]$DefaultValue = $null
        )

        if ($null -eq $InputObject) {
            return $DefaultValue
        }
        foreach ($name in $Names) {
            if ($InputObject -is [System.Collections.IDictionary]) {
                foreach ($key in $InputObject.Keys) {
                    if ([string]::Equals([string]$key, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return $InputObject[$key]
                    }
                }
            }
            $property = $InputObject.PSObject.Properties | Where-Object {
                [string]::Equals($_.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1
            if ($null -ne $property) {
                return $property.Value
            }
        }
        return $DefaultValue
    }

    function ConvertTo-SdwBoolean {
        param([AllowNull()][object]$Value)
        if ($Value -is [bool]) {
            return $Value
        }
        if ($null -eq $Value) {
            return $false
        }
        return ([string]$Value -match '^(?i:true|1|yes)$')
    }

    function Test-SdwLoopbackUrl {
        param([AllowNull()][object]$Value)
        if ($null -eq $Value) {
            return $false
        }
        $uri = $null
        if (-not [System.Uri]::TryCreate([string]$Value, [System.UriKind]::Absolute, [ref]$uri)) {
            return $false
        }
        return (($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https') -and $uri.IsLoopback)
    }

    function Start-SdwGpuProbe {
        if ($null -ne $script:GpuProbe) {
            return
        }
        $script:GpuProbe = [powershell]::Create()
        [void]$script:GpuProbe.AddScript(@'
try {
    Add-Type -AssemblyName System.Management
    $searcher = New-Object System.Management.ManagementObjectSearcher(
        'SELECT Name FROM Win32_VideoController WHERE Name IS NOT NULL'
    )
    $names = @($searcher.Get() | ForEach-Object { [string]$_.Name } | Where-Object { $_ })
    $preferred = @($names | Where-Object { $_ -match '(?i)NVIDIA|AMD|Radeon|Intel.*Arc' })
    if ($preferred.Count -gt 0) { $preferred -join ' / ' }
    elseif ($names.Count -gt 0) { $names -join ' / ' }
    else { '未检测到显卡' }
}
catch {
    '检测失败（可运行“诊断”查看）'
}
'@)
        $script:GpuProbeAsync = $script:GpuProbe.BeginInvoke()
    }

    function Complete-SdwGpuProbe {
        if ($null -eq $script:GpuProbe -or $null -eq $script:GpuProbeAsync -or
            -not $script:GpuProbeAsync.IsCompleted) {
            return
        }
        try {
            $result = @($script:GpuProbe.EndInvoke($script:GpuProbeAsync))
            $name = (($result | ForEach-Object { [string]$_ }) -join ' / ').Trim()
            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = '未检测到显卡'
            }
            $script:DetectedGpu = $name
        }
        catch {
            $script:DetectedGpu = '检测失败（可运行“诊断”查看）'
        }
        finally {
            $script:GpuProbe.Dispose()
            $script:GpuProbe = $null
            $script:GpuProbeAsync = $null
        }
        $gpuLabel.Text = $script:DetectedGpu
        $toolTip.SetToolTip($gpuLabel, $script:DetectedGpu)
    }

    # Each checkout owns its environment; do not inherit another installation's path.
    $script:LauncherDataRoot = Join-Path $script:RepositoryRoot 'data'
    if ([string]::IsNullOrWhiteSpace($script:LauncherDataRoot)) {
        # Portable default: keep all large/local data beside the cloned launcher,
        # under a git-ignored directory. The user can change it at any time.
        $script:LauncherDataRoot = Join-Path $script:RepositoryRoot 'data'
    }

    # Presentation only: keep the CLI, queue, settings and lifecycle handlers unchanged.
    [xml]$xaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'StableDiffusionWorkbench.xaml') -Raw -Encoding UTF8
    $window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader($xaml)))
    $form = New-Object System.Windows.Forms.NativeWindow
    $window.Add_SourceInitialized({ $form.AssignHandle(([Windows.Interop.WindowInteropHelper]::new($window)).Handle) })
    $window.FindName('MinimizeWindowButton').Add_Click({ $window.WindowState = 'Minimized' })
    $window.FindName('MaximizeWindowButton').Add_Click({
        if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' }
        else { $window.WindowState = 'Maximized' }
    })
    $window.FindName('CloseWindowButton').Add_Click({ $window.Close() })
    $controlNames = @('stateLabel','profileLabel','gpuLabel','dataRootLabel','modelCountLabel','urlLink',
        'operationLabel','actionGroup','logBox','setupButton','startButton','stopButton','openUiButton',
        'importButton','downloadButton','doctorButton','settingsButton','openDataButton','openModelsButton',
        'openOutputsButton','openLogsButton','HeroTitle','HeroDescription','StatusPillText','LogExpander','BusyBar')
    foreach ($name in $controlNames) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }
    $toolTip = New-Object PSObject
    $toolTip | Add-Member -MemberType ScriptMethod -Name SetToolTip -Value {
        param($control, [string]$text)
        $control.ToolTip = $text
    }
    $dataRootLabel.Text = $script:LauncherDataRoot

    function Get-SdwNormalizedState {
        param([AllowNull()][object]$Summary)

        if ($null -eq $Summary) {
            return 'unknown'
        }
        $state = [string](Get-SdwObjectValue $Summary @('status', 'state') 'unknown')
        $running = ConvertTo-SdwBoolean (Get-SdwObjectValue $Summary @('running') $false)
        $healthy = ConvertTo-SdwBoolean (Get-SdwObjectValue $Summary @('healthy') $false)
        if ($running -and $healthy) {
            return 'running'
        }
        if ($state -eq 'running' -and -not $healthy) {
            return 'starting'
        }
        return $state.ToLowerInvariant()
    }

    function Test-SdwActionBusy {
        return (($null -ne $script:PendingAction) -or
            ($null -ne $script:ActiveProcess -and $script:ActivePurpose -eq 'action'))
    }

    function Update-SdwButtons {
        $busy = Test-SdwActionBusy
        $hasSummary = $null -ne $script:CurrentSummary
        $state = Get-SdwNormalizedState $script:CurrentSummary
        $running = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('running') $false)
        $healthy = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('healthy') $false)
        $installed = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('installed') $false)
        $hasModel = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('hasModel') $false)
        $url = Get-SdwObjectValue $script:CurrentSummary @('url', 'webUiUrl') $null
        $stopped = (-not $running -and $state -ne 'starting')

        $actionGroup.Text = if ($busy) {
            '当前任务执行中，请等待完成；相关维护操作暂不可用。'
        }
        else {
            ''
        }

        $BusyBar.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
        if ($busy) { $LogExpander.IsExpanded = $true }
        $setupButton.IsEnabled = (-not $busy -and $stopped)
        # The three primary lifecycle controls stay clickable. Their handlers explain
        # unmet prerequisites instead of hiding the reason behind a disabled button.
        $startButton.IsEnabled = $true
        $stopButton.IsEnabled = $true
        $openUiButton.IsEnabled = $true
        $importButton.IsEnabled = $true
        $downloadButton.IsEnabled = $true
        $doctorButton.IsEnabled = -not $busy
        $settingsButton.IsEnabled = $true
        $openDataButton.IsEnabled = -not $busy
        $openModelsButton.IsEnabled = -not $busy
        $openOutputsButton.IsEnabled = -not $busy
        $openLogsButton.IsEnabled = -not $busy
        $urlLink.IsEnabled = (-not $busy -and $healthy -and (Test-SdwLoopbackUrl $url))

        if ($busy) {
            $busyText = if ([string]::IsNullOrWhiteSpace($script:ActiveDisplayName)) {
                '当前有任务正在执行。'
            }
            else {
                "当前正在执行：$($script:ActiveDisplayName)"
            }
            $toolTip.SetToolTip($startButton, $busyText)
            $toolTip.SetToolTip($stopButton, $busyText)
            $toolTip.SetToolTip($openUiButton, $busyText)
        }
        else {
            $startTip = if ($installed -and $hasModel -and $stopped) { '启动本地 Stable Diffusion 服务' } else { '点击查看当前无法启动的原因' }
            $stopTip = if ($running -or $state -eq 'starting') { '停止由本工作台启动的服务' } else { '当前没有正在运行的服务' }
            $openUiTip = if ($healthy) { '在浏览器中打开图片生成界面' } else { '点击后检查环境；就绪时将自动启动并打开生成界面' }
            $toolTip.SetToolTip($startButton, $startTip)
            $toolTip.SetToolTip($stopButton, $stopTip)
            $toolTip.SetToolTip($openUiButton, $openUiTip)
        }
    }

    function Update-SdwSummaryView {
        param([AllowNull()][object]$Summary)

        if ($null -eq $Summary) {
            return
        }
        $script:CurrentSummary = $Summary
        $state = Get-SdwNormalizedState $Summary
        $stateMap = @{
            unconfigured = '尚未配置'
            notinstalled = '尚未安装'
            missingmodel = '缺少可用模型'
            ready = '已就绪（未启动）'
            starting = '正在启动 / 等待健康检查'
            running = '运行中'
            stale = '进程状态异常'
            faulted = '发生故障'
            unknown = '状态未知'
        }
        $stateText = $stateMap[$state]
        if ([string]::IsNullOrWhiteSpace($stateText)) {
            $stateText = $state
        }
        $message = [string](Get-SdwObjectValue $Summary @('message') '')
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $stateLabel.Text = "$stateText — $message"
        }
        else {
            $stateLabel.Text = $stateText
        }
        switch ($state) {
            'running' { $stateLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#166534') }
            'faulted' { $stateLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#b91c1c') }
            'stale' { $stateLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#b91c1c') }
            'starting' { $stateLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#b45309') }
            default { $stateLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#1f2937') }
        }

        $StatusPillText.Text = $stateText
        $StatusPillText.Foreground = $stateLabel.Foreground
        $pillColor = if ($state -in @('ready','running')) { '#DCFCE7' }
                     elseif ($state -in @('stale','faulted')) { '#FCE6DF' }
                     else { '#FFF4D8' }
        $window.FindName('StatusPill').Background = [Windows.Media.BrushConverter]::new().ConvertFromString($pillColor)
        switch ($state) {
            'running' { $HeroTitle.Text = '创作界面已经准备好'; $HeroDescription.Text = '本地引擎正在运行，点击下面的按钮打开 WebUI。' }
            'ready' { $HeroTitle.Text = '点击下面的按钮打开 WebUI'; $HeroDescription.Text = '本地离线运行的图片工作站，环境与模型已就绪。' }
            'starting' { $HeroTitle.Text = '正在启动图片引擎'; $HeroDescription.Text = '第一次加载模型可能需要一点时间，进度可在运行详情中查看。' }
            'missingmodel' { $HeroTitle.Text = '运行环境已就绪，添加模型即可'; $HeroDescription.Text = '把主模型放进项目的 Models / Checkpoints，或点击「添加模型」。' }
            { $_ -in @('unconfigured', 'notinstalled') } { $HeroTitle.Text = '首次使用，一键配置运行环境'; $HeroDescription.Text = '自动准备独立 Python、依赖和图片引擎，全部放在项目内，无需手动配置 PATH。' }
            default { $HeroTitle.Text = '查看当前工作台状态'; $HeroDescription.Text = '可以先点击「检查问题」，运行详情中会显示原因和处理建议。' }
        }
        $profileName = [string](Get-SdwObjectValue $Summary @('profileName') '')
        $profileId = [string](Get-SdwObjectValue $Summary @('profileId', 'profile') '—')
        if ([string]::IsNullOrWhiteSpace($profileName)) {
            $profileLabel.Text = $profileId
        }
        else {
            $profileLabel.Text = "$profileName ($profileId)"
        }
        $dataRootLabel.Text = [string](Get-SdwObjectValue $Summary @('dataRoot') '—')
        $modelCount = Get-SdwObjectValue $Summary @('modelCount') 0
        $modelCountLabel.Text = [string]$modelCount
        $url = [string](Get-SdwObjectValue $Summary @('url', 'webUiUrl') '—')
        if ([string]::IsNullOrWhiteSpace($url)) {
            $url = '—'
        }
        $urlLink.Content = $url
        $toolTip.SetToolTip($dataRootLabel, $dataRootLabel.Text)
        $toolTip.SetToolTip($urlLink, $url)
        Update-SdwButtons
    }

    function Get-SdwValidatedTokens {
        param(
            [string]$Command,
            [System.Collections.IDictionary]$Parameters
        )

        if ($script:AllowedCommands -notcontains $Command) {
            throw "不允许的命令：$Command"
        }
        $tokens = New-Object 'System.Collections.Generic.List[string]'
        @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:CliPath, '-Command', $Command) |
            ForEach-Object { [void]$tokens.Add([string]$_) }

        if ($null -eq $Parameters) {
            return $tokens.ToArray()
        }
        foreach ($keyObject in $Parameters.Keys) {
            $key = [string]$keyObject
            $value = $Parameters[$keyObject]
            switch ($key) {
                'DataRoot' {
                    if ([string]::IsNullOrWhiteSpace([string]$value) -or -not [System.IO.Path]::IsPathRooted([string]$value)) {
                        throw '数据目录必须是绝对路径。'
                    }
                    [void]$tokens.Add('-DataRoot')
                    [void]$tokens.Add([System.IO.Path]::GetFullPath([string]$value))
                }
                'Port' {
                    $port = 0
                    if (-not [int]::TryParse([string]$value, [ref]$port) -or $port -lt 1024 -or $port -gt 65535) {
                        throw '端口必须是 1024 到 65535 之间的整数。'
                    }
                    [void]$tokens.Add('-Port')
                    [void]$tokens.Add($port.ToString([System.Globalization.CultureInfo]::InvariantCulture))
                }
                'ProfileId' {
                    if ([string]$value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
                        throw 'ProfileId 格式不正确。'
                    }
                    [void]$tokens.Add('-ProfileId')
                    [void]$tokens.Add([string]$value)
                }
                'Path' {
                    if ([string]::IsNullOrWhiteSpace([string]$value) -or -not [System.IO.Path]::IsPathRooted([string]$value)) {
                        throw '模型文件必须使用绝对路径。'
                    }
                    [void]$tokens.Add('-Path')
                    [void]$tokens.Add([System.IO.Path]::GetFullPath([string]$value))
                }
                'AcceptLicense' {
                    if (ConvertTo-SdwBoolean $value) {
                        [void]$tokens.Add('-AcceptLicense')
                    }
                }
                'Json' {
                    if (ConvertTo-SdwBoolean $value) {
                        [void]$tokens.Add('-Json')
                    }
                }
                default {
                    throw "不允许的参数：$key"
                }
            }
        }
        return $tokens.ToArray()
    }

    function Start-SdwProcess {
        param(
            [string]$Command,
            [System.Collections.IDictionary]$Parameters,
            [string]$DisplayName,
            [ValidateSet('action', 'status')][string]$Purpose
        )

        if ($null -ne $script:ActiveProcess) {
            throw '已有命令正在运行。'
        }
        $effectiveParameters = [ordered]@{}
        $hasExplicitDataRoot = $false
        if ($null -ne $Parameters) {
            foreach ($parameterKey in $Parameters.Keys) {
                if ([string]::Equals([string]$parameterKey, 'DataRoot', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $hasExplicitDataRoot = $true
                }
            }
        }
        if (-not $hasExplicitDataRoot -and -not [string]::IsNullOrWhiteSpace($script:LauncherDataRoot)) {
            $effectiveParameters['DataRoot'] = $script:LauncherDataRoot
        }
        if ($null -ne $Parameters) {
            foreach ($parameterKey in $Parameters.Keys) {
                $effectiveParameters[[string]$parameterKey] = $Parameters[$parameterKey]
            }
        }
        if (($Command -eq 'setup' -or $Command -eq 'repair') -and
            (-not $effectiveParameters.Contains('DataRoot') -or
             [string]::IsNullOrWhiteSpace([string]$effectiveParameters['DataRoot']))) {
            throw '准备或修复引擎前必须先确认存储位置。请点击“更改存储位置”。'
        }
        $tokens = Get-SdwValidatedTokens -Command $Command -Parameters $effectiveParameters
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:WindowsPowerShell
        $startInfo.Arguments = Join-SdwProcessArguments -Tokens $tokens
        $startInfo.WorkingDirectory = $script:RepositoryRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        $process.EnableRaisingEvents = $true
        $runId = [guid]::NewGuid().ToString('N')
        $outputPump = New-Object SdwProcessOutputPump -ArgumentList @($script:OutputQueue, $runId)
        $outputPump.Attach($process)

        if (-not $process.Start()) {
            throw '无法启动 Windows PowerShell 子进程。'
        }
        $script:ActiveProcess = $process
        $script:ActiveRunId = $runId
        $script:ActiveOutputPump = $outputPump
        $script:ActivePurpose = $Purpose
        $script:ActiveCommand = $Command
        $script:ActiveDisplayName = $DisplayName
        $script:ActiveParameters = $effectiveParameters
        $script:ActiveOutput = New-Object 'System.Collections.Generic.List[string]'
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        $script:LastStatusStarted = [datetime]::Now

        if ($Purpose -eq 'action') {
            Add-SdwLogLine "开始：$DisplayName"
            $operationLabel.Text = "正在执行：$DisplayName"
        }
        Update-SdwButtons
    }

    function Drain-SdwProcessOutput {
        $item = $null
        while ($script:OutputQueue.TryDequeue([ref]$item)) {
            if ($null -eq $item -or $item.Id -ne $script:ActiveRunId) {
                continue
            }
            if ($script:ActivePurpose -eq 'status') {
                if (-not $item.Error) {
                    [void]$script:ActiveOutput.Add($item.Text)
                }
                elseif (-not [string]::IsNullOrWhiteSpace($item.Text)) {
                    [void]$script:ActiveOutput.Add("__STDERR__ $($item.Text)")
                }
            }
            else {
                if ($item.Error) {
                    Add-SdwLogLine "错误：$($item.Text)"
                }
                else {
                    Add-SdwLogLine $item.Text
                }
            }
        }
    }

    function Reset-SdwActiveProcess {
        if ($null -ne $script:ActiveProcess) {
            try {
                if ($null -ne $script:ActiveOutputPump) {
                    $script:ActiveOutputPump.Detach($script:ActiveProcess)
                }
                $script:ActiveProcess.Dispose()
            }
            catch {}
        }
        $script:ActiveProcess = $null
        $script:ActiveRunId = $null
        $script:ActivePurpose = $null
        $script:ActiveCommand = $null
        $script:ActiveDisplayName = $null
        $script:ActiveParameters = $null
        $script:ActiveOutput = $null
        $script:ActiveOutputPump = $null
    }

    function Start-SdwStatusRefresh {
        if ($script:Closing -or $null -ne $script:ActiveProcess -or $null -ne $script:PendingAction) {
            return
        }
        try {
            $statusParameters = [ordered]@{ Json = $true }
            if (-not [string]::IsNullOrWhiteSpace($script:LauncherDataRoot)) {
                $statusParameters['DataRoot'] = $script:LauncherDataRoot
            }
            Start-SdwProcess -Command 'status' -Parameters $statusParameters -DisplayName '刷新状态' -Purpose 'status'
        }
        catch {
            Add-SdwLogLine "状态刷新失败：$($_.Exception.Message)"
        }
    }

    function Queue-SdwAction {
        param(
            [string]$Command,
            [System.Collections.IDictionary]$Parameters,
            [string]$DisplayName
        )

        if (Test-SdwActionBusy) {
            return
        }
        if ($null -ne $script:ActiveProcess -and $script:ActivePurpose -eq 'status') {
            $script:PendingAction = [pscustomobject]@{
                Command = $Command
                Parameters = $Parameters
                DisplayName = $DisplayName
            }
            $operationLabel.Text = "等待状态刷新后执行：$DisplayName"
            Update-SdwButtons
            return
        }
        try {
            Start-SdwProcess -Command $Command -Parameters $Parameters -DisplayName $DisplayName -Purpose 'action'
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                $_.Exception.Message,
                '无法执行命令',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    }

    function Complete-SdwProcess {
        if ($null -eq $script:ActiveProcess -or -not $script:ActiveProcess.HasExited) {
            return
        }
        $process = $script:ActiveProcess
        $purpose = $script:ActivePurpose
        $command = $script:ActiveCommand
        $displayName = $script:ActiveDisplayName
        $completedParameters = $script:ActiveParameters
        try { $process.WaitForExit() } catch {}
        Drain-SdwProcessOutput
        $exitCode = $process.ExitCode
        $captured = @($script:ActiveOutput)
        Reset-SdwActiveProcess

        if ($purpose -eq 'status') {
            if ($exitCode -eq 0) {
                try {
                    $jsonLines = @($captured | Where-Object { $_ -notlike '__STDERR__*' })
                    $json = $jsonLines -join [Environment]::NewLine
                    if ([string]::IsNullOrWhiteSpace($json)) {
                        throw 'CLI 没有返回状态数据。'
                    }
                    $summary = $json | ConvertFrom-Json
                    Update-SdwSummaryView $summary
                    $operationLabel.Text = '状态已同步'
                }
                catch {
                    if (([datetime]::Now - $script:LastStatusErrorShown).TotalSeconds -ge 30) {
                        Add-SdwLogLine "无法解析状态：$($_.Exception.Message)"
                        $script:LastStatusErrorShown = [datetime]::Now
                    }
                }
            }
            elseif (([datetime]::Now - $script:LastStatusErrorShown).TotalSeconds -ge 30) {
                $detail = (@($captured) -join ' ')
                Add-SdwLogLine "状态命令失败（退出码 $exitCode）：$detail"
                $script:LastStatusErrorShown = [datetime]::Now
            }

            if ($null -ne $script:PendingAction) {
                $pending = $script:PendingAction
                $script:PendingAction = $null
                try {
                    Start-SdwProcess -Command $pending.Command -Parameters $pending.Parameters -DisplayName $pending.DisplayName -Purpose 'action'
                }
                catch {
                    [void][System.Windows.Forms.MessageBox]::Show(
                        $form, $_.Exception.Message, '无法执行命令',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    )
                }
            }
            else {
                Update-SdwButtons
            }
            return
        }

        if ($exitCode -eq 0) {
            if ($command -eq 'configure') {
                try {
                    Save-SdwLauncherSettings -DataRoot ([string]$completedParameters['DataRoot'])
                    Add-SdwLogLine "启动器已记住存储位置：$($script:LauncherDataRoot)"
                }
                catch {
                    Add-SdwLogLine "设置已写入数据目录，但启动器无法记住该目录：$($_.Exception.Message)"
                    $operationLabel.Text = '无法保存启动器设置'
                    [void][System.Windows.Forms.MessageBox]::Show(
                        $form,
                        "数据目录中的配置已经写入，但启动器无法保存目录选择。`r`n`r`n$($_.Exception.Message)",
                        '启动器设置保存失败',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    )
                }
            }
            Add-SdwLogLine "完成：$displayName"
            if ($command -eq 'start') {
                $stateLabel.Text = '正在启动 / 等待健康检查'
                $stateLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#b45309')
                $operationLabel.Text = '启动命令已完成，正在确认生成界面状态…'
            }
            else {
                $operationLabel.Text = "$displayName 已完成"
            }
        }
        else {
            if ($command -eq 'start') {
                $script:OpenUiAfterStart = $false
            }
            Add-SdwLogLine "失败：$displayName（退出码 $exitCode）"
            $operationLabel.Text = "$displayName 失败"
            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                ('{0} 执行失败（退出码 {1}）。请查看下方日志，或点击“检查问题”。' -f $displayName, $exitCode),
                '命令执行失败',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
        Update-SdwButtons
        if ($exitCode -eq 0 -and $command -eq 'start' -and $script:OpenUiAfterStart) {
            $script:OpenUiAfterStart = $false
            Queue-SdwAction -Command 'open-ui' -Parameters ([ordered]@{}) -DisplayName '打开生成界面'
            return
        }
        Start-SdwStatusRefresh
    }

    function Show-SdwSettingsDialog {
        param([switch]$InstallMode)

        $running = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('running') $false)
        $state = Get-SdwNormalizedState $script:CurrentSummary
        if ($running -or $state -eq 'starting') {
            [void][System.Windows.Forms.MessageBox]::Show(
                $form, '请先停止生成引擎，再修改存储位置或端口。', '设置',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        $dialog = New-Object System.Windows.Forms.Form
        $dialog.Text = if ($InstallMode) { '一键配置运行环境' } else { '项目内环境与端口' }
        $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $dialog.MaximizeBox = $false
        $dialog.MinimizeBox = $false
        $dialog.ClientSize = New-Object System.Drawing.Size(620, 220)
        $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
        $dialog.BackColor = [System.Drawing.Color]::FromArgb(228, 241, 232)

        $dataCaption = New-Object System.Windows.Forms.Label
        $dataCaption.Text = '项目内运行环境（模型在 Models，生成结果在 Outputs）'
        $dataCaption.Location = New-Object System.Drawing.Point(20, 22)
        $dataCaption.AutoSize = $true
        $dataText = New-Object System.Windows.Forms.TextBox
        $dataText.Location = New-Object System.Drawing.Point(20, 47)
        $dataText.Size = New-Object System.Drawing.Size(470, 28)
        $currentDataRoot = [string]$script:LauncherDataRoot
        if ([string]::IsNullOrWhiteSpace($currentDataRoot)) {
            $currentDataRoot = [string](Get-SdwObjectValue $script:CurrentSummary @('dataRoot') '')
        }
        if ([string]::IsNullOrWhiteSpace($currentDataRoot)) {
            $currentDataRoot = Join-Path $script:RepositoryRoot 'data'
        }
        $dataText.Text = $currentDataRoot
        $dataText.ReadOnly = $true
        $browseButton = New-Object System.Windows.Forms.Button
        $browseButton.Text = '浏览…'
        $browseButton.Location = New-Object System.Drawing.Point(504, 45)
        $browseButton.Size = New-Object System.Drawing.Size(94, 31)
        $browseButton.Visible = $false

        $portCaption = New-Object System.Windows.Forms.Label
        $portCaption.Text = '本地端口（1024–65535）'
        $portCaption.Location = New-Object System.Drawing.Point(20, 91)
        $portCaption.AutoSize = $true
        $portInput = New-Object System.Windows.Forms.NumericUpDown
        $portInput.Location = New-Object System.Drawing.Point(20, 117)
        $portInput.Minimum = 1024
        $portInput.Maximum = 65535
        $currentPort = Get-SdwObjectValue $script:CurrentSummary @('port') 7860
        $parsedPort = 7860
        [void][int]::TryParse([string]$currentPort, [ref]$parsedPort)
        if ($parsedPort -lt 1024 -or $parsedPort -gt 65535) { $parsedPort = 7860 }
        $portInput.Value = $parsedPort

        $saveButton = New-Object System.Windows.Forms.Button
        $saveButton.Text = if ($InstallMode) { '一键配置' } else { '保存' }
        $saveButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $saveButton.Location = New-Object System.Drawing.Point(399, 169)
        $saveButton.Size = New-Object System.Drawing.Size(94, 34)
        $cancelButton = New-Object System.Windows.Forms.Button
        $cancelButton.Text = '取消'
        $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $cancelButton.Location = New-Object System.Drawing.Point(504, 169)
        $cancelButton.Size = New-Object System.Drawing.Size(94, 34)

        $browseButton.Add_Click({
            $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $folderDialog.Description = '选择 Stable Diffusion 存储位置'
            $folderDialog.ShowNewFolderButton = $true
            if (Test-Path -LiteralPath $dataText.Text -PathType Container) {
                $folderDialog.SelectedPath = $dataText.Text
            }
            if ($folderDialog.ShowDialog($dialog) -eq [System.Windows.Forms.DialogResult]::OK) {
                $dataText.Text = $folderDialog.SelectedPath
            }
            $folderDialog.Dispose()
        })
        $dialog.Controls.AddRange(@(
            $dataCaption, $dataText, $browseButton, $portCaption, $portInput,
            $saveButton, $cancelButton
        ))
        $dialog.AcceptButton = $saveButton
        $dialog.CancelButton = $cancelButton

        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                if ([string]::IsNullOrWhiteSpace($dataText.Text) -or -not [System.IO.Path]::IsPathRooted($dataText.Text)) {
                    throw '请选择一个绝对路径作为存储位置。'
                }
                $selectedRoot = [System.IO.Path]::GetFullPath($dataText.Text)
                if (Test-SdwLauncherPathEncrypted -Path $selectedRoot) {
                    throw "所选目录继承了 Windows EFS 加密，无法可靠安装 Python 包：$selectedRoot`r`n`r`n请选择未加密的本地目录，例如 D:\StableDiffusionWorkbench。"
                }
                if ($InstallMode) {
                    $confirmation = [System.Windows.Forms.MessageBox]::Show(
                        $dialog,
                        "Stable Diffusion 的隔离 Python、PyTorch、模型和输出将存放在：`r`n`r`n$selectedRoot`r`n`r`n安装不会修改系统 Python 或全局 PATH。是否开始安装？",
                        '确认安装位置',
                        [System.Windows.Forms.MessageBoxButtons]::YesNo,
                        [System.Windows.Forms.MessageBoxIcon]::Question,
                        [System.Windows.Forms.MessageBoxDefaultButton]::Button1
                    )
                    if ($confirmation -eq [System.Windows.Forms.DialogResult]::Yes) {
                        Save-SdwLauncherSettings -DataRoot $selectedRoot
                        $dataRootLabel.Text = $selectedRoot
                        $toolTip.SetToolTip($dataRootLabel, $selectedRoot)
                        Add-SdwLogLine "已确认引擎存储位置：$selectedRoot"
                        Queue-SdwAction -Command 'setup' -Parameters ([ordered]@{
                            DataRoot = $selectedRoot
                        }) -DisplayName '安装 Stable Diffusion'
                    }
                }
                else {
                    Queue-SdwAction -Command 'configure' -Parameters ([ordered]@{
                        DataRoot = $selectedRoot
                        Port = [int]$portInput.Value
                    }) -DisplayName '保存设置'
                }
            }
            catch {
                [void][System.Windows.Forms.MessageBox]::Show(
                    $form, $_.Exception.Message, '设置无效',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
            }
        }
        $dialog.Dispose()
    }

    function Get-SdwStarterAssetNotice {
        $manifestPath = Join-Path $script:RepositoryRoot 'asset-manifests\starter-models.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "找不到入门模型清单：$manifestPath"
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $asset = @($manifest.assets) | Select-Object -First 1
        if ($null -eq $asset -or [string]::IsNullOrWhiteSpace([string]$asset.url) -or
            $null -eq $asset.license -or [string]::IsNullOrWhiteSpace([string]$asset.license.url)) {
            throw '入门模型清单缺少来源或许可信息。'
        }
        $sizeBytes = [long]$asset.sizeBytes
        if ($sizeBytes -le 0) {
            throw '入门模型清单中的文件大小无效。'
        }
        return [pscustomobject]@{
            DisplayName = [string]$asset.displayName
            SourceUrl = [string]$asset.url
            SourceNote = [string]$asset.sourceNote
            LicenseName = if ([string]$asset.license.id -eq 'creativeml-openrail-m') {
                'CreativeML Open RAIL-M'
            }
            else {
                [string]$asset.license.id
            }
            LicenseUrl = [string]$asset.license.url
            SizeText = [string]::Format(
                [System.Globalization.CultureInfo]::InvariantCulture,
                '{0:F2} GB',
                ($sizeBytes / 1000000000.0)
            )
        }
    }

    function Show-SdwLifecycleNotice {
        param(
            [string]$Message,
            [string]$Title = 'Stable Diffusion Workbench',
            [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
        )
        [void][System.Windows.Forms.MessageBox]::Show(
            $form,
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            $Icon
        )
    }

    function Get-SdwDisplayedDataRoot {
        $summaryRoot = [string](Get-SdwObjectValue $script:CurrentSummary @('dataRoot') '')
        if (-not [string]::IsNullOrWhiteSpace($summaryRoot)) {
            return $summaryRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($script:LauncherDataRoot)) {
            return $script:LauncherDataRoot
        }
        return '(尚未选择)'
    }

    function Show-SdwBusyNotice {
        $taskName = if ([string]::IsNullOrWhiteSpace($script:ActiveDisplayName)) { '后台任务' } else { $script:ActiveDisplayName }
        Show-SdwLifecycleNotice -Title '任务正在执行' -Message "当前正在执行：$taskName`r`n`r`n完成后即可继续操作；进度与错误会显示在下方运行日志中。"
    }

    function Invoke-SdwStartFromUi {
        if (Test-SdwActionBusy) {
            Show-SdwBusyNotice
            return
        }
        if ($null -eq $script:CurrentSummary) {
            Show-SdwLifecycleNotice -Title '正在读取状态' -Message '启动器正在读取本地环境，请稍候再试。'
            Start-SdwStatusRefresh
            return
        }
        $state = Get-SdwNormalizedState $script:CurrentSummary
        $installed = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('installed') $false)
        $hasModel = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('hasModel') $false)
        $running = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('running') $false)
        $dataRoot = Get-SdwDisplayedDataRoot
        if ($running -or $state -eq 'starting') {
            Show-SdwLifecycleNotice -Title '服务已经启动' -Message 'Stable Diffusion 已经在运行或正在启动。可以点击“打开生成界面”。'
            return
        }
        if (-not $installed) {
            Show-SdwLifecycleNotice -Title '本地引擎尚未准备' -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning) -Message "项目内尚未配置运行环境：`r`n$dataRoot`r`n`r`n请先点击「一键配置 / 修复运行环境」。"
            return
        }
        if (-not $hasModel) {
            Show-SdwLifecycleNotice -Title '缺少生成模型' -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning) -Message "尚未找到模型，请放入项目 Models/Checkpoints 文件夹：`r`n$dataRoot`r`n`r`n请点击「添加模型」或「下载通用基础模型」。"
            return
        }
        Queue-SdwAction -Command 'start' -Parameters ([ordered]@{}) -DisplayName '启动 Stable Diffusion'
    }

    function Invoke-SdwStopFromUi {
        if (Test-SdwActionBusy) {
            Show-SdwBusyNotice
            return
        }
        $state = Get-SdwNormalizedState $script:CurrentSummary
        $running = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('running') $false)
        if (-not $running -and $state -ne 'starting') {
            Show-SdwLifecycleNotice -Title '服务未运行' -Message '当前没有由本工作台启动的 Stable Diffusion 服务，无需停止。'
            return
        }
        Queue-SdwAction -Command 'stop' -Parameters ([ordered]@{}) -DisplayName '停止 Stable Diffusion'
    }

    function Invoke-SdwOpenUiFromUi {
        if (Test-SdwActionBusy) {
            Show-SdwBusyNotice
            return
        }
        if ($null -eq $script:CurrentSummary) {
            Show-SdwLifecycleNotice -Title '正在读取状态' -Message '启动器正在读取本地环境，请稍候再试。'
            Start-SdwStatusRefresh
            return
        }
        $state = Get-SdwNormalizedState $script:CurrentSummary
        $installed = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('installed') $false)
        $hasModel = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('hasModel') $false)
        $running = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('running') $false)
        $healthy = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('healthy') $false)
        $url = [string](Get-SdwObjectValue $script:CurrentSummary @('url', 'webUiUrl') '')
        $dataRoot = Get-SdwDisplayedDataRoot
        if ($healthy -and (Test-SdwLoopbackUrl $url)) {
            Queue-SdwAction -Command 'open-ui' -Parameters ([ordered]@{}) -DisplayName '打开生成界面'
            return
        }
        if ($running -or $state -eq 'starting') {
            Show-SdwLifecycleNotice -Title '生成界面正在启动' -Message '生成引擎已经启动，但健康检查尚未通过。请稍候再次点击；如果长时间没有就绪，请查看下方日志。'
            return
        }
        if (-not $installed) {
            Show-SdwLifecycleNotice -Title '本地引擎尚未准备' -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning) -Message "项目内尚未配置运行环境：`r`n$dataRoot`r`n`r`n请先点击「一键配置 / 修复运行环境」。"
            return
        }
        if (-not $hasModel) {
            Show-SdwLifecycleNotice -Title '缺少生成模型' -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning) -Message "尚未找到模型，请放入项目 Models/Checkpoints 文件夹：`r`n$dataRoot`r`n`r`n请点击「添加模型」或「下载通用基础模型」。"
            return
        }
        $script:OpenUiAfterStart = $true
        Queue-SdwAction -Command 'start' -Parameters ([ordered]@{}) -DisplayName '启动并打开生成界面'
    }

    $setupButton.Add_Click({
        $state = Get-SdwNormalizedState $script:CurrentSummary
        $installed = ConvertTo-SdwBoolean (Get-SdwObjectValue $script:CurrentSummary @('installed') $false)
        if (-not $installed -or $state -eq 'unconfigured' -or $state -eq 'notinstalled') {
            Show-SdwSettingsDialog -InstallMode
        }
        else {
            Queue-SdwAction -Command 'repair' -Parameters ([ordered]@{}) -DisplayName '检查并修复环境'
        }
    })
    $startButton.Add_Click({ Invoke-SdwStartFromUi })
    $stopButton.Add_Click({ Invoke-SdwStopFromUi })
    $doctorButton.Add_Click({ Queue-SdwAction -Command 'doctor' -Parameters ([ordered]@{}) -DisplayName '检查运行问题' })
    $openUiButton.Add_Click({ Invoke-SdwOpenUiFromUi })
    $urlLink.Add_Click({ Queue-SdwAction -Command 'open-ui' -Parameters ([ordered]@{}) -DisplayName '打开生成界面' })
    $openDataButton.Add_Click({ Queue-SdwAction -Command 'open-data' -Parameters ([ordered]@{}) -DisplayName '打开存储位置' })
    $openModelsButton.Add_Click({
        if (Test-SdwActionBusy) {
            Show-SdwBusyNotice
            return
        }
        Show-SdwLifecycleNotice -Title '模型管理' -Message "现在打开的是模型管理文件夹。`r`n`r`n• 主模型放在 Checkpoints 文件夹，常见格式是 .safetensors 和 .ckpt；推荐优先使用更安全的 .safetensors。`r`n`r`n• VAE 是图像解析器，通常负责颜色和细节。文件名经常带 .vae，实际后缀多为 .safetensors、.pt 或 .ckpt。`r`n`r`n• Hypernetworks 和 LoRA 都是用来追加权重效果的扩展，原理不同，但使用目的比较接近。`r`n`r`n• Codeformer 和 GFPGAN 是人脸修复工具，不是主模型，平时不用手动管理。`r`n`r`n生成引擎正在运行时，新文件可能需要在生成界面点击刷新，或重新启动引擎后出现。"
        Queue-SdwAction -Command 'open-models' -Parameters ([ordered]@{}) -DisplayName '打开模型管理'
    })
    $openOutputsButton.Add_Click({ Queue-SdwAction -Command 'open-outputs' -Parameters ([ordered]@{}) -DisplayName '打开输出管理' })
    $openLogsButton.Add_Click({ Queue-SdwAction -Command 'logs' -Parameters ([ordered]@{}) -DisplayName '查看运行日志' })
    $settingsButton.Add_Click({
        if (Test-SdwActionBusy) {
            Show-SdwBusyNotice
        }
        else {
            Show-SdwSettingsDialog
        }
    })

    $importButton.Add_Click({
        if (Test-SdwActionBusy) {
            Show-SdwBusyNotice
            return
        }
        $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $fileDialog.Title = '添加 Stable Diffusion 模型'
        $fileDialog.Filter = 'SafeTensors 模型 (*.safetensors)|*.safetensors'
        $fileDialog.CheckFileExists = $true
        $fileDialog.Multiselect = $false
        if ($fileDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            if (-not [string]::Equals(
                [System.IO.Path]::GetExtension($fileDialog.FileName),
                '.safetensors',
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    $form, '当前版本只允许导入 .safetensors 模型。', '不支持的文件',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
            }
            else {
                Queue-SdwAction -Command 'import-model' -Parameters ([ordered]@{ Path = $fileDialog.FileName }) -DisplayName '导入模型'
            }
        }
        $fileDialog.Dispose()
    })

    $downloadButton.Add_Click({
        if (Test-SdwActionBusy) {
            Show-SdwBusyNotice
            return
        }
        try {
            $asset = Get-SdwStarterAssetNotice
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                $form, $_.Exception.Message, '无法读取模型清单',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
            return
        }
        $confirmation = @"
即将下载通用基础模型：$($asset.DisplayName)
下载大小：约 $($asset.SizeText)

来源：
$($asset.SourceUrl)
$($asset.SourceNote)

许可：$($asset.LicenseName)
$($asset.LicenseUrl)

模型许可可能对用途和分发设有限制。继续表示你已阅读并接受上述许可。

是否继续下载？
"@
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $form,
            $confirmation,
            '确认模型来源与许可',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            Queue-SdwAction -Command 'download-starter-model' -Parameters ([ordered]@{ AcceptLicense = $true }) -DisplayName "下载通用基础模型（$($asset.SizeText)）"
        }
    })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({
        Complete-SdwGpuProbe
        Drain-SdwProcessOutput
        Complete-SdwProcess

        if ($script:LogDirty) {
            $logBox.Text = $script:LogHistory.ToArray() -join [Environment]::NewLine
            $logBox.ScrollToEnd()
            $script:LogDirty = $false
        }

        if (-not $script:Closing -and $null -eq $script:ActiveProcess -and
            $null -eq $script:PendingAction -and
            ([datetime]::Now - $script:LastStatusStarted).TotalSeconds -ge 4) {
            Start-SdwStatusRefresh
        }
    })

    $window.Add_ContentRendered({
        if (-not [string]::IsNullOrWhiteSpace($PreviewPath) -and -not $LiveStatusPreview) { return }
        if ($script:LastStatusStarted -ne [datetime]::MinValue) { return }
        Add-SdwLogLine '启动器已就绪。所有安装和运行命令将通过 scripts\sdw.ps1 执行。'
        if (-not [string]::IsNullOrWhiteSpace($script:LauncherDataRoot)) {
            Add-SdwLogLine "已加载存储位置：$script:LauncherDataRoot"
        }
        if (-not [string]::IsNullOrWhiteSpace($script:LauncherSettingsWarning)) {
            Add-SdwLogLine $script:LauncherSettingsWarning
        }
        Start-SdwGpuProbe
        $timer.Start()
        Start-SdwStatusRefresh
    })

    $window.Add_Closing({
        param($sender, $eventArgs)
        $script:Closing = $true
        $timer.Stop()
        if ($null -ne $script:ActiveProcess -and -not $script:ActiveProcess.HasExited -and
            $script:ActivePurpose -eq 'action') {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                $form,
                '当前操作仍在执行。关闭启动器不会主动停止已启动的 WebUI，但可能中断安装或下载命令。是否仍要关闭？',
                '操作仍在运行',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                $eventArgs.Cancel = $true
                $script:Closing = $false
                $timer.Start()
            }
        }
    })

    $window.Add_Closed({
        $timer.Stop()
        Reset-SdwActiveProcess
        if ($null -ne $script:GpuProbe) {
            try { $script:GpuProbe.Stop() } catch {}
            try { $script:GpuProbe.Dispose() } catch {}
            $script:GpuProbe = $null
            $script:GpuProbeAsync = $null
        }
        $form.ReleaseHandle()
    })

    Update-SdwButtons
    if (-not [string]::IsNullOrWhiteSpace($PreviewPath)) {
        $window.Width = $PreviewWidth; $window.Height = $PreviewHeight
        $window.ShowActivated = $false; $window.ShowInTaskbar = $false
        $window.Left = -20000; $window.Top = -20000
        Update-SdwSummaryView ([pscustomobject]@{ status='ready'; running=$false; healthy=$false; installed=$true; hasModel=$true; dataRoot=$script:LauncherDataRoot; modelCount=2; url='http://127.0.0.1:7860'; profileName='Windows + NVIDIA'; profileId='blackwell-experimental' })
        $gpuLabel.Text = 'NVIDIA GeForce RTX 5070 Laptop GPU'
        $operationLabel.Text = '状态已同步'
        $LogExpander.IsExpanded = [bool]$PreviewLogs
        $logBox.Text = '[预览] 运行日志显示在这里。'
        $window.Show()
        if ($LiveStatusPreview) {
            # Exercise the real dispatcher, GPU probe and read-only status subprocess.
            $script:CurrentSummary = $null
            $frame = New-Object Windows.Threading.DispatcherFrame
            $timeout = New-Object Windows.Threading.DispatcherTimer
            $timeout.Interval = [TimeSpan]::FromSeconds(12)
            $timeout.Add_Tick({ $frame.Continue = $false })
            $timeout.Start()
            try { [Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $timeout.Stop() }
            if ($null -eq $script:CurrentSummary) { $window.Close(); throw 'Live status preview did not receive a backend summary.' }
            Write-Output ('Live status: ' + (Get-SdwNormalizedState $script:CurrentSummary))
        }
        $window.UpdateLayout()
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth, [int]$window.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($window)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $output = [IO.Path]::GetFullPath($PreviewPath)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output))
        $stream = [IO.File]::Create($output)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
        $window.Close()
        Write-Output $output
    }
    else { [void]$window.ShowDialog() }
    exit 0
}
catch {
    if (-not [string]::IsNullOrWhiteSpace($PreviewPath)) { throw }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show(
            "图形启动器无法初始化。`r`n`r`n$($_.Exception.Message)",
            'Stable Diffusion Workbench',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
    catch {
        Write-Error $_
    }
    exit 1
}
