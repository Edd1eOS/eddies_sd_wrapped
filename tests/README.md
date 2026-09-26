# tests

本地快速测试不下载 A1111、PyTorch 或模型，会覆盖：

- Windows PowerShell 5.1 语法解析与核心模块导入；
- 锁文件、profile、SHA-256 和许可信息一致性；
- 带空格、中文、引号与反斜杠的命令行传参；
- 配置、模型导入、许可门禁、状态、诊断与进程所有权；
- 图形启动器的核心安全参数、环境隔离约束与双击入口。

在仓库根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
```

测试仅在系统临时目录创建带随机 ID 的小型夹具，并在结束时删除。它不使用真实密钥或提交模型权重。
