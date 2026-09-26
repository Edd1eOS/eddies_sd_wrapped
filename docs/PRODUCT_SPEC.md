# Product Specification

本文同时记录长期产品边界与当前可运行切片。当前交付物只是 **Windows Launcher MVP**：便携安装、固定 A1111、模型入口、启停、健康检查与日志。Training Studio 和 Agent/MCP 均已后置。

## 两个产品入口

### 1. Launcher 与资产中心

- 识别 OS、GPU、驱动、Python、Git、磁盘、端口和 VRAM。
- 管理 Stable/Experimental 通道、固定 commit、独立虚拟环境、更新与原子回滚。
- 管理多个 Profile/实例、启动参数、进程、健康状态、日志和打开 UI。
- 把上游代码、venv、用户配置、模型库、输入和输出彻底分离。
- 管理 Checkpoint、VAE、LoRA、Embedding、Upscaler、扩展和生成图库。
- 资产注册表记录 hash、来源、许可证、架构兼容性、trigger words、预览、大小和 Profile。

Launcher 保留 A1111 原生 WebUI 作为生成界面，不在第一阶段重做 txt2img/img2img UI。它额外提供独立的 **Training Studio**：

- Quick LoRA 向导：选择基础模型、数据集、caption、角色/风格/物体预设和资源上限。
- Expert 模式：查看并编辑完整训练配置，必要时打开经固定版本验证的上游训练 GUI。
- 原生入口：继续允许用户在 A1111 Train 页使用 Textual Inversion 与 Hypernetwork。
- 任务中心：预检、配置/命令预览、排队、日志、进度、采样、取消、恢复和失败诊断。
- 产物登记：训练完成后把 `.safetensors`、触发词、基础模型 hash、数据集版本和预览图登记到 LoRA 资产库。

LoRA 训练不塞进 A1111 的 Python 环境。生成与训练后端各自固定依赖和虚拟环境，通过资产注册表共享经过验证的模型与产物，并由 GPU 资源协调器避免单卡同时训练和生成导致显存争抢。

### 2. Agent 工具服务

- 启动 A1111 时启用 localhost REST API，由独立 MCP 服务调用。
- 生成任务异步排队，返回 job ID；支持进度、取消和产物读取。
- Codex/多模态 Agent 可查看生成图，再用固定 seed、变体、img2img 或 inpaint 有限次调整。
- 每张图保存 prompt、negative prompt、seed、sampler、scheduler、CFG、尺寸、checkpoint hash、VAE、LoRA、扩展版本和 A1111 commit。

## 当前 Windows MVP 数据布局

```text
<user-data>/
  config.json
  downloads/
  runtime/{active.json,versions/,staging/}
  state/runtime.json
  logs/{setup.log,webui.log}
  userdata/
    models/{Stable-diffusion,Lora,VAE}/
    embeddings/
    outputs/
```

运行时、上游 checkout、模型、配置、日志和输出均位于用户选定且不被 Git 跟踪的数据目录。当前便携默认是仓库中的 `data/`，用户可以改到任意本地路径。便携包与入门模型采用临时/下载文件、大小和 SHA-256 校验后原子移动。

## 目标产品数据布局

```text
<user-data>/
  runtime/upstream/<commit>/
  runtime/venv/<runtime-id>/
  runtime/training/<backend>/<version>/
  profiles/<profile>/
  assets/{checkpoints,vae,lora,embeddings,upscalers}/
  datasets/<dataset-id>/<version>/
  training/jobs/<job-id>/
  inputs/<project>/
  outputs/<project>/<job-id>/
  cache/
  logs/
```

这些目录都位于 Git 仓库外。下载采用临时文件、大小/hash 校验、原子移动和按 hash 去重。

## 当前 MVP 验收边界

- Windows 10/11 x64 + NVIDIA 的一键 `setup/start/stop/status/doctor`。
- 标准 NVIDIA 与 RTX 50/Blackwell 两个固定 Profile，不跟踪浮动分支。
- `.safetensors` checkpoint 安全添加，以及带来源、社区镜像说明、许可和 hash 确认的可选通用基础模型。
- A1111 原生 txt2img/img2img/inpaint UI 与 localhost REST API。
- 默认 loopback、禁用额外扩展、禁用 share/远程监听，并且只停止通过所有权验证的进程。
- 训练、MCP、update/rollback、多实例、扩展管理、AMD/Intel 与非 Windows 平台不在当前验收边界。

DreamBooth、全量 checkpoint fine-tune 和无人值守自动反复训练不进入首个训练 MVP；这些模式显存、存储和误用风险更高，待硬件矩阵、评测基线和确认流程成熟后再开放。
