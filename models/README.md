# models

此目录是启动器默认识别的模型位置。主模型放 `Checkpoints/`，VAE 放 `VAE/`，LoRA 放 `Lora/`，其余扩展分别放 `Hypernetworks/`、`Embeddings/`、`Codeformer/`、`GFPGAN/`。这些主要是 PyTorch 生态的权重，不是 TensorFlow 模型；**不得提交任何模型权重**。

后续下载流程应记录模型来源、许可证、固定版本、SHA-256、架构兼容性和 trigger words，并让用户明确接受适用条款。优先 `.safetensors`，旧 `.ckpt` 作为显式风险兼容选项。实际权重文件由 `.gitignore` 排除。
