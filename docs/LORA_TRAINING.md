# LoRA 训练

启动器的「LoRA 训练」区域：

1. 点击「配置训练环境」，确认后自动下载独立 Python 和 Kohya 依赖；首次需要联网及数 GB 下载，不使用或修改系统 Python、SD 出图环境。失败可查看「训练日志」后重试。
2. 「训练素材」打开 `datasets/lora/`。按 Kohya 数据集规则建立角色子目录（例如 `10_my_character/`），放图片和同名 `.txt` 标签；目录前的数字是重复次数，不是角色名的一部分。
3. 「打开训练界面」打开本机 `http://127.0.0.1:7861`，选择 **LoRA** 标签。自行选择兼容底模、数据集和参数；此按钮不会自动开始训练。
4. 开始 GPU 训练前，停止 SD/ComfyUI 等出图引擎释放显存。8GB 显存建议先验证 SD 1.5、512 分辨率、batch 1；不保证任意模型和参数均可训练。
5. 「训练结果」打开 `training-runs/`。对比不同阶段的模型，选择满意的 `.safetensors` **复制**到 `Models/Lora/` 后在 A1111 的 LoRA 标签刷新。不要覆盖已有同名文件。

训练服务与素材、输出分开：环境和日志在 `data/training/`，训练配置在其中的 `config.toml`。GUI默认的素材、模型、结果路径已指向本项目；用户在 Kohya 内手动修改路径后以其设置为准。

「停止训练服务」会确认后关闭 GUI 及它启动的子任务，未保存的进度会丢失，已保存模型不删除。只停止本启动器记录且 PID、启动时间、解释器和随机归属标记均匹配的服务；不会按进程名杀其他 Python。关闭启动器窗口不自动终止训练。

## 版本、安全和许可

- Kohya GUI 与其 sd-scripts 子模块固定到 `configs/training-lock.json` 中的精确 commit；源代码下载验证大小与 SHA-256。
- 私有 uv 下载验证 SHA-256；Python 由 uv 管理并校验下载，Python版本固定。依赖使用该 Kohya commit 附带的 `uv.lock`，以 `uv sync --frozen --no-dev` 安装，不执行浮动升级或系统级安装。
- GUI 只绑定 loopback，不启用 Gradio share，关闭遥测；训练使用无 shell 的命令调用。GUI仍是本地代码执行工具，请只使用可信数据、底模和配置。
- Kohya GUI、sd-scripts 为 Apache-2.0，uv 为 MIT/Apache-2.0；下载包保留各自许可证。没有将第三方运行时、源码、模型、训练素材或权重提交到仓库。模型训练和输出使用权仍取决于其独立许可证。
- 不默认安装额外标注模型或连接云端训练服务；部分 Kohya 功能可能另行下载模型，使用前应确认。

本入口不等于 A1111 的 Train 标签，不提供自动选择训练参数或训练质量保证。

## 本机验证

2026-10-03：独立环境完成首次安装，PyTorch 2.7.0+cu128 在 RTX 5070 Laptop 上通过 CUDA 运算检查；`train_network.py --help` 正常退出；Kohya GUI 的启动、健康检查、停止与重新打开通过。SD 原服务仍健康。尚未使用真实角色数据完成一轮 LoRA 训练，训练速度、峰值显存和角色效果不作保证。Windows 下 xformers 提示缺少可选 Triton 并不代表所有训练路径不可用。
