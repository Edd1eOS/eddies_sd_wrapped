# scripts

统一命令入口为：

- `sdw.ps1 -Command setup`：环境检查、便携运行时、固定 Profile、上游和依赖准备
- `start`：启动并记录可控的进程状态
- `stop`：只停止本项目启动的进程
- `doctor`：只读优先地诊断依赖、GPU、端口、目录与配置
- `status` / `logs` / `open-ui`：状态、日志与本地界面
- `configure`：配置仓库外数据目录和端口
- `import-model` / `download-starter-model`：准备生成所需权重
- `open-data` / `open-models` / `open-outputs`：打开受控用户目录

`supervisor.ps1` 是内部进程托管器，不应由用户直接运行。所有入口使用明确退出码；`status -Json` 供 Launcher 消费。当前只实现 Windows PowerShell 5.1，其他平台后续保持相同命令语义。
