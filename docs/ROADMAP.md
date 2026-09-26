# 路线图

## Phase 0：规划与骨架（已完成）

- 定义项目边界、目录、仓库卫生与命令契约。
- 记录 AUTOMATIC1111 官方仓库、AGPL 许可证、Stable/Experimental 通道与 API 边界。
- 暂不承诺可运行的推理能力。

## Phase 1：上游版本与硬件验证（当前）

- 验证 v1.10.1/固定 master commit 的支持矩阵与正式通道。
- 为 RTX 50/Blackwell 验证固定 dev commit + PyTorch 2.7 实验通道。
- 复现 REST API、数据目录重定向、模型切换和生成烟测。
- 固定 `sd-scripts` 训练后端候选，验证 Windows 安装、LoRA 最小训练、显存占用和产物加载。
- 对 `kohya_ss` 专家 GUI 做版本、许可证和打包边界验证。
- 核对 WD14 ONNX caption 代码、模型权重、数据来源与许可证；未通过前不作为默认下载项。
- 完成 AGPL、模型与扩展许可证策略。

## Phase 2：一键生命周期

- 实现可重复的 `setup`。
- 实现可靠的 `start` 与 `stop`。
- 实现只读优先、输出可操作建议的 `doctor`。
- 实现保留配置并可回滚的 `update`。
- 实现 Profile、多实例、资产注册表与输出图库。
- 实现 Training Studio：数据集登记/预检、Quick LoRA 向导、训练计划、GPU 互斥队列、日志和取消。
- 训练完成后登记 LoRA，并在 A1111 原生 WebUI 中刷新和验证加载。
- 覆盖 Windows，并明确 macOS/Linux 支持范围。

## Phase 3：可用产品层

- 加入安全默认配置、预设和示例。
- 完善失败恢复、升级、卸载与离线使用路径。
- 建立端到端测试和发布包验证。
- 加入独立 MCP 服务、异步任务队列、生成 provenance 和 Agent 有限调参循环。
- 增加默认关闭的训练 MCP 权限；只读规划先行，提交与产物登记需要人工确认。
- 建立固定 prompt/seed 的 LoRA 对比评测，限制自动实验次数与总预算。

## Phase 4：分发与维护

- 发布版本化安装说明与变更日志。
- 自动检查上游兼容性、安全公告和许可证变化。
- 在不破坏用户数据的前提下支持迁移与升级。
- 评估 DreamBooth、全量 fine-tune 与其他模型架构；不把它们伪装成首个 MVP 能力。
