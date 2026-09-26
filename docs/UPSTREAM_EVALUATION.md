# Upstream Evaluation

核心上游已由用户指定为 [AUTOMATIC1111/stable-diffusion-webui](https://github.com/AUTOMATIC1111/stable-diffusion-webui)。当前评估重点是固定版本、硬件兼容通道、API 稳定性与 AGPL 分发边界。

## 已确认事实

- 官方已有 Windows/Linux 启动脚本，但缺少完整 GUI 启动器、多实例、资产库、诊断和回滚控制面。
- 加 `--api` 可使用 REST API，运行时 `/docs` 是对应版本的权威 OpenAPI。
- `--data-dir`、`--models-dir` 及 checkpoint/VAE/embedding/LoRA 等目录参数支持仓库外数据布局。
- 上游采用 AGPL-3.0；模型和扩展有独立许可证。
- 正式发布节奏较慢，master/dev 长期分叉，默认不得自动 `git pull`。

## 版本通道候选

| 通道 | 候选版本 | 场景 | 进入默认前的验证 |
| --- | --- | --- | --- |
| Stable | `v1.10.1` / `82a973c...` | 已知兼容硬件 | OS、GPU、驱动、PyTorch、API 与扩展基线 |
| Blackwell/Experimental | 固定且测试通过的 dev commit | RTX 50 系/PyTorch 2.7 | 独立环境、完整烟测、明确实验提示与回滚 |

这些是调研候选，不是已经通过测试的 operational lock。

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
