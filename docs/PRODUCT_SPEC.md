# Product Specification

## 两个产品入口

### 1. Launcher 与资产中心

- 识别 OS、GPU、驱动、Python、Git、磁盘、端口和 VRAM。
- 管理 Stable/Experimental 通道、固定 commit、独立虚拟环境、更新与原子回滚。
- 管理多个 Profile/实例、启动参数、进程、健康状态、日志和打开 UI。
- 把上游代码、venv、用户配置、模型库、输入和输出彻底分离。
- 管理 Checkpoint、VAE、LoRA、Embedding、Upscaler、扩展和生成图库。
- 资产注册表记录 hash、来源、许可证、架构兼容性、trigger words、预览、大小和 Profile。

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
  profiles/<profile>/
  assets/{checkpoints,vae,lora,embeddings,upscalers}/
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
- 独立 MCP 服务与有限的生成/查看/调整循环。
- 默认 loopback、扩展白名单和资源上限。
