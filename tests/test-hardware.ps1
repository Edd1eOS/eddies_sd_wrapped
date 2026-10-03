$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'src\StableDiffusionWorkbench.Core.psm1') -Force
$module = Get-Module StableDiffusionWorkbench.Core
$lock = Get-Content (Join-Path $repo 'configs\upstream-lock.json') -Raw | ConvertFrom-Json
foreach ($id in @('windows-intel-directml','windows-amd-directml','windows-cpu','windows-nvidia-standard','windows-nvidia-blackwell')) {
    $profile = Get-SdwProfile -RepositoryRoot $repo -ProfileId $id
    if ($lock.upstream.profiles.$id.commit -ne $profile.upstreamCommit) { throw 'Lock mismatch' }
    if ($id -like '*directml' -and ($profile.launchArgs -notcontains '--use-directml' -or $profile.torchCommand -notmatch 'torch-directml==')) { throw 'Missing DirectML setup' }
}
& $module {
    param($repo)
    foreach ($case in @(@('Intel Arc A770','windows-intel-directml'),@('AMD Radeon RX 7800','windows-amd-directml'),@('','windows-cpu'))) {
        $script:testGpuName=$case[0]
        function script:Get-SdwGpuInfo { [pscustomobject]@{HasNvidia=$false;IsBlackwell=$false;DisplayName=$script:testGpuName} }
        if ((Get-SdwProfile -RepositoryRoot $repo -ProfileId auto).id -ne $case[1]) { throw 'Auto profile detection failed' }
    }
} $repo
Add-Type -AssemblyName PresentationFramework
[xml]$xaml=Get-Content (Join-Path $repo 'launcher\StableDiffusionWorkbench.xaml') -Raw -Encoding UTF8
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
if ($null -eq $window.FindName('hardwareButton')) { throw 'Hardware entry missing' }
$window.Close()
$source=Get-Content (Join-Path $repo 'src\StableDiffusionWorkbench.Core.psm1') -Raw
if ($source -notmatch "\+ \`$launchArguments" -or $source -notmatch 'Get-SdwProfileRepository' -or $source -notmatch "'--device-id'") { throw 'Backend wiring incomplete' }
Write-Output 'PASS: five pinned profiles, hardware detection, DirectML install flags, per-vendor device selection and WPF entry.'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\supervisor.ps1'), [ref]$tokens, [ref]$parseErrors)
$ensureFunction = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Ensure-SdwUiSettings' }, $true)
. ([scriptblock]::Create($ensureFunction.Extent.Text))
$settingsTest = Join-Path $repo ('data\hardware-settings-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $settingsTest
try {
    Ensure-SdwUiSettings -UserDataRoot $settingsTest -DirectML
    $settings = Get-Content (Join-Path $settingsTest 'config.json') -Raw | ConvertFrom-Json
    if ($settings.directml_memory_provider -ne 'None') { throw 'DirectML must not default to fragile Windows PDH counters' }
    if ($settings.quicksettings_list -notcontains 'sd_vae') { throw 'VAE selector lost' }
    Write-Output 'PASS: DirectML initial UI settings avoid PDH counters and retain model selectors.'
}
finally {
    Remove-Item -LiteralPath (Join-Path $settingsTest 'config.json') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $settingsTest
}
