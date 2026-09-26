# Distribution Plan

## 克隆后体验

```text
git clone <future-github-repository>
cd stable-diffusion-workbench
./scripts/setup.ps1
./scripts/doctor.ps1
./scripts/start.ps1
```

setup 根据硬件选择已验证 Profile，从官方仓库获取精确 tag/commit，创建隔离环境，并让用户选择仓库外数据目录。它不会自动下载大型模型；用户选择 manifest、查看大小与许可证并确认后才下载。

## 仓库内容

- Launcher、资产中心、A1111 适配层和独立 MCP 服务
- 上游/依赖 lock、Profile、配置 Schema、模型/扩展 manifest
- setup/start/stop/doctor/update/rollback 脚本
- 测试、文档、第三方声明与 SBOM 生成配置

## 不进入仓库

- A1111 checkout、虚拟环境、模型权重、扩展 checkout
- 用户配置、输入、输出、缓存、日志和凭据

上游采用 AGPL-3.0。分发修改版、网络提供修改版、打包源码/二进制以及独立进程组合的具体义务应在发布前正式审查。模型和扩展拥有各自许可证，默认不随 Release 再分发。
