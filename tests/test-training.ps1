$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$lock=Get-Content (Join-Path $repo 'configs\training-lock.json') -Raw | ConvertFrom-Json
foreach($name in @('uv','kohya','scripts')) {
    if($lock.$name.url -notmatch '^https://' -or $lock.$name.sha256 -notmatch '^[a-f0-9]{64}$' -or $lock.$name.size -le 0){throw 'Invalid pinned asset'}
}
foreach($name in @('kohya','scripts')){if($lock.$name.commit -notmatch '^[a-f0-9]{40}$'){throw 'Floating source revision'}}
$source=Get-Content (Join-Path $repo 'scripts\training.ps1') -Raw
$hostSource=Get-Content (Join-Path $repo 'scripts\training-host.py') -Raw
foreach($required in @('UV_PYTHON_INSTALL_DIR','UV_PROJECT_ENVIRONMENT','PYTHONNOUSERSITE','HF_HOME','TORCH_HOME','GRADIO_TEMP_DIR','--frozen','--do_not_share','--do_not_use_shell','Get-TrainingProcess','StartTime.ToUniversalTime','CommandLine.Contains')) {
    if(-not $source.Contains($required)){throw "Missing isolation/safety control: $required"}
}
if($source -match '(?im)^\s*setx\b|\[Environment\]::SetEnvironmentVariable\s*\('){throw 'Global environment mutation'}
if(-not $hostSource.Contains('JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE')){throw 'Missing descendant cleanup'}
$status=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\sdw.ps1') -Command training-status
if($LASTEXITCODE -ne 0){throw 'Training status failed'}
$s=$status|ConvertFrom-Json
if($s.root -ne (Join-Path $repo 'data\training') -or $s.url -ne 'http://127.0.0.1:7861'){throw 'Wrong training location'}
Write-Output 'PASS: pinned assets, private environment, loopback, process ownership, descendant cleanup and CLI status.'
