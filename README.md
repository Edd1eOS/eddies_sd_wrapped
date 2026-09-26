# Stable Diffusion Workbench

基于官方 [AUTOMATIC1111/stable-diffusion-webui](https://github.com/AUTOMATIC1111/stable-diffusion-webui) 的本地图片生成工作站。当前版本先把主功能做稳：Windows 用户克隆仓库后双击图形启动器，由它准备隔离运行时、固定版本 A1111、模型、进程、日志与健康检查；生成界面继续使用 A1111 原生 WebUI。

## 当前状态

- 阶段：**Windows Launcher MVP**
- 默认支持范围：**Windows 10/11 x64 + NVIDIA GPU**
- 上游：标准 Profile 固定 A1111 v1.10.1；RTX 50/Blackwell 使用固定的实验 Profile
- 主功能：引擎准备/修复、模型管理、通用基础模型下载、启动、停止、问题检查、存储位置和生成界面
- 后置：训练、MCP、第三方扩展管理、非 Windows 平台和多实例

## 最快使用方式

1. 克隆或下载本仓库。
2. 双击根目录的 **`Start Stable Diffusion.cmd`**。
3. 点击“更改存储位置”可随时指定路径；未选择时默认使用仓库旁的 `data/`。该目录已被 Git 忽略，不会提交模型或用户产物。
4. 点击“准备 / 修复引擎”准备本地引擎。
5. 点击“添加模型”选择现有 `.safetensors`，在“模型管理”中分别管理 Checkpoint、VAE、LoRA 和 Hypernetwork，或明确接受许可后下载约 4.27 GB 的通用 SD 1.5 基础模型。
6. 点击“打开生成界面”；如果服务尚未运行，Launcher 会自动启动后再打开浏览器。

启动器本身不要求预装 Python、Git、Node.js 或 .NET SDK，也不会改写系统 Python、IDE 解释器或全局 `PATH`。首次 setup 会下载 A1111 官方便携引导包、固定 commit 的上游源码和 PyTorch 等依赖，因此需要网络、足够磁盘空间和一定等待时间。默认存储位置是启动器仓库中的 `data/`；也可以随时通过“更改存储位置”改到其他未加密本地路径。详细步骤与限制见 [`docs/WINDOWS_QUICKSTART.md`](docs/WINDOWS_QUICKSTART.md)，环境与分发约束见 [`docs/ENVIRONMENT_ISOLATION.md`](docs/ENVIRONMENT_ISOLATION.md)，RTX 5070 Laptop 的完整安装/生成/停止结果见 [`docs/VALIDATION.md`](docs/VALIDATION.md)。

## 目标使用体验

图形界面与命令行共用同一套核心逻辑。可用 CLI 入口为：

- `setup`：下载并校验便携运行时，选择硬件 Profile，安装固定 A1111 版本和依赖
- `start`：启动工作台及所选上游
- `stop`：验证进程所有权后安全停止相关进程
- `doctor`：诊断系统、运行时、GPU、端口、目录和依赖
- `import-model` / `download-starter-model`：登记生成所需的安全权重
- `status/logs/open-ui/open-data/open-models/open-outputs`：日常运行管理
- `configure`：在停止状态修改数据目录或本地端口

例如：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sdw.ps1 -Command doctor
```

## 目录

- `configs/`：可提交的默认配置和配置模板
- `asset-manifests/`：模型与扩展的来源、许可证和 hash
- `docs/`：架构、路线图与上游评估记录
- `examples/`：最小可复现用例
- `integrations/mcp/`：未来的独立 MCP 服务与 REST 适配边界
- `launcher/`：图形化启动、实例和资产中心
- `models/`：仅保存模型获取与放置说明，不保存权重
- `policies/`：扩展、网络、资源和 Agent 调整策略
- `presets/`：可复用生成预设
- `profiles/`：经验证的硬件/运行时/A1111 组合
- `scripts/`：统一 CLI、A1111 supervisor 与生命周期入口
- `src/`：工作台自身代码与上游适配层
- `tests/`：自动化测试
- `training/`、`training-presets/`：后续训练功能设计占位；不属于当前可运行切片

## 安全与仓库卫生

不得提交模型权重、训练数据集、密钥、真实 `.env`、生成图片、日志、缓存或其他运行产物。只提交可审查的代码、配置模板、文档和小型测试夹具。

这里管理的是 PyTorch 模型权重，而不是 TensorFlow 模型。优先使用 `.safetensors`；旧 `.ckpt` 仅作为显式风险兼容选项。

本仓库当前尚未确定自身最终许可证。A1111、便携包、Python/Git 运行时、PyTorch 和模型分别拥有自己的许可证；setup 从 lock/manifest 记录的来源下载，不把大型第三方二进制或模型提交到 Git。

详细产品边界、训练方案、MCP 工具和分发方案见 `docs/PRODUCT_SPEC.md`、`docs/TRAINING_STUDIO.md`、`docs/MCP_TOOL_PLAN.md` 与 `docs/DISTRIBUTION.md`。
