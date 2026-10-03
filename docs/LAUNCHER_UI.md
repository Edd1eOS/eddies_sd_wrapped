# 启动器界面

采用与 ComfyUI 工作台一致的浅绿色玻璃风格：半透明卡片、柔和背景、圆角按钮、自定义标题栏与折叠日志。

文案和布局：`launcher/StableDiffusionWorkbench.xaml`。界面控制：`launcher/StableDiffusionWorkbench.ps1`。启动入口、CLI、进程归属校验、模型导入、许可确认与用户存储设置保持不变。原生文件和目录选择窗口继续使用系统对话框。

启动、停止、打开生成界面始终可点击；条件不满足时说明原因，不隐藏操作。执行任务时展开日志并显示忙碌提示；维护操作沿用原来的并发限制。

验证：运行 `tests/run.ps1` 和 `tests/test-launcher-ui.ps1`。使用 Windows PowerShell 5.1 的 `-STA` 模式。启动器的 `-PreviewPath <png>` 输出不启动引擎的预览；可加 `-PreviewWidth`、`-PreviewHeight`、`-PreviewLogs` 检查排版。`-LiveStatusPreview` 在预览时额外测试真实状态子进程与界面定时刷新，不启动或停止生成引擎。
