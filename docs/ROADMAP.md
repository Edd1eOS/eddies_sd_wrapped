# 路线图

## Phase 0：规划与骨架（已完成）

- 定义项目边界、目录、仓库卫生与命令契约。
- 记录 AUTOMATIC1111 官方仓库、AGPL 许可证、Stable/Experimental 通道与 API 边界。
- 暂不承诺可运行的推理能力。

## Phase 1：上游生成基线（已完成）

- 验证 v1.10.1/固定 master commit 的支持矩阵与正式通道。
- 为 RTX 50/Blackwell 验证固定 dev commit + PyTorch 2.7 实验通道。
- 复现 REST API、数据目录重定向、模型导入和生成烟测。
- 记录 A1111、便携运行时、PyTorch 与入门模型的来源和许可证；发布前仍需正式完成递归许可/SBOM 审查。

## Phase 2：Windows Launcher MVP（当前）

- 实现可重复的便携 `setup`，不依赖系统 Python/Git。
- 实现图形 Launcher、可靠的 `start`/`stop`、健康检查和日志。
- 实现只读优先、输出可操作建议的 `doctor`。
- 实现固定标准/Blackwell Profile、模型导入和带许可证确认的入门模型下载。
- 将运行时、模型、配置、输出和日志保持在仓库外。
- 用无 GPU/无大下载的单元测试覆盖配置、Profile、命令、环境隔离与进程所有权；RTX 5070 Laptop 的 setup/import/start/API txt2img/stop 实机闭环已完成，标准 NVIDIA Profile 的同等矩阵后续补充。
- 多实例、版本更新/回滚和完整资产图库后置。
- 当前版本不实现 Training Studio；等生成闭环验收后再恢复该路线。
- 覆盖 Windows NVIDIA，并明确 AMD/Intel/Linux/macOS 尚未验证。

## Phase 3：产品化与扩展

- 将脚本入口产品化为可签名的 Windows `.exe` 与安装器；安装包本身保持轻量，首次运行再把固定并校验过的运行时与依赖下载到用户确认的数据目录。
- 增加面向普通用户的原生生成页和分步首次使用向导；AUTOMATIC1111 原生 WebUI 保留为“高级模式”，不再作为普通用户的唯一入口。
- 安装、下载等长任务提供明确阶段、进度、剩余空间提示和安全取消/清理能力，避免单纯用整页禁用表达忙碌状态。
- 加入安全默认配置、预设和示例。
- 完善失败恢复、升级、卸载与离线使用路径。
- 建立端到端测试和发布包验证。
- 实现版本化更新、原子切换、回滚、完整资产图库与多实例。
- 加入独立 MCP 服务、异步任务队列、生成 provenance 和 Agent 有限调参循环。
- 增加默认关闭的训练 MCP 权限；只读规划先行，提交与产物登记需要人工确认。
- 建立固定 prompt/seed 的 LoRA 对比评测，限制自动实验次数与总预算。
- 生成闭环稳定后再实现 Training Studio、LoRA 数据集和训练任务管理。
- 训练阶段再固定 `sd-scripts` 后端，验证 Windows LoRA 最小训练、显存、产物加载，并复核 `kohya_ss` 与 WD14 caption 的版本、来源和许可证边界。

## Phase 4：分发与维护

- 发布版本化安装说明与变更日志。
- 自动检查上游兼容性、安全公告和许可证变化。
- 在不破坏用户数据的前提下支持迁移与升级。
- 评估 DreamBooth、全量 fine-tune 与其他模型架构；不把它们伪装成首个 MVP 能力。
