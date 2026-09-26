# Python 环境隔离与分发引导

Stable Diffusion Workbench 的分发目标是“克隆后双击即可准备环境”。用户不需要预装 Python、Git、Conda、virtualenv 或 Node.js，也不需要修改系统或用户 `PATH`。

## 为什么不使用系统 Python

AUTOMATIC1111 及其 PyTorch 组合对 Python、CUDA 和打包工具版本有明确兼容边界。复用系统 Python 会让任意一个普通开发项目、IDE 设置或 `pip install` 影响图片工作站；反过来，A1111 的依赖也可能污染用户的编码环境。因此工作台始终使用独立的便携运行时。

## 首次启动流程

1. 用户双击仓库根目录的 `Start Stable Diffusion.cmd`。
2. 入口只调用 Windows 自带的 Windows PowerShell 5.1，不调用裸 `python`、`pip` 或 `git` 命令。
3. Launcher 让用户选择仓库外的数据目录；默认目录不可用（例如继承 EFS 加密）时会给出可操作提示。
4. `setup` 下载 `configs/upstream-lock.json` 中固定大小和 SHA-256 的 A1111 便携引导包，只提取其中的 Python/Git 运行时。
5. 工作台检出 Profile 锁定的 A1111 commit，并在该私有运行时中安装锁定的引导工具链、PyTorch 与上游依赖。
6. 启动时只在 A1111 子进程环境中设置 `PYTHON`、`GIT` 和临时 `PATH`；父进程、用户环境变量和系统环境变量保持不变。

这里使用的是“一套应用私有的便携 Python”，不是供其他项目复用的通用虚拟环境。运行时位于所选数据目录的 `runtime/versions/`，模型、输出、日志和用户配置也都位于仓库外。

## 用户需要配置什么

只有以下三项属于用户配置：

- 数据目录：运行时、模型、输出与日志的根目录；
- 端口：默认 `7860`，只绑定 `127.0.0.1`；
- 硬件 Profile：通常由 Launcher 根据 GPU 自动选择，也可在诊断时确认。

Launcher 的数据目录选择保存在 `%LOCALAPPDATA%\StableDiffusionWorkbench.Launcher\settings.json`。工作台配置保存在所选数据目录中。两者均由 Launcher 原子写入，不要求用户手工创建或复制配置模板。

## 明确禁止的做法

- 不把工作台 Python 加入用户或系统 `PATH`；
- 不设置全局 `PYTHONHOME`、`PYTHONPATH`、`VIRTUAL_ENV` 或 Conda 环境；
- 不修改 VS Code/Cursor 的全局 `python.defaultInterpreterPath`；
- 不调用系统中的裸 `python`、`pip` 或 `git`；
- 不复用旧 A1111 的 `python/`、`venv/`、`git/` 或 `repositories/`；
- 不把运行时、模型、日志或生成图片提交到 Git。

## 开发者自己的 Python 项目

工作台运行时不应作为编码解释器。普通 Python 项目应在项目目录中创建自己的 `.venv`，由编辑器按项目选择；机器上的新版 Python 可以作为创建 `.venv` 的基础解释器。机器学习项目若尚未支持最新 Python，应在该项目自身锁定兼容版本，而不是改变全局默认值。

## 验证隔离是否生效

安装前后分别在一个新终端中运行 `python --version` 和 `where.exe python`，结果应保持不变。随后在 Launcher 中运行“诊断”，它会单独报告工作台便携 Python、PyTorch、CUDA、数据目录和上游 commit。删除或移动仓库也不会删除数据目录；修复运行时也不会修改系统 Python。
