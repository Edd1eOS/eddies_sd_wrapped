[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Management

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
// timer consume this thread-safe queue on the UI thread.
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
    $script:LauncherStateDirectory = Join-Path $env:LOCALAPPDATA 'StableDiffusionWorkbench.Launcher'
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

    $script:LauncherDataRoot = Import-SdwLauncherSettings
    if ([string]::IsNullOrWhiteSpace($script:LauncherDataRoot)) {
        # Portable default: keep all large/local data beside the cloned launcher,
        # under a git-ignored directory. The user can change it at any time.
        $script:LauncherDataRoot = Join-Path $script:RepositoryRoot 'data'
    }

    function New-SdwButton {
        param(
            [string]$Text,
            [int]$Width = 132,
            [System.Drawing.Color]$BackColor = [System.Drawing.Color]::White
        )
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Width = $Width
        $button.Height = 38
        $button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 10)
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(205, 211, 221)
        $button.BackColor = $BackColor
        $button.Cursor = [System.Windows.Forms.Cursors]::Hand
        return $button
    }

    function New-SdwValueLabel {
        param([string]$Text = '—')
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Dock = [System.Windows.Forms.DockStyle]::Fill
        $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $label.AutoEllipsis = $true
        $label.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
        return $label
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Stable Diffusion Workbench'
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Size = New-Object System.Drawing.Size(1120, 780)
    $form.MinimumSize = New-Object System.Drawing.Size(980, 700)
    $form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 251)
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $rootLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rootLayout.Padding = New-Object System.Windows.Forms.Padding(20, 16, 20, 18)
    $rootLayout.ColumnCount = 1
    $rootLayout.RowCount = 4
    [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 67)))
    [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 172)))
    [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 180)))
    [void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $form.Controls.Add($rootLayout)

    $headerPanel = New-Object System.Windows.Forms.Panel
    $headerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'Stable Diffusion Workbench'
    $titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(0, 1)
    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = '本地 AUTOMATIC1111 环境、模型和进程管理'
    $subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
    $subtitleLabel.AutoSize = $true
    $subtitleLabel.Location = New-Object System.Drawing.Point(3, 39)
    $operationLabel = New-Object System.Windows.Forms.Label
    $operationLabel.Text = '正在读取状态…'
    $operationLabel.AutoSize = $false
    $operationLabel.Width = 440
    $operationLabel.Height = 50
    $operationLabel.Dock = [System.Windows.Forms.DockStyle]::Right
    $operationLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $operationLabel.AutoEllipsis = $true
    $operationLabel.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)
    $headerPanel.Controls.AddRange(@($titleLabel, $subtitleLabel, $operationLabel))
    $rootLayout.Controls.Add($headerPanel, 0, 0)

    $statusGroup = New-Object System.Windows.Forms.GroupBox
    $statusGroup.Text = ' 当前状态 '
    $statusGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusGroup.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)
    $rootLayout.Controls.Add($statusGroup, 0, 1)

    $statusLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $statusLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusLayout.ColumnCount = 4
    $statusLayout.RowCount = 4
    [void]$statusLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 86)))
    [void]$statusLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    [void]$statusLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 86)))
    [void]$statusLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    1..4 | ForEach-Object {
        [void]$statusLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 25)))
    }
    $statusGroup.Controls.Add($statusLayout)

    function Add-SdwStatusCaption {
        param([string]$Text, [int]$Column, [int]$Row)
        $caption = New-Object System.Windows.Forms.Label
        $caption.Text = $Text
        $caption.Dock = [System.Windows.Forms.DockStyle]::Fill
        $caption.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $caption.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
        $statusLayout.Controls.Add($caption, $Column, $Row)
    }

    Add-SdwStatusCaption '整体状态' 0 0
    Add-SdwStatusCaption 'Profile' 2 0
    Add-SdwStatusCaption 'GPU' 0 1
    Add-SdwStatusCaption '存储位置' 0 2
    Add-SdwStatusCaption '已安装模型' 0 3
    Add-SdwStatusCaption '生成界面' 2 3

    $stateLabel = New-SdwValueLabel '正在检查…'
    $stateLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $profileLabel = New-SdwValueLabel
    $gpuLabel = New-SdwValueLabel $script:DetectedGpu
    $dataRootLabel = New-SdwValueLabel
    $modelCountLabel = New-SdwValueLabel
    $urlLink = New-Object System.Windows.Forms.LinkLabel
    $urlLink.Text = '—'
    $urlLink.Dock = [System.Windows.Forms.DockStyle]::Fill
    $urlLink.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $urlLink.AutoEllipsis = $true
    $urlLink.LinkBehavior = [System.Windows.Forms.LinkBehavior]::HoverUnderline
    $urlLink.Enabled = $false

    $statusLayout.Controls.Add($stateLabel, 1, 0)
    $statusLayout.Controls.Add($profileLabel, 3, 0)
    $statusLayout.Controls.Add($gpuLabel, 1, 1)
    $statusLayout.SetColumnSpan($gpuLabel, 3)
    $statusLayout.Controls.Add($dataRootLabel, 1, 2)
    $statusLayout.SetColumnSpan($dataRootLabel, 3)
    $statusLayout.Controls.Add($modelCountLabel, 1, 3)
    $statusLayout.Controls.Add($urlLink, 3, 3)

    $actionGroup = New-Object System.Windows.Forms.GroupBox
    $actionGroup.Text = ' 操作 '
    $actionGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actionGroup.Padding = New-Object System.Windows.Forms.Padding(14, 12, 14, 8)
    $rootLayout.Controls.Add($actionGroup, 0, 2)
    $actionFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $actionFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actionFlow.WrapContents = $true
    $actionFlow.AutoScroll = $true
    $actionFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $actionGroup.Controls.Add($actionFlow)

    $setupButton = New-SdwButton '准备 / 修复引擎' 154 ([System.Drawing.Color]::FromArgb(235, 242, 255))
    $startButton = New-SdwButton '启动引擎' 104 ([System.Drawing.Color]::FromArgb(220, 252, 231))
    $stopButton = New-SdwButton '停止引擎' 104 ([System.Drawing.Color]::FromArgb(254, 226, 226))
    $openUiButton = New-SdwButton '打开生成界面' 146 ([System.Drawing.Color]::FromArgb(219, 234, 254))
    $importButton = New-SdwButton '添加模型' 112
    $downloadButton = New-SdwButton '下载通用基础模型' 166
    $doctorButton = New-SdwButton '检查问题' 104
    $settingsButton = New-SdwButton '更改存储位置' 142
    $openDataButton = New-SdwButton '打开存储位置' 132
    $openModelsButton = New-SdwButton '模型管理' 112
    $openOutputsButton = New-SdwButton '输出管理' 112
    $openLogsButton = New-SdwButton '查看运行日志' 132
    $actionFlow.Controls.AddRange(@(
        $setupButton, $startButton, $stopButton, $openUiButton, $importButton,
        $downloadButton, $doctorButton, $settingsButton, $openDataButton,
        $openModelsButton, $openOutputsButton, $openLogsButton
    ))

    $logGroup = New-Object System.Windows.Forms.GroupBox
    $logGroup.Text = ' 运行日志（最多 600 行） '
    $logGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logGroup.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 12)
    $rootLayout.Controls.Add($logGroup, 0, 3)
    $logBox = New-Object System.Windows.Forms.RichTextBox
    $logBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logBox.ReadOnly = $true
    $logBox.WordWrap = $false
    $logBox.DetectUrls = $false
    $logBox.BackColor = [System.Drawing.Color]::FromArgb(20, 25, 34)
    $logBox.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $logGroup.Controls.Add($logBox)

    $toolTip = New-Object System.Windows.Forms.ToolTip
    if (-not [string]::IsNullOrWhiteSpace($script:LauncherDataRoot)) {
        $dataRootLabel.Text = $script:LauncherDataRoot
    }
    $toolTip.SetToolTip($dataRootLabel, '引擎、模型和生成结果统一保存在这里')
    $toolTip.SetToolTip($urlLink, '打开本地图片生成界面')

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
            ' 操作（当前任务执行中；为避免安装或运行环境损坏，相关按钮暂时锁定） '
        }
        else {
            ' 操作 '
        }

        $setupButton.Enabled = (-not $busy -and $stopped)
        # The three primary lifecycle controls stay clickable. Their handlers explain
        # unmet prerequisites instead of hiding the reason behind a disabled button.
        $startButton.Enabled = $true
        $stopButton.Enabled = $true
        $openUiButton.Enabled = $true
        $importButton.Enabled = $true
        $downloadButton.Enabled = $true
        $doctorButton.Enabled = -not $busy
        $settingsButton.Enabled = $true
        $openDataButton.Enabled = -not $busy
        $openModelsButton.Enabled = -not $busy
        $openOutputsButton.Enabled = -not $busy
        $openLogsButton.Enabled = -not $busy
        $urlLink.Enabled = (-not $busy -and $healthy -and (Test-SdwLoopbackUrl $url))

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
            'running' { $stateLabel.ForeColor = [System.Drawing.Color]::FromArgb(22, 101, 52) }
            'faulted' { $stateLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28) }
            'stale' { $stateLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28) }
            'starting' { $stateLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 83, 9) }
            default { $stateLabel.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55) }
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
        $urlLink.Text = $url
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
                $stateLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 83, 9)
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
        $dialog.Text = if ($InstallMode) { '确认本地引擎存储位置' } else { '存储位置与端口' }
        $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $dialog.MaximizeBox = $false
        $dialog.MinimizeBox = $false
        $dialog.ClientSize = New-Object System.Drawing.Size(620, 220)
        $dialog.Font = $form.Font

        $dataCaption = New-Object System.Windows.Forms.Label
        $dataCaption.Text = if ($InstallMode) { '存储位置（引擎、模型和生成结果）' } else { '存储位置' }
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
        $browseButton = New-Object System.Windows.Forms.Button
        $browseButton.Text = '浏览…'
        $browseButton.Location = New-Object System.Drawing.Point(504, 45)
        $browseButton.Size = New-Object System.Drawing.Size(94, 31)

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
        $saveButton.Text = if ($InstallMode) { '确认并安装' } else { '保存' }
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
            Show-SdwLifecycleNotice -Title '本地引擎尚未准备' -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning) -Message "当前存储位置尚未准备运行环境：`r`n$dataRoot`r`n`r`n请先点击“准备 / 修复引擎”。"
            return
        }
        if (-not $hasModel) {
            Show-SdwLifecycleNotice -Title '缺少生成模型' -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning) -Message "当前存储位置没有 .safetensors 模型：`r`n$dataRoot`r`n`r`n请点击“添加模型”或“下载通用基础模型”。"
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
            Show-SdwLifecycleNotice -Title '本地引擎尚未准备' -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning) -Message "当前存储位置尚未准备运行环境：`r`n$dataRoot`r`n`r`n请先点击“准备 / 修复引擎”。"
            return
        }
        if (-not $hasModel) {
            Show-SdwLifecycleNotice -Title '缺少生成模型' -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning) -Message "当前存储位置没有 .safetensors 模型：`r`n$dataRoot`r`n`r`n请点击“添加模型”或“下载通用基础模型”。"
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
    $urlLink.Add_LinkClicked({ Queue-SdwAction -Command 'open-ui' -Parameters ([ordered]@{}) -DisplayName '打开生成界面' })
    $openDataButton.Add_Click({ Queue-SdwAction -Command 'open-data' -Parameters ([ordered]@{}) -DisplayName '打开存储位置' })
    $openModelsButton.Add_Click({
        if (Test-SdwActionBusy) {
            Show-SdwBusyNotice
            return
        }
        Show-SdwLifecycleNotice -Title '模型管理' -Message "即将打开模型文件夹。`r`n`r`n• Checkpoint 主模型放入 Stable-diffusion`r`n• VAE 放入 VAE`r`n• LoRA 放入 Lora`r`n`r`n支持的模型文件优先使用 .safetensors。生成引擎正在运行时，新文件可能需要在生成界面点击刷新，或重新启动引擎后出现。"
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

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 120
    $timer.Add_Tick({
        Complete-SdwGpuProbe
        Drain-SdwProcessOutput
        Complete-SdwProcess

        if ($script:LogDirty) {
            $logBox.Lines = $script:LogHistory.ToArray()
            $logBox.SelectionStart = $logBox.TextLength
            $logBox.ScrollToCaret()
            $script:LogDirty = $false
        }

        if (-not $script:Closing -and $null -eq $script:ActiveProcess -and
            $null -eq $script:PendingAction -and
            ([datetime]::Now - $script:LastStatusStarted).TotalSeconds -ge 4) {
            Start-SdwStatusRefresh
        }
    })

    $form.Add_Shown({
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

    $form.Add_FormClosing({
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

    $form.Add_FormClosed({
        $timer.Stop()
        $timer.Dispose()
        Reset-SdwActiveProcess
        if ($null -ne $script:GpuProbe) {
            try { $script:GpuProbe.Stop() } catch {}
            try { $script:GpuProbe.Dispose() } catch {}
            $script:GpuProbe = $null
            $script:GpuProbeAsync = $null
        }
        $toolTip.Dispose()
        $form.Dispose()
    })

    Update-SdwButtons
    [void][System.Windows.Forms.Application]::Run($form)
    exit 0
}
catch {
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
