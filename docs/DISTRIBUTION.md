# Distribution Plan

## 克隆后体验

```text
git clone <future-github-repository>
cd stable-diffusion-workbench
双击 Start Stable Diffusion.cmd
```

Launcher 的 setup 根据硬件选择固定 Profile，从官方来源获取并校验 A1111 便携引导包及精确 commit，在仓库外建立隔离环境。用户可以导入现有 `.safetensors`；入门模型只有在界面展示大小、社区镜像说明、来源与许可并取得明确确认后才下载。

Windows MVP 不要求预装 Python/Git：setup 使用 A1111 官方便携包中的 Python 3.10.6 和 Git，且只在子进程环境中设置它们，不改写系统 `PATH`。标准 NVIDIA Profile 固定 v1.10.1；RTX 50/Blackwell 使用固定 dev commit 的实验 Profile。两者不追踪浮动分支。EFS 加密数据目录会被预检拒绝，用户可在 Launcher 中选择未加密的本地目录。

用户不需要复制 virtualenv 配置或手工选择解释器；环境引导、配置位置和禁止修改的全局状态见 [`ENVIRONMENT_ISOLATION.md`](ENVIRONMENT_ISOLATION.md)。

## 仓库内容

- Windows WinForms Launcher、A1111 生命周期适配层和安全模型导入/下载入口
- 上游/依赖 lock、Profile、配置 Schema、模型/扩展 manifest
- setup/start/stop/doctor/status/configure 与目录打开脚本
- 测试、文档、第三方声明与 SBOM 生成配置

## 不进入仓库

- A1111 checkout、虚拟环境、模型权重、扩展 checkout
- 用户配置、输入、输出、缓存、日志和凭据

上游采用 AGPL-3.0。分发修改版、网络提供修改版、打包源码/二进制以及独立进程组合的具体义务应在发布前正式审查。模型和扩展拥有各自许可证，默认不随 Release 再分发。

当前 Release 只分发本项目的小型代码和 manifest。约 52.7 MB 的官方便携包、A1111 checkout、PyTorch、约 4.27 GB 的可选入门模型和所有用户产物均在 setup/用户确认后从 manifest 记录的来源进入仓库外数据目录。

后续正式面向非技术用户分发时，Release 应提供可签名的 Windows `.exe`/安装器和清晰的首次运行向导。应用仍以固定版本 A1111 作为本地推理后端，但普通用户默认进入简化生成界面；原生 WebUI 作为高级入口保留。大型运行时、PyTorch 与模型不直接塞入安装器，而是在用户确认目录、磁盘空间、来源和许可后下载并校验。
