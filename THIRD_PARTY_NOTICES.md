# Third-Party Notices

当前仓库尚未 vendoring 或打包第三方源码、二进制、扩展或模型。

计划集成的核心上游为 [AUTOMATIC1111/stable-diffusion-webui](https://github.com/AUTOMATIC1111/stable-diffusion-webui)，许可证为 AGPL-3.0。正式 setup/Release 引入任何固定版本后，本文件将记录完整 commit、许可证、修改、源码获取方式和传递依赖声明。

模型权重与扩展拥有独立许可证，不因上游 WebUI 的许可证而自动允许再分发。

LoRA 训练计划评估 [`kohya-ss/sd-scripts`](https://github.com/kohya-ss/sd-scripts) 作为独立后端。其仓库说明主体/多数代码使用 Apache-2.0，但包含单独许可部分，不能把全部内容概括为单一许可证；[`bmaltais/kohya_ss`](https://github.com/bmaltais/kohya_ss) 专家 GUI 候选本身为 Apache-2.0。二者目前都尚未引入、修改或随本仓库分发；实现阶段必须固定版本并逐项核对仓库内文件及传递依赖许可证。

数据集自动 caption 计划评估 WD14 ONNX 路径，其代码、模型权重和标签数据可能具有彼此独立的来源与许可证。目前它只是候选能力，未通过来源、许可证与隐私审查前不得由 setup 默认下载或再分发。
