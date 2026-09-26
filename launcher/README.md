# Windows 图形启动器

`StableDiffusionWorkbench.ps1` 是仓库的 Windows 桌面入口。它使用 Windows PowerShell 5.1 和 WinForms，不要求用户预先安装 Node.js、Python GUI 库或其他启动器依赖。

普通用户应双击仓库根目录的 `Start Stable Diffusion.cmd`，不要直接执行本文件夹中的脚本。启动器只调用统一 CLI `scripts/sdw.ps1`，不直接修改 AUTOMATIC1111 的启动脚本、进程或模型目录。

## 当前功能

- 显示安装/运行状态、Profile、GPU、数据目录、模型数量和本地 WebUI 地址。
- 一键安装或修复环境，启动、停止和诊断 AUTOMATIC1111。
- 主界面始终提供“选择数据目录”；未选择时默认使用启动器仓库中的 `data/`，并在执行 setup 前拒绝 EFS 加密位置。
- 导入 `.safetensors` 模型，或在明确确认来源、社区镜像说明、许可和 4.27 GB 下载量后下载入门模型。
- 设置数据目录和本地端口；运行中禁止修改。
- “启动”“停止”“打开 WebUI”始终可点击；条件不足时显示具体原因。“打开 WebUI”会在已就绪但未运行时自动启动服务。
- 通过 CLI 打开 WebUI、数据、模型、输出和日志目录。
- 所有耗时命令都在独立的 Windows PowerShell 进程中执行，界面不会因安装或启动而假死。

训练功能不属于当前可用版本，启动器中暂不展示训练入口。

## 安全边界

- CLI 命令和参数采用白名单，路径作为进程参数传递，不拼接成可执行 Shell 命令。
- 启动器将用户选择的数据目录原子写入 `%LOCALAPPDATA%\StableDiffusionWorkbench.Launcher\settings.json`，并在后续每条 CLI 命令中显式传递，避免切回默认目录。
- 启动器只使用 CLI 返回并记录的 loopback URL 打开 WebUI。
- 启动按钮退出后仍会继续检查健康状态；只有 CLI 报告 `running=true` 且 `healthy=true` 时界面才显示“运行中”。
- 日志窗口有行数上限，不会随着长时间安装无限增长。

如果启动器无法打开，可在 Windows PowerShell 中执行：

```powershell
.\scripts\sdw.ps1 -Command doctor
```
