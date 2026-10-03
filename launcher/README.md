# Windows 图形启动器

`StableDiffusionWorkbench.ps1` 是仓库的 Windows 桌面入口。它使用 Windows PowerShell 5.1 和 WPF，文件选择对话框使用 WinForms；不要求用户预先安装 Python 或 Node.js。

普通用户应双击仓库根目录的 `Start Stable Diffusion.cmd`，不要直接执行本文件夹中的脚本。启动器只调用统一 CLI `scripts/sdw.ps1`，不直接修改 AUTOMATIC1111 的启动脚本、进程或模型目录。

## 当前功能

- 显示引擎/运行状态、Profile、GPU、存储位置、已安装模型和本地生成界面地址。
- 一键安装或修复环境，启动、停止和诊断 AUTOMATIC1111。
- “一键配置 / 修复运行环境”自动准备独立 Python、引擎和依赖，固定放在本项目 `data/`；模型放在 `Models/`，输出默认放在 `Outputs/`。首次配置需要联网。
- 通过“添加模型”选择 `.safetensors`，或进入“模型管理”把文件拖入模型文件夹。
- “模型管理”打开包含 `Checkpoints`、`VAE`、`Lora` 和 `Hypernetworks` 的模型根目录，并用口语化说明提示每类文件的作用与放置位置。
- 启动引擎时保留用户其他 A1111 设置，并确保顶部快捷栏显示 Checkpoint 与 VAE 选择器。
- 在明确确认来源、社区镜像说明、许可和约 4.27 GB 下载量后，可下载通用 SD 1.5 基础模型。
- “环境与端口”显示项目内环境路径并允许修改端口；运行中禁止修改。
- “启动引擎”“停止引擎”“打开生成界面”始终可点击；条件不足时显示具体原因。“打开生成界面”会在已就绪但未运行时自动启动服务。
- 通过 CLI 打开生成界面、存储位置、模型管理、输出管理和运行日志。
- 所有耗时命令都在独立的 Windows PowerShell 进程中执行，界面不会因安装或启动而假死。

训练功能不属于当前可用版本，启动器中暂不展示训练入口。

## 安全边界

- CLI 命令和参数采用白名单，路径作为进程参数传递，不拼接成可执行 Shell 命令。
- 启动器设置保存在项目 `data/launcher/`，不继承其他副本或 AppData 的旧路径；每条 CLI 命令显式传递本项目环境路径。
- 启动器只使用 CLI 返回并记录的 loopback URL 打开 WebUI。
- 启动按钮退出后仍会继续检查健康状态；只有 CLI 报告 `running=true` 且 `healthy=true` 时界面才显示“运行中”。
- 日志窗口有行数上限，不会随着长时间安装无限增长。

如果启动器无法打开，可在 Windows PowerShell 中执行：

```powershell
.\scripts\sdw.ps1 -Command doctor
```
