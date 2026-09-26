# MCP Tool Plan

MCP 服务作为独立进程，通过 localhost REST API 调用固定版本的 AUTOMATIC1111 WebUI。它维护自己的任务队列和调用者归属，避免全局 interrupt 误伤其他任务。

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

## 不对 Agent 开放

- 扩展安装或自动更新
- 任意 URL 模型下载
- 任意文件系统路径
- server kill/restart、训练 API、全局 options 任意修改
- `--enable-insecure-extension-access`、`--allow-code` 等高危模式

服务端限制最大分辨率、steps、batch、并发、超时和自动调整轮数。输入图只通过受控 input ID 引用，不接受任意绝对路径。
