# Third-Party Notices

本仓库不提交、vendoring 或随 Release 重新分发 A1111 源码、Python/Git 二进制、PyTorch wheel 或模型权重。Launcher 会在用户本地按以下固定来源下载，并将运行时放在 Git 仓库之外。

## 当前运行时

### AUTOMATIC1111 Stable Diffusion WebUI

- 上游：[`AUTOMATIC1111/stable-diffusion-webui`](https://github.com/AUTOMATIC1111/stable-diffusion-webui)
- 许可：AGPL-3.0，详见上游 [`LICENSE.txt`](https://github.com/AUTOMATIC1111/stable-diffusion-webui/blob/master/LICENSE.txt)
- 标准 Profile：`82a973c04367123ae98bd9abdf80d9eda9b910e2`（v1.10.1）
- RTX 50/Blackwell 实验 Profile：`1937682a20f7f0442311a1ede68f9f0cb480163b`
- 获取方式：setup 直接从 GitHub 获取精确 commit，不跟踪浮动分支。

### A1111 官方 Windows 便携引导包

- 来源：[`sd.webui.zip`](https://github.com/AUTOMATIC1111/stable-diffusion-webui/releases/download/v1.0.0-pre/sd.webui.zip)
- 大小：`52,701,884` bytes
- SHA-256：`1384F18FDAA3C21BF7BC4976A6BF5A9672B71F25FA7CCF1AE6660AD461B1A42C`
- 用途：Launcher 只提取其 `system/` 中的便携 Python 3.10.6、Git 和 pip 引导文件；包内旧 WebUI 不会被启动。

该引导包包含多个独立第三方组件，包括 Python 和 Git，其各自许可不因 A1111 的 AGPL-3.0 而改变。本项目当前只下载并校验官方包，不重新打包这些二进制。

### PyTorch 与生成依赖

- 标准 Profile：PyTorch `2.1.2` + torchvision `0.16.2` + CUDA 12.1 wheel 源。
- RTX 50/Blackwell Profile：PyTorch `2.7.0` + torchvision `0.22.0` + CUDA 12.8 wheel 源。
- 其他 Python 依赖由固定 A1111 commit 的安装流程获取。

这些包均由用户本地环境下载；发布前还需为打包分发场景生成完整 SBOM 与递归许可清单。

## 可选入门模型

- 资产：Stable Diffusion v1.5 `v1-5-pruned-emaonly.safetensors`
- 来源：[`stable-diffusion-v1-5/stable-diffusion-v1-5`](https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5)
- 来源状态：这是已废弃 RunwayML 仓库的社区镜像，与 RunwayML 无隶属关系。
- 大小：`4,265,146,304` bytes
- SHA-256：`6ce0161689b3853acaa03779ec93eafe75a02f4ced659bee03f50797806fa2fa`
- 许可：[`CreativeML OpenRAIL-M`](https://huggingface.co/spaces/CompVis/stable-diffusion-license)

该镜像文件的大小与 SHA-256 与原 SD 1.5 checkpoint 一致。Launcher 会在下载前显示来源、镜像说明、大小和许可链接；只有用户明确确认后才会下载。模型权重不进入本 Git 仓库。

## 未引入的训练候选

LoRA 训练计划评估 [`kohya-ss/sd-scripts`](https://github.com/kohya-ss/sd-scripts) 作为独立后端。其仓库说明主体/多数代码使用 Apache-2.0，但包含单独许可部分，不能把全部内容概括为单一许可；[`bmaltais/kohya_ss`](https://github.com/bmaltais/kohya_ss) 专家 GUI 候选本身为 Apache-2.0。二者目前都尚未引入、修改或随本仓库分发。

数据集自动 caption 计划评估 WD14 ONNX 路径。其代码、模型权重和标签数据可能具有彼此独立的来源与许可；它们未通过来源、许可与隐私审查前不得由 setup 默认下载或再分发。
