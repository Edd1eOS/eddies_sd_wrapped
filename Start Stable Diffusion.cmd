@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul

set "SDW_ROOT=%~dp0"
set "SDW_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SDW_LAUNCHER=%SDW_ROOT%launcher\StableDiffusionWorkbench.ps1"

if not exist "%SDW_POWERSHELL%" (
    echo Windows PowerShell 5.1 was not found.
    echo Expected: %SDW_POWERSHELL%
    exit /b 1
)

if not exist "%SDW_LAUNCHER%" (
    "%SDW_POWERSHELL%" -NoProfile -STA -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('启动器文件缺失。请重新下载完整仓库。','Stable Diffusion Workbench',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null"
    exit /b 1
)

start "" "%SDW_POWERSHELL%" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%SDW_LAUNCHER%"
exit /b 0
