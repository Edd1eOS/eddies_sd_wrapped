$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$profiles=@(Get-Content (Join-Path $repo 'configs\training-profiles.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
if(($profiles.id -join ',') -ne 'nvidia,intel-xpu,cpu,amd'){throw 'Unexpected training profiles'}
if(($profiles | Where-Object id -eq amd).enabled){throw 'Unverified AMD Windows installation must remain blocked'}
if(($profiles.port | Sort-Object -Unique).Count -ne 4){throw 'Training ports collide'}
foreach($id in @('intel-xpu','cpu')) {
    $raw=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts/sdw.ps1') -Command training-status -ProfileId $id
    if($LASTEXITCODE -ne 0){throw 'Profile status failed'}
    $status=$raw | ConvertFrom-Json
    if($status.profileId -ne $id -or $status.root -ne (Join-Path $repo ('data\training\backends\'+$id))){throw 'Training isolation failed'}
}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/training.ps1'),[ref]$tokens,[ref]$errors)
$function=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-TrainingDefaults'},$true)
. ([scriptblock]::Create($function.Extent.Text))
$root=Join-Path $repo ('data\training-defaults-test-'+[guid]::NewGuid().ToString('N'))
$datasets=Join-Path $repo 'datasets\lora';$output=Join-Path $repo 'training-runs';$ProfileId='intel-xpu'
$null=New-Item -ItemType Directory -Path $root
try {
    $path=Write-TrainingDefaults
    $content=Get-Content $path -Raw
    foreach($setting in @("optimizer = 'AdamW'","xformers = 'sdpa'","mixed_precision = 'no'")) {
        if(-not $content.Contains($setting)){throw "Unsafe non-CUDA default: $setting"}
    }
} finally {Remove-Item -LiteralPath (Join-Path $root 'config.toml');Remove-Item -LiteralPath $root}
$source=Get-Content (Join-Path $repo 'scripts/training.ps1') -Raw
if(-not $source.Contains('probe-training-device.py') -or -not $source.Contains('if(-not $PrepareOnly)')){throw 'Missing probe or activation protection'}
Write-Output 'PASS: isolated training profiles, distinct ports, safe Intel/CPU defaults, validation and preparation-only activation guard.'
