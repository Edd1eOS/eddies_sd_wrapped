[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('training-setup','training-open','training-stop','training-status','training-data','training-output','training-logs')]
    [string]$Command,
    [string]$DataRoot,
    [switch]$Json
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repo 'src\StableDiffusionWorkbench.Core.psm1') -Force -DisableNameChecking
$root=Join-Path $repo 'data\training'
$lock=Read-SdwJson -Path (Join-Path $repo 'configs\training-lock.json')
$checkout=Join-Path $root ('kohya-' + $lock.kohya.commit)
$venv=Join-Path $root 'venv'
$python=Join-Path $venv 'Scripts\python.exe'
$statePath=Join-Path $root 'service.json'
$readyPath=Join-Path $root 'ready.json'
$log=Join-Path $root 'logs\setup.log'
$url='http://127.0.0.1:' + $lock.port
$datasets=Join-Path $repo 'datasets\lora'
$output=Join-Path $repo 'training-runs'

function Get-TrainingProcess {
    if (-not (Test-Path $statePath)) { return $null }
    $s=Read-SdwJson -Path $statePath
    $p=Get-Process -Id $s.pid -ErrorAction SilentlyContinue
    if (-not $p -or $p.StartTime.ToUniversalTime().ToString('o') -ne $s.started) { return $null }
    $c=Get-CimInstance Win32_Process -Filter ("ProcessId=" + $s.pid)
    if ($c.ExecutablePath -ne $python -or -not $c.CommandLine.Contains($s.token) -or -not $c.CommandLine.Contains('training-host.py')) { return $null }
    return $p
}
function Test-TrainingReady {
    if (-not (Test-Path $python) -or -not (Test-Path $readyPath)) { return $false }
    $r=Read-SdwJson -Path $readyPath
    return ($r.commit -eq $lock.kohya.commit -and $r.root -eq $root -and (Test-Path (Join-Path $checkout 'kohya_gui.py')))
}
function Initialize-TrainingDirectories {
    foreach($p in @($root,$datasets,$output,(Join-Path $root 'downloads'),(Join-Path $root 'logs'),(Join-Path $root 'tmp'))) {
        $null=New-Item -ItemType Directory -Path $p -Force
    }
}
function Set-TrainingEnvironment {
    # Process-only variables, inherited by this tool's children. Never setx/global PATH.
    $env:UV_CACHE_DIR=Join-Path $root 'cache\uv'
    $env:UV_PYTHON_INSTALL_DIR=Join-Path $root 'python'
    $env:UV_PROJECT_ENVIRONMENT=$venv
    $env:UV_PYTHON_PREFERENCE='only-managed'
    $env:PYTHONNOUSERSITE='1'
    $env:PYTHONPATH=''
    $env:PYTHONHOME=''
    $env:VIRTUAL_ENV=$venv
    $env:HF_HOME=Join-Path $root 'cache\huggingface'
    $env:TORCH_HOME=Join-Path $root 'cache\torch'
    $env:PIP_CACHE_DIR=Join-Path $root 'cache\pip'
    $env:GRADIO_TEMP_DIR=Join-Path $root 'tmp\gradio'
    $env:TEMP=Join-Path $root 'tmp'
    $env:TMP=$env:TEMP
    $env:GRADIO_ANALYTICS_ENABLED='False'
    $env:HF_HUB_DISABLE_TELEMETRY='1'
    $env:PYTHONUTF8='1'
    $env:PYTHONIOENCODING='utf-8'
    $env:PATH=(Join-Path $venv 'Scripts') + ';' + $env:PATH
}
function Get-TrainingAsset($asset,[string]$name) {
    $destination=Join-Path $root ('downloads\'+$name)
    Invoke-SdwDownload -Url $asset.url -Destination $destination -ExpectedSize $asset.size -ExpectedSha256 $asset.sha256 -Label $name | Out-Host
    return $destination
}
function Invoke-TrainingInstall([string]$Executable,[string[]]$Arguments) {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Executable
    $info.Arguments=Join-SdwCommandLine -Arguments $Arguments
    $info.WorkingDirectory=$checkout
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $proc=New-Object Diagnostics.Process
    $proc.StartInfo=$info
    try {
        $null=$proc.Start()
        $readers=@($proc.StandardOutput,$proc.StandardError)
        $pending=@($readers[0].ReadLineAsync(),$readers[1].ReadLineAsync())
        while($null -ne $pending[0] -or $null -ne $pending[1]) {
            for($i=0;$i -lt 2;$i++) {
                if($null -ne $pending[$i] -and $pending[$i].IsCompleted) {
                    $line=$pending[$i].GetAwaiter().GetResult()
                    if($null -eq $line){$pending[$i]=$null}
                    else {Write-Output $line;Add-Content -LiteralPath $log -Value $line -Encoding UTF8;$pending[$i]=$readers[$i].ReadLineAsync()}
                }
            }
            Start-Sleep -Milliseconds 100
        }
        $proc.WaitForExit()
        if($proc.ExitCode -ne 0){throw "Environment installation failed ($($proc.ExitCode)); see $log. Click Configure again to retry."}
    } finally {$proc.Dispose()}
}
function Install-TrainingArchive($asset,[string]$name,[string]$target,[string]$inner) {
    if (Test-Path $target) { return }
    $zip=Get-TrainingAsset $asset $name
    $stage=Join-Path $root ('unpack-' + [guid]::NewGuid().ToString('N'))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip,$stage)
    $from=Join-Path $stage $inner
    if (-not [IO.Path]::GetFullPath($from).StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFullPath($target).StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Archive target escaped training directory.' }
    Move-Item -LiteralPath $from -Destination $target
}
function Write-TrainingDefaults {
    $config=Join-Path $root 'config.toml'
    if (-not (Test-Path $config)) {
        $models=Join-Path $repo 'Models\Checkpoints\v1-5-pruned-emaonly.safetensors'
        if(-not(Test-Path -LiteralPath $models -PathType Leaf)){$models=''}
        $models=$models.Replace('\','/')
        $ds=$datasets.Replace('\','/'); $out=$output.Replace('\','/')
        $logs=(Join-Path $root 'logs').Replace('\','/')
        $body=@"
[settings]
use_shell = false
[server]
allowed_paths = []
[model]
models_dir = '$models'
train_data_dir = '$ds'
output_name = 'my_character'
save_model_as = 'safetensors'
[folders]
output_dir = '$out'
logging_dir = '$logs'
"@
        [IO.File]::WriteAllText($config,$body,(New-Object Text.UTF8Encoding($false)))
    }
    return $config
}

try {
    if ($Command -eq 'training-status') {
        $p=Get-TrainingProcess
        [pscustomobject]@{installed=(Test-TrainingReady);running=($null -ne $p);url=$url;root=$root} | ConvertTo-Json -Compress
        exit 0
    }
    Initialize-TrainingDirectories
    if($Command -in @('training-data','training-output','training-logs')) {
        $target=switch($Command){'training-data'{$datasets};'training-output'{$output};'training-logs'{Join-Path $root 'logs'}}
        Start-Process explorer.exe -ArgumentList (ConvertTo-SdwCommandLineArgument $target)
        exit 0
    }
    if($Command -eq 'training-stop') {
        $p=Get-TrainingProcess
        if ($p) { Stop-Process -Id $p.Id -ErrorAction Stop; Write-Output 'Training UI and its child jobs stopped. Previously saved checkpoints remain.' }
        else { Write-Output 'No owned training UI is running.' }
        exit 0
    }
    Set-TrainingEnvironment
    if($Command -eq 'training-setup') {
        if(Get-TrainingProcess){throw 'Stop the training UI before configuring its environment.'}
        $guard=$null
        try {
            $guard=[IO.File]::Open((Join-Path $root 'setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            if(Test-TrainingReady){Write-Output 'Training environment is already configured.';exit 0}
            Write-Output 'Preparing isolated Kohya environment; downloads may require several GB. System Python and generation runtime are unchanged.'
            $uvzip=Get-TrainingAsset $lock.uv 'uv.zip'
            $uvdir=Join-Path $root 'uv'
            if(-not(Test-Path $uvdir)){Add-Type -AssemblyName System.IO.Compression.FileSystem;[IO.Compression.ZipFile]::ExtractToDirectory($uvzip,$uvdir)}
            $uv=(Get-ChildItem $uvdir -Recurse -Filter uv.exe | Select-Object -First 1).FullName
            Install-TrainingArchive $lock.kohya 'kohya.zip' $checkout ('kohya_ss-'+$lock.kohya.commit)
            $scriptsTarget=Join-Path $checkout 'sd-scripts'
            # Git archive can include an empty gitlink directory; remove only if empty.
            if((Test-Path $scriptsTarget) -and @(Get-ChildItem $scriptsTarget -Force).Count -eq 0){[IO.Directory]::Delete($scriptsTarget,$false)}
            Install-TrainingArchive $lock.scripts 'sd-scripts.zip' $scriptsTarget ('sd-scripts-'+$lock.scripts.commit)
            Write-Output 'Downloading private Python and installing the upstream frozen dependency lock. Please wait; details are written to setup.log.'
            Invoke-TrainingInstall -Executable $uv -Arguments @('sync','--frozen','--no-dev','--python',$lock.python,'--link-mode','copy')
            Write-Output 'Checking CUDA, training dependencies and GUI imports...'
            $check=Invoke-SdwNativeCommand -FilePath $python -Arguments @('-c','import torch,gradio,accelerate,transformers,kohya_gui; print(torch.__version__); print(torch.cuda.get_device_name(0)); assert torch.cuda.is_available(); x=torch.ones(1,device="cuda"); print((x+x).item())') -WorkingDirectory $checkout -LogPath $log
            Write-Output $check.StandardOutput
            $null=Write-TrainingDefaults
            Write-SdwJsonAtomic -Path $readyPath -Value @{commit=$lock.kohya.commit;root=$root;checkedAt=[DateTime]::UtcNow.ToString('o')}
            Write-Output 'Training environment ready. Open the training UI and select the LoRA tab. No training has been started.'
        } finally {if($guard){$guard.Dispose()}}
        exit 0
    }
    if(-not(Test-TrainingReady)){throw 'First click Configure training environment. See training logs if setup failed.'}
    $p=Get-TrainingProcess
    if(-not $p){
        if(-not(Test-SdwPortAvailable -Port $lock.port)){throw "Port $($lock.port) is occupied by another process; nothing was stopped."}
        $token=[guid]::NewGuid().ToString()
        $config=Write-TrainingDefaults
        $args=@((Join-Path $repo 'scripts\training-host.py'),'--owner-token',$token,'--checkout',$checkout,'--config',$config,'--listen','127.0.0.1','--server_port',[string]$lock.port,'--do_not_share','--do_not_use_shell','--noverify')
        $p=Start-Process -FilePath $python -ArgumentList (Join-SdwCommandLine -Arguments $args) -WorkingDirectory $checkout -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'logs\gui.log') -RedirectStandardError (Join-Path $root 'logs\gui-error.log')
        Write-SdwJsonAtomic -Path $statePath -Value @{pid=$p.Id;started=$p.StartTime.ToUniversalTime().ToString('o');token=$token}
    }
    Write-Output "Starting training UI at $url. This does not start GPU training. Stop generation engines before starting training."
    $deadline=[DateTime]::UtcNow.AddSeconds(120)
    do {
        if(-not(Get-TrainingProcess)){throw 'Training UI exited. Open training logs for details.'}
        try {$response=Invoke-WebRequest ($url+'/config') -UseBasicParsing -TimeoutSec 3;if($response.StatusCode -eq 200){Start-Process $url;Write-Output 'Training UI is ready. Select the LoRA tab.';exit 0}} catch {}
        Start-Sleep -Seconds 2
    } while([DateTime]::UtcNow -lt $deadline)
    throw 'Training UI is still starting or failed health check. Check training logs; retry Open training UI later.'
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
