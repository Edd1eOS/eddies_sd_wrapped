# Upstream Evaluation

核心上游已由用户指定为 [AUTOMATIC1111/stable-diffusion-webui](https://github.com/AUTOMATIC1111/stable-diffusion-webui)。当前评估重点是固定版本、硬件兼容通道、API 稳定性与 AGPL 分发边界。

## 已确认事实

- 官方已有 Windows/Linux 启动脚本，但缺少完整 GUI 启动器、多实例、资产库、诊断和回滚控制面。
- 加 `--api` 可使用 REST API，运行时 `/docs` 是对应版本的权威 OpenAPI。
- `--data-dir`、`--models-dir` 及 checkpoint/VAE/embedding/LoRA 等目录参数支持仓库外数据布局。
- 上游采用 AGPL-3.0；模型和扩展有独立许可证。
- 正式发布节奏较慢，master/dev 长期分叉，默认不得自动 `git pull`。

## 已锁定的版本通道

| 通道 | 精确版本 | 场景 | 当前验证状态 |
| --- | --- | --- | --- |
| Stable | `v1.10.1` / `82a973c04367123ae98bd9abdf80d9eda9b910e2` | RTX 40 及更早的 NVIDIA 硬件 | lock、便携引导、安全启动参数与 CLI 测试已完成；生成烟测按具体硬件持续补充 |
| Blackwell/Experimental | `1937682a20f7f0442311a1ede68f9f0cb480163b` | RTX 50 系 + PyTorch 2.7/cu128 | 已在 RTX 5070 Laptop 上完成隔离安装、CUDA、API 生成和停止闭环；见 [`VALIDATION.md`](VALIDATION.md) |

两个通道都是 operational lock，不会在 setup 时自动跟踪 master/dev。Blackwell 通道仍标记为实验；“已锁定”不等于对所有驱动与 RTX 50 型号做出兼容性承诺。

## 必评维度

1. AGPL、模型、扩展与再分发边界
2. Windows/Linux 及 GPU/CPU 兼容性
3. 安装可复现性、冷启动时间与磁盘占用
4. API 稳定性、无头运行、进程关闭与健康检查
5. 图片生成质量、性能、显存管理与批处理
6. 扩展任意代码执行、插件隔离与升级风险
7. 数据目录、日志、诊断、离线和代理网络支持

## 决策要求

每个通道必须包含可复现实验、完整 commit、运行时/驱动矩阵、许可证复核、已知风险和至少一个回退方案。

## 官方证据入口

- [安装与启动](https://github.com/AUTOMATIC1111/stable-diffusion-webui#installation-and-running)
- [NVIDIA 安装与 RTX 50 注意事项](https://github.com/AUTOMATIC1111/stable-diffusion-webui/wiki/Install-and-Run-on-NVidia-GPUs)
- [命令行参数](https://github.com/AUTOMATIC1111/stable-diffusion-webui/wiki/Command-Line-Arguments-and-Settings)
- [REST API](https://github.com/AUTOMATIC1111/stable-diffusion-webui/wiki/API)
- [扩展安全说明](https://github.com/AUTOMATIC1111/stable-diffusion-webui/wiki/Extensions#security)
- [AGPL License](https://github.com/AUTOMATIC1111/stable-diffusion-webui/blob/master/LICENSE.txt)
