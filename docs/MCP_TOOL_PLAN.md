# MCP Tool Plan

MCP 服务作为独立进程：生成工具通过 localhost REST API 调用固定版本的 AUTOMATIC1111 WebUI，训练工具调用本项目自己的 Training Job Service，再由其启动隔离的训练后端。它维护自己的任务队列和调用者归属，避免全局 interrupt 误伤其他任务。

| 工具 | 用途 | 风险 |
| --- | --- | --- |
| `sd_status` | 进程、版本、GPU/VRAM、当前任务 | 只读 |
| `sd_capabilities` | 模型、VAE、sampler、scheduler、upscaler 与允许参数 | 只读 |
| `sd_submit_txt2img` | 提交文生图任务并返回 job ID | 消耗 GPU/磁盘 |
| `sd_submit_img2img` | 提交参考图、denoise、mask/inpaint 任务 | 消耗 GPU/磁盘 |
| `sd_submit_upscale` | 提交受限放大任务 | 可能高显存 |
| `sd_interrogate` | 从图片提取描述/标签辅助改 Prompt | 消耗计算资源 |
| `sd_get_job` | 查询排队、进度、ETA、预览和结果 | 只读 |
| `sd_cancel_job` | 只取消调用方自己的任务 | 改变运行状态 |
| `sd_read_png_metadata` | 读取可复现生成参数 | 只读 |
| `sd_list_artifacts` / `sd_get_artifact` | 列出或读取任务产物与 provenance | 路径受限 |
| `sd_list_assets` | 列出已注册模型和兼容性 | 只读 |

## 可选训练工具

训练 MCP 权限默认关闭。启用后仍把“分析/规划”和“真正消耗 GPU 的执行”分开：

| 工具 | 用途 | 默认策略 |
| --- | --- | --- |
| `sd_training_capabilities` | 查询后端、硬件、支持架构与资源上限 | 只读开放 |
| `sd_validate_dataset` | 校验已登记数据集并返回问题，不读取任意路径 | 只读开放 |
| `sd_create_training_plan` | 生成配置、资源估算和命令预览，不启动训练 | 只读开放 |
| `sd_submit_lora_training` | 提交已经确认的计划 | 默认关闭；需人工确认 |
| `sd_get_training_job` | 查询进度、日志摘要、采样和资源占用 | 仅任务所有者 |
| `sd_cancel_training_job` | 请求安全取消调用方任务 | 仅任务所有者 |
| `sd_list_training_artifacts` | 列出任务产物和 provenance | 路径受限 |
| `sd_register_lora` | 校验并登记训练产物 | 默认关闭；需人工确认 |
| `sd_evaluate_lora` | 用固定 prompt/seed 套件生成有限对比样本 | 限额执行 |

服务端强制限制训练时长、steps/epochs、磁盘、并发、基础模型白名单和自动实验次数。Agent 不能绕过确认、修改已确认计划、把任意目录当作数据集，或自动循环训练直到预算耗尽。

## 不对 Agent 开放

- 扩展安装或自动更新
- 任意 URL 模型下载
- 任意文件系统路径
- server kill/restart、全量 checkpoint fine-tune、DreamBooth、全局 options 任意修改
- `--enable-insecure-extension-access`、`--allow-code` 等高危模式

服务端限制最大分辨率、steps、batch、并发、超时和自动调整轮数。输入图只通过受控 input ID 引用，不接受任意绝对路径。
