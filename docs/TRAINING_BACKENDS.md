# LoRA training backends (Windows)

Use **配置训练环境** to select training hardware. Selection is independent from image generation. An Intel i7 CPU is not an Intel GPU; an i7 + RTX machine should select NVIDIA.

| Choice | Installation | Status |
| --- | --- | --- |
| NVIDIA / CUDA | Existing pinned Kohya uv.lock; existing `data/training` is preserved | Existing integration; full LoRA quality depends on dataset/model |
| Intel / XPU | Pinned Kohya `requirements_ipex_xpu.txt`, PyTorch 2.7.1+xpu / torchvision 0.22.1+xpu | Experimental; requires an XPU-supported GPU and driver, not every Intel iGPU |
| CPU | CPU PyTorch 2.7.1 / torchvision 0.22.1, same GUI/training scripts | Explicit slow fallback; not a practical speed promise |
| AMD | No Windows installer enabled | Requires a separately validated ROCm/system integration; DirectML inference is not training support |

Intel and CPU have separate `data/training/backends/<profile>/` Python, dependencies, settings, logs and ownership state. Datasets and training outputs remain `datasets/lora` and `training-runs`. Ports are 7861 / 7862 / 7863. Installation failure does not change `selection.json`; previous NVIDIA installations without that file remain valid. Stop the current training service before switching. `scripts/training.ps1 -Command training-setup -ProfileId intel-xpu -PrepareOnly` can prepare a separate environment without activating it or interrupting the existing service.

Non-CUDA profiles use AdamW, SDPA and full precision by default, not CUDA xformers or 8-bit optimizers. Loading a saved user preset can override these defaults; do not reuse a CUDA-only training preset unchanged. Selecting a profile does not launch training. The probe verifies device availability, finite loss/gradients and an AdamW weight update, with no silent CPU fallback. This is a smoke test, **not full LoRA training or image-quality acceptance**.

NVIDIA retains its frozen lock. Intel/CPU use version-pinned upstream requirement files plus explicit torch constraints; upstream contains some version ranges, so these two dependency graphs are not yet fully frozen. Successful installations record `requirements-resolved.txt` for audit. No weights, datasets, Python runtimes or downloaded third-party source are committed.

Sources: [pinned Kohya XPU requirements](https://github.com/bmaltais/kohya_ss/blob/45088f04af78e11cec5407ff4652ea3ed2c14422/requirements_ipex_xpu.txt), [PyTorch Intel GPU documentation](https://docs.pytorch.org/docs/stable/notes/get_start_xpu.html). Upstream labels the XPU installer Linux-oriented; this Windows adapter is experimental and requires its own acceptance tests.

Validation on 2026-10-04:

- 38 core tests, WPF lifecycle tests, training isolation/defaults tests and four Python probe tests pass. Full launcher preview renders successfully.
- Existing RTX 5070 Laptop CUDA environment passes finite-gradient and AdamW weight-update smoke tests. Existing training service and selected backend are preserved.
- Fresh Intel XPU environment installs 158 packages; dependency check and `train_network.py --help` pass. On this machine's Intel integrated graphics, the optimizer probe did not finish within 300 seconds and was stopped; **device validation did not pass**. No ready marker or backend selection was written. New probes have a 300-second watchdog. Arc and complete LoRA training remain untested.
- CPU dependency dry-run resolves successfully; CPU optimizer smoke test passes using the existing Python environment. A fresh CPU-only installation and full LoRA training have not been tested.
- No AMD physical-device validation. No new model weights or training dataset are downloaded for these checks.
