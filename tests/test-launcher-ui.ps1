$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
$repo = Split-Path -Parent $PSScriptRoot
$source = Get-Content (Join-Path $repo 'launcher\StableDiffusionWorkbench.ps1') -Raw -Encoding UTF8
[xml]$xaml = Get-Content (Join-Path $repo 'launcher\StableDiffusionWorkbench.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader($xaml)))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Launcher syntax errors' }
foreach ($fn in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$names = @('stateLabel','profileLabel','gpuLabel','dataRootLabel','modelCountLabel','urlLink','operationLabel','actionGroup','logBox',
    'setupButton','startButton','stopButton','openUiButton','importButton','downloadButton','doctorButton','settingsButton',
    'openDataButton','openModelsButton','openOutputsButton','openLogsButton','HeroTitle','HeroDescription','StatusPillText','LogExpander','BusyBar')
foreach ($name in $names) {
    $control = $window.FindName($name)
    if ($null -eq $control) { throw "Missing control: $name" }
    Set-Variable -Name $name -Value $control -Scope Script
}
$script:PendingAction = $null; $script:ActiveProcess = $null; $script:ActivePurpose = $null
$script:ActiveDisplayName = ''; $script:OpenUiAfterStart = $false; $script:LauncherDataRoot = 'D:\Example'
$script:toolTip = New-Object PSObject
$toolTip | Add-Member ScriptMethod SetToolTip { param($control,$text) $control.ToolTip = $text }
function Queue-SdwAction { param($Command,$Parameters,$DisplayName) $script:Captured = $Command }
function Show-SdwLifecycleNotice { param($Message,$Title,$Icon) $script:Captured = 'notice' }
function Start-SdwStatusRefresh { $script:Captured = 'refresh' }
foreach ($name in @('startButton','stopButton','openUiButton','doctorButton','urlLink','openDataButton','openOutputsButton','openLogsButton')) {
    $pattern = '(?m)^\s*\$' + $name + '\.Add_Click\(\{[^\r\n]+\}\)'
    $binding = [regex]::Match($source, $pattern)
    if (-not $binding.Success) { throw "Missing click binding: $name" }
    . ([scriptblock]::Create($binding.Value))
}
foreach ($state in @('unconfigured','notinstalled','missingmodel','ready','starting','running','faulted','stale')) {
    Update-SdwSummaryView ([pscustomobject]@{ status=$state; running=($state -eq 'running'); healthy=($state -eq 'running'); installed=($state -notin @('unconfigured','notinstalled')); hasModel=($state -ne 'missingmodel'); modelCount=2; dataRoot='D:\Example'; url='http://127.0.0.1:7860' })
    if (-not $startButton.IsEnabled -or -not $stopButton.IsEnabled -or -not $openUiButton.IsEnabled) { throw "Primary action disabled: $state" }
    if ([string]::IsNullOrWhiteSpace($HeroTitle.Text)) { throw "Missing heading: $state" }
    foreach ($name in @('startButton','stopButton','openUiButton')) {
        $script:Captured = $null
        (Get-Variable $name -ValueOnly).RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $expected = 'notice'
        if ($name -eq 'startButton' -and $state -in @('ready','faulted','stale')) { $expected = 'start' }
        if ($name -eq 'openUiButton' -and $state -in @('ready','faulted','stale')) { $expected = 'start' }
        if ($name -eq 'openUiButton' -and $state -eq 'running') { $expected = 'open-ui' }
        if ($name -eq 'stopButton' -and $state -in @('running','starting')) { $expected = 'stop' }
        if ($script:Captured -ne $expected) { throw "Wrong action for $state / $name : $script:Captured, expected $expected" }
    }
}
$script:PendingAction = @{}
Update-SdwButtons
if ($doctorButton.IsEnabled -or $setupButton.IsEnabled -or -not $LogExpander.IsExpanded -or $BusyBar.Visibility -ne 'Visible') { throw 'Busy presentation is incorrect' }
foreach ($name in @('startButton','stopButton','openUiButton')) {
    $script:Captured = $null
    (Get-Variable $name -ValueOnly).RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    if ($Captured -ne 'notice') { throw 'Busy handler failed to explain the active task' }
}
foreach ($name in @('setupButton','importButton','downloadButton','settingsButton','openModelsButton')) {
    if ($source -notmatch ('\$' + $name + '\.Add_Click')) { throw "Missing action: $name" }
}
if ([Windows.Shell.WindowChrome]::GetWindowChrome($window).ResizeBorderThickness.Left -lt 1) { throw 'Resize chrome missing' }
$window.Close()
Write-Output 'PASS: WPF controls, window chrome, eight states, 24 lifecycle clicks, busy feedback, and all maintenance action bindings.'
