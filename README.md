# Stable Diffusion Workbench

基于官方 [AUTOMATIC1111/stable-diffusion-webui](https://github.com/AUTOMATIC1111/stable-diffusion-webui) 的本地图片生成工作站。目标是在上游 PyTorch 推理与 WebUI 外增加完整启动/资产管理层，并提供可被 Codex、OpenClaw 和其他 Agent 调用的安全 MCP 工具。

## 当前状态

- 阶段：**Phase 1（官方上游调研与产品规格完成；实现尚未开始）**
- 上游：**已指定 AUTOMATIC1111 WebUI**；精确版本、硬件通道与许可证组合仍需验证
- 功能：尚未提供可运行服务

## 目标使用体验

上游已有 `webui-user.bat`、`webui.sh` 等启动脚本；本项目补的是图形化安装/启动、多实例、资产中心、诊断、版本锁定和回滚。后续将提供语义稳定的入口：

- `setup`：检查环境并安装依赖
- `start`：启动工作台及所选上游
- `stop`：安全停止相关进程
- `doctor`：诊断系统、运行时、GPU、端口、目录和依赖
- `update`：在保留配置和回滚能力的前提下更新
- `status/logs/open-ui/restart/rollback`：完成日常运行管理

这些命令目前只是产品契约，不应伪装成已实现。

## 目录

- `configs/`：可提交的默认配置和配置模板
- `asset-manifests/`：模型与扩展的来源、许可证和 hash
- `docs/`：架构、路线图与上游评估记录
- `examples/`：最小可复现用例
- `integrations/mcp/`：独立 MCP 服务与 REST 适配边界
- `launcher/`：图形化启动、实例和资产中心
- `models/`：仅保存模型获取与放置说明，不保存权重
- `policies/`：扩展、网络、资源和 Agent 调整策略
- `presets/`：可复用生成预设
- `profiles/`：经验证的硬件/运行时/A1111 组合
- `scripts/`：未来的 setup/start/stop/doctor/update 入口
- `src/`：工作台自身代码与上游适配层
- `tests/`：自动化测试

## 安全与仓库卫生

不得提交模型权重、密钥、真实 `.env`、生成图片、日志、缓存或其他运行产物。只提交可审查的代码、配置模板、文档和小型测试夹具。

这里管理的是 PyTorch 模型权重，而不是 TensorFlow 模型。优先使用 `.safetensors`；旧 `.ckpt` 仅作为显式风险兼容选项。

许可证将在上游选型与兼容性审查后确定。

详细产品边界、MCP 工具和分发方案见 `docs/PRODUCT_SPEC.md`、`docs/MCP_TOOL_PLAN.md` 与 `docs/DISTRIBUTION.md`。
