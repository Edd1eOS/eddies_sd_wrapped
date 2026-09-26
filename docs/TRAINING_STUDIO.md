# Training Studio 设计

## 结论

第一版不重做 AUTOMATIC1111 的生成界面。Launcher 继续打开 A1111 原生 WebUI，同时增加独立的 Training Studio，把最容易卡住用户的环境、数据集、参数、任务和产物管理统一起来。

A1111 原生 Train 页目前面向 **Textual Inversion embedding** 与 **Hypernetwork**；A1111 可以加载和使用 LoRA，但 LoRA 训练应接独立后端。首选候选为 [`kohya-ss/sd-scripts`](https://github.com/kohya-ss/sd-scripts)，可选专家界面候选为 [`bmaltais/kohya_ss`](https://github.com/bmaltais/kohya_ss)。

正式 Training Studio 直接生成可审查的 dataset TOML 与 argv 调用 `sd-scripts`，不抓取或遥控第三方 Gradio 页面。`kohya_ss` GUI 只是早期/专家模式的逃生口，不能成为核心数据模型。

## 你可能记得的其他训练方式

| 类型 | 学习内容 | 首版定位 |
| --- | --- | --- |
| Textual Inversion | 学习一个或少量文本 embedding，文件很小但表达能力有限 | 使用 A1111 原生入口 |
| Hypernetwork | 插入注意力路径的小网络，不改基础模型 | 仅保留 Legacy 兼容 |
| LoRA | 冻结基础模型，训练低秩 adapter | Training Studio MVP 主功能 |
| DreamBooth | 面向主体个性化的数据组织/训练配方，可训练完整 checkpoint，也可结合 LoRA | 第二阶段 |
| Full fine-tune | 更新全部或大部分基础权重 | 高显存、高存储、高风险；MVP 不做 |

“DreamBooth LoRA”通常表示用 DreamBooth 风格数据训练 LoRA，并不是另一种产物格式。

## 为什么先做 LoRA

- 相比全量 fine-tune，LoRA 产物小、训练成本和显存需求较低，也更容易启用、停用和组合。
- 适合训练角色、画风、物体或特定视觉概念。
- 训练结果可以作为普通 `.safetensors` 资产登记并直接供 A1111 使用。
- 参数仍然复杂，因此本项目的价值不是再放一排输入框，而是提供经过验证的预设、预检、可复现任务和对比评测。

LoRA 并不是“免费获得新知识”。质量高度依赖数据版权/同意、图片质量、caption、一致性、基础模型兼容性和训练参数；过拟合、概念泄漏和风格模仿风险都要在产品里显式提示。

## 产品入口

### Quick LoRA

1. 选择基础模型；显示架构、hash、许可证和兼容预设。
2. 创建或选择数据集版本；导入图片，不直接引用散落的任意目录。
3. 运行数据预检：损坏文件、重复图、尺寸、宽高比分布、caption 缺失和敏感元数据。
4. 选择 `character`、`style` 或 `object` 预设，再根据可用 VRAM 给出 batch、resolution、precision 和缓存建议。
5. 显示完整计划：后端版本、基础模型、数据集 manifest、训练步数、预计磁盘/时间区间和输出位置。
6. 用户确认后入队；训练中展示进度、loss、采样图、日志摘要与安全取消。
7. 完成后运行固定 prompt/seed 对比，用户决定登记、保留为实验产物或删除。

预估时间只给范围，并标注为估算；不得在没有同类硬件基准时显示虚假精确 ETA。

数据预检会生成 aspect-ratio buckets，不强迫把所有图片裁成正方形；自动 caption 首选本地 WD14 ONNX 路径并要求人工批改。训练前先运行后端的 dataset debug，再允许用户确认执行。

### Expert 模式

- 允许从 Quick 配置展开所有已支持参数并导入/导出配置。
- 始终展示最终命令与环境版本，便于复现和脱离 Launcher 调试。
- 可选打开固定版本、隔离运行的 `kohya_ss` GUI，但它不直接写入正式资产注册表；产物仍要经过校验与登记。
- A1111 原生 Textual Inversion/Hypernetwork 页面保留为高级兼容入口，Launcher 只负责环境和资产定位。

## 数据集管理

每次训练引用不可变的 dataset version，而不是一个会继续变化的文件夹。manifest 至少记录：

- 稳定 dataset ID、version、文件相对路径、内容 hash、像素尺寸和格式；
- caption 文本及生成/人工修订来源；
- 去重结果、分桶统计、被排除文件与原因；
- 数据来源、作者/主体同意、许可证或用户确认；
- 创建时间与工具版本。

原图、caption 和训练缓存位于仓库外的用户数据目录。默认不上传云端，不写入 Git，也不把原图内容泄露到普通诊断报告。

## 可复现任务与产物

每个训练 job 固定并保存：

- 训练后端 commit/版本及环境 Profile；
- 基础模型 asset ID 与 hash；
- dataset ID/version 与 manifest hash；
- 完整训练参数、seed、启动命令和状态转换；
- 资源上限、日志、采样图、最终权重 hash 与失败原因。

正式 LoRA 资产额外记录 trigger words、建议权重范围、兼容架构、预览图和评测结果。只接受可验证的安全权重格式；不得自动加载未知 pickle/checkpoint。

## Agent 辅助边界

Agent 可以帮助 caption、发现数据问题、生成训练计划、分析日志和按固定评测套件比较样本。它不能默认启动无限循环，也不能以“效果还可以更好”为由持续消耗 GPU。

训练执行采用三段式授权：

1. `validate`：只读数据与环境检查；
2. `plan`：产生不可变计划和资源估算，不执行；
3. `submit`：用户确认计划 hash、资源上限和输出位置后才运行。

任何修改数据集、基础模型、steps/epochs 或预设都会产生新的计划并重新确认。

## 运行环境与安全基线

- 首发只承诺经过验证的 Windows 10/11 + NVIDIA Profile。显存需求按模型、分辨率、rank、batch 和 optimizer 动态判断，不宣传一个虚假的通用最低值。
- A1111 与训练后端使用独立 Python/venv；训练时默认获取 GPU 独占锁，并停止生成或卸载 A1111 模型。
- 子进程使用 argv 调用而不是 shell 拼接；训练输入/输出只允许已登记路径。
- 默认只绑定 `127.0.0.1`，不启用 `--share` 或公网监听。
- 正式产物只接收 `.safetensors`；启动器禁止 A1111 的 `--disable-safe-unpickle`。
- 数据导入只在工作区副本上清理 EXIF，不修改用户原图；W&B、Hugging Face 等远端上传默认关闭。人物/私密素材要求用户记录授权与同意。

## 首个验收切片

- Windows + NVIDIA 的一个受验证硬件 Profile。
- 一个受验证的 SD 1.5 或 SDXL LoRA 路径，以硬件烟测结果决定先后。
- 20–50 张小型、授权明确的测试数据集。
- 从预检到训练、采样、登记、A1111 加载和固定 prompt 对比的完整闭环。
- 中断、磁盘不足、CUDA OOM、坏图、错误模型架构和取消后的恢复测试。

DreamBooth、全量 checkpoint fine-tune、FLUX 等其他架构、多 GPU/远程训练与无人值守超参数搜索均为后续候选，不进入首个验收切片。

## 官方依据

- [A1111 Features](https://github.com/AUTOMATIC1111/stable-diffusion-webui/wiki/Features)：Extra Networks 与 LoRA 使用入口，并指向 kohya-ss 训练方式。
- [A1111 Textual Inversion](https://github.com/AUTOMATIC1111/stable-diffusion-webui/wiki/Textual-Inversion)：原生 embedding 与 Hypernetwork 训练流程。
- [A1111 UI source（调研时固定 commit）](https://github.com/AUTOMATIC1111/stable-diffusion-webui/blob/82a973c04367123ae98bd9abdf80d9eda9b910e2/modules/ui.py#L899-L990)：Train 页当前能力的源码边界。
- [A1111 API source（同一 commit）](https://github.com/AUTOMATIC1111/stable-diffusion-webui/blob/82a973c04367123ae98bd9abdf80d9eda9b910e2/modules/api/api.py)：原生训练 API 只有 embedding/Hypernetwork，没有 LoRA trainer。
- [sd-scripts](https://github.com/kohya-ss/sd-scripts)：LoRA、fine-tuning、Textual Inversion 等训练脚本及安装文档。
- [sd-scripts fine-tuning guide](https://github.com/kohya-ss/sd-scripts/blob/main/docs/fine_tune.md)：全量 fine-tune 与 LoRA 的资源/产物差异。
- [sd-scripts dataset config](https://github.com/kohya-ss/sd-scripts/blob/main/docs/config_README-en.md)：数据集 TOML、caption 与 bucket 规范。
- [kohya_ss](https://github.com/bmaltais/kohya_ss)：基于 sd-scripts 的 GUI/CLI 候选。
