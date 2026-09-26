# Windows 快速开始

当前可用切片只面向 **Windows 10/11 x64 + NVIDIA GPU**。训练、MCP、第三方扩展管理和其他操作系统暂不属于这个版本。

## 准备

- 建议预留至少 20 GB 可用空间；模型和后续输出会继续占用空间。
- 首次安装需要访问 GitHub、PyPI、PyTorch 下载源和模型来源。
- 不要求预先安装 Python、Git、Node.js 或 .NET SDK。启动器使用 Windows 自带 PowerShell，并从 A1111 官方便携包准备隔离的 Python 3.10.6 与 Git。
- 不需要创建 virtualenv 或修改 `PATH`。便携 Python 只在 A1111 子进程内可见，也不会改写 VS Code/Cursor 的解释器设置；完整边界见 `ENVIRONMENT_ISOLATION.md`。
- 所有运行时、模型、输出和日志默认位于 `%LOCALAPPDATA%\StableDiffusionWorkbench`，不写进 Git 仓库。
- 如果该目录继承了 Windows EFS 加密，`doctor/setup` 会明确拒绝，因为 pip 的原子文件替换在某些 EFS 环境下会失败。请在 Launcher 的“设置”中选择未加密的本地目录，例如 `D:\StableDiffusionWorkbench`。

## 图形化流程

1. 克隆或下载本仓库。
2. 双击仓库根目录的 `Start Stable Diffusion.cmd`。
3. 首次打开后点击 **一键安装/修复**。Launcher 会强制弹出安装位置确认窗口；选择数据目录并确认后才会开始下载。安装命令不会静默回退到其他目录。
4. 等待启动器下载已锁定且校验 SHA-256 的官方便携运行时、A1111 源码和 Python/PyTorch 依赖。首次安装可能耗时较长，期间不要关闭 Launcher。
5. 使用 **导入 .safetensors** 选择已有模型，或选择 **下载入门模型**。
6. 入门模型约 4.27 GB；它来自当前可用的 SD 1.5 社区镜像，文件 SHA-256 与原 checkpoint 一致。下载前会显示镜像说明、来源和许可链接，只有用户明确确认后才开始。
7. 状态变为“就绪”后点击 **启动**。健康检查通过后点击 **打开 WebUI**。
8. 结束使用时点击 **停止**；Launcher 只停止由本工作台启动并通过所有权校验的进程。

RTX 50 系列会自动选择固定 commit 的 Blackwell 实验 Profile 和 CUDA 12.8/PyTorch 2.7 路径。其他 NVIDIA GPU 使用固定的 A1111 v1.10.1 Profile。Profile 均锁定完整 commit，不在启动时追踪浮动分支。

## 命令行等价入口

在仓库根目录使用 Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sdw.ps1 -Command doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sdw.ps1 -Command setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sdw.ps1 -Command import-model -Path "D:\models\example.safetensors"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sdw.ps1 -Command start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sdw.ps1 -Command open-ui
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sdw.ps1 -Command stop
```

下载入门模型需要显式接受该模型自己的许可证：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sdw.ps1 -Command download-starter-model -AcceptLicense
```

## 数据目录与端口

Launcher 设置中可在停止状态修改数据根目录和端口。命令行也可以配置：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sdw.ps1 -Command configure -DataRoot "D:\AI\StableDiffusionWorkbench" -Port 7860
```

切换数据根目录不会删除或移动旧目录。模型、输出和运行时仍保留在原位置，用户需要自行决定是否迁移。

## 安全默认值

- WebUI 只绑定 loopback，不传入 `--listen` 或 `--share`。
- REST API 只供本机 Launcher 和未来的受限 MCP 适配器使用。
- 首版禁用额外第三方扩展，只保留 A1111 内置扩展。
- 默认只导入 `.safetensors`；不启用 `--disable-safe-unpickle`。
- 下载在校验文件大小和 SHA-256 后才进入正式目录。
- 上游代码和运行依赖按完整 commit/Profile 隔离，用户模型与输出不随修复操作删除。

## 常见状态

| 状态 | 含义 | 下一步 |
| --- | --- | --- |
| 未安装 | 便携运行时或 A1111 尚未准备 | 点击“一键安装/修复” |
| 缺少模型 | 运行环境就绪，但还不能生成 | 导入或下载 `.safetensors` |
| 就绪 | 运行环境与模型都可用 | 点击“启动” |
| 正在启动 | A1111 已启动但健康检查未通过 | 查看 Launcher 日志，首次加载模型需要时间 |
| 运行中 | `/internal/ping` 健康检查通过 | 打开 WebUI |
| 故障 | 安装、进程或健康检查失败 | 点击“诊断”，再查看日志中的具体修复建议 |

## 当前限制

- 只承诺 Windows x64 + NVIDIA；AMD、Intel、CPU、Linux 和 macOS 尚未验证。
- 启动器可以安装和运行 A1111，但模型质量、许可证和硬件需求由所选模型决定。
- RTX 50 Profile 属于实验通道；它固定版本并可诊断，但仍可能遇到上游兼容问题。
- 当前没有训练功能、Agent/MCP、图库、模型商店或多实例。
- “一键可用”表示克隆后由 Launcher 完成安装；由于 PyTorch 和模型体积较大，不代表首次启动无需下载或能瞬间完成。

## 复用旧版 A1111 资产

旧安装可以作为模型来源，但不要把它的 `python/`、`venv/`、`git/`、`repositories/` 或启动参数复制到新运行时。在 Launcher 中选择 **导入 .safetensors** 时，工作台会把所选 checkpoint 复制到新的仓库外数据目录，对源文件和副本计算 SHA-256，并且不修改旧安装。

当前图形入口只管理主 checkpoint；VAE、LoRA、Embedding 的完整资产迁移界面属于后续阶段。
