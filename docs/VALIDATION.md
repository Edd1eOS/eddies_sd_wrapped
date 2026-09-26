# 实机验收记录

## 2026-09-26：Windows / RTX 5070 Laptop

本轮验收使用公开仓库中的 Launcher/Core 代码和一个已有的 SD 1.5 `.safetensors` checkpoint。旧 A1111 目录只作为模型的只读来源；没有执行或复制旧目录中的 Python、Git、venv、扩展或启动参数。

| 项目 | 验收结果 |
| --- | --- |
| 系统 | Windows x64 |
| GPU | NVIDIA GeForce RTX 5070 Laptop GPU，8151 MiB VRAM，驱动 592.01 |
| Profile | `windows-nvidia-blackwell`（Experimental） |
| A1111 commit | `1937682a20f7f0442311a1ede68f9f0cb480163b` |
| 私有 Python | 3.10.6；未写入用户/系统 `PATH` |
| PyTorch | `2.7.0+cu128`，CUDA runtime 12.8，`torch.cuda.is_available() == True` |
| Python 依赖 | `pip check`：`No broken requirements found` |
| 数据目录 | `D:\StableDiffusionWorkbench`；EFS 预检通过 |
| 模型 | `anything-v5.safetensors`，2,132,626,102 bytes，SHA-256 `7f96a1a9ca9b3a3242a9ae95d19284f0d2da8d5282b42d2d974398bf7663a252` |

## 已通过的闭环

1. 根目录双击入口成功打开 WinForms Launcher；启动后保持响应，并从已保存的数据目录读取 Ready 状态。
2. 从空数据目录执行 setup，下载并校验便携引导包，检出精确 A1111 commit，安装固定打包工具链、PyTorch/cu128 和上游依赖。
3. 对已有 checkpoint 执行只读源导入；副本进入仓库外用户数据目录，源文件未修改。
4. `doctor` 的平台、GPU、Profile、磁盘、EFS、运行时、Git 工作树、Python/Torch/CUDA、Python 依赖、模型、状态和端口检查全部通过（0 failure / 0 warning）。
5. `start` 启动受 supervisor 管理的进程，只绑定 `127.0.0.1:7860`；`/internal/ping` 与 `/sdapi/v1/sd-models` 正常响应。
6. 通过 `/sdapi/v1/txt2img` 使用固定 seed `123456789`、8 steps 生成 256 × 256 PNG；图片保存至仓库外 `userdata/outputs/`。
7. `stop` 先验证 PID、启动时间、owner token 和 supervisor 路径，再通过 A1111 stop API 正常退出；最终端口可用、状态为 Ready。
8. 修复流程重新归一化依赖，清理上游解析遗留的 orphan 包，并再次通过 `pip check`、CUDA 和精确 commit 校验。

仓库测试另在 Windows PowerShell 5.1 下覆盖 JSON/lock、参数引用、配置、模型导入、许可门槛、进程所有权、loopback/API 固定参数、环境隔离和双击入口。发布前仍应在标准（非 Blackwell）NVIDIA Profile 上补充同等实机矩阵。
