# Stable Diffusion Workbench

基于官方 [AUTOMATIC1111/stable-diffusion-webui](https://github.com/AUTOMATIC1111/stable-diffusion-webui) 的本地图片生成工作站。

## Python 版本需求

无需预装 Python。首次点击“一键配置 / 修复运行环境”，自动下载并配置独立 Python 3.10.6、引擎和依赖，需要联网及数 GB 下载；不修改系统 Python 或 `PATH`。

## 使用方式

```powershell
git clone https://github.com/Edd1eOS/eddies_sd_wrapped.git
cd eddies_sd_wrapped
& ".\Start Stable Diffusion.cmd"
```

首次：一键配置运行环境 → 添加模型 → 打开生成界面。环境在项目 `data/`，模型在 `Models/`，结果在 `Outputs/`。

## 目录

- `configs/`：可提交的默认配置和配置模板
- `asset-manifests/`：模型与扩展的来源、许可证和 hash
- `docs/`：架构、路线图与上游评估记录
- `examples/`：最小可复现用例
- `integrations/mcp/`：未来的独立 MCP 服务与 REST 适配边界
- `launcher/`：图形化启动、实例和资产中心
- `models/`：仅保存模型获取与放置说明，不保存权重
- `policies/`：扩展、网络、资源和 Agent 调整策略
- `presets/`：可复用生成预设
- `profiles/`：经验证的硬件/运行时/A1111 组合
- `scripts/`：统一 CLI、A1111 supervisor 与生命周期入口
- `src/`：工作台自身代码与上游适配层
- `tests/`：自动化测试
- `training/`、`training-presets/`：后续训练功能设计占位；不属于当前可运行切片
