# Product Specification

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

## 数据布局

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

## MVP

- Windows Stable 通道一键 setup/start/stop/doctor/update/rollback。
- 一个受验证的 text-to-image Profile 和一个 img2img/inpaint Profile。
- 资产导入、扫描、hash、许可证确认和输出图库。
- 引导式 LoRA 数据集预检、训练计划、单 GPU 队列和训练产物登记。
- 独立 MCP 服务与有限的生成/查看/调整循环。
- 默认 loopback、扩展白名单和资源上限。

DreamBooth、全量 checkpoint fine-tune 和无人值守自动反复训练不进入首个训练 MVP；这些模式显存、存储和误用风险更高，待硬件矩阵、评测基线和确认流程成熟后再开放。
