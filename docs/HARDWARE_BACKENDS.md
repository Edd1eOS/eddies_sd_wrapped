# Hardware backends

Windows only. NVIDIA retains the existing AUTOMATIC1111 profiles and commits. Intel/AMD use the separate AGPL-3.0 `lshqqytiger/stable-diffusion-webui-amdgpu` compatibility fork, pinned to `9cb6e4c5431b440b55dc5da037bcdbcf220bf511`, with torch 2.4.1, torchvision 0.19.1 and torch-directml 0.2.5.dev240914. CPU uses the pinned original A1111 with CPU PyTorch.

Use **选择显卡 / 安装后端**, select a profile, and confirm installation. Stop the current engine first. Each backend has its own `data/runtime/versions/<profile>-<commit>` environment. Models and outputs are shared; failed installation does not replace the active environment. Previously installed backends can be selected again and are checked before activation.

Intel is DirectML, not native XPU/IPEX. Arc is the first target; Core Ultra graphics, Iris Xe and UHD are not universally supported. A compatible DirectX 12 device and vendor driver are required. The launcher checks adapter names and a tensor operation, prefers Arc among Intel adapters, and explicitly passes the selected DirectML device index on startup. An absent requested vendor fails rather than selecting another vendor or CPU. Operator-level CPU fallback inside DirectML is a separate upstream behavior; this is not a guarantee all operations are GPU-native. AMD uses the same mechanism for AMD/Radeon devices.

The standard/Blackwell NVIDIA environments remain unchanged. LoRA training has its own hardware selector and isolated dependencies; selecting Intel DirectML for generation does **not** configure Intel training. The separate experimental XPU / CPU training adapters and their validation limits are documented in [TRAINING_BACKENDS.md](TRAINING_BACKENDS.md).

DirectML defaults to full precision, low-VRAM offload and split attention. New DirectML settings disable the upstream Windows PDH memory-statistics provider, which threw `PDHError` on this machine. The replacement upstream provider is an estimate, not a measurement of usable VRAM. Low-VRAM mode avoids the allocation failures observed at 512×512 without offload. These settings prioritize compatibility over speed, but do not guarantee correct output on every device.

Validation on 2026-10-03:

- All 38 core tests, WPF lifecycle tests, hardware configuration/PDH tests, and five device-selection unit tests pass. Existing RTX 5070 Laptop / CUDA environment remains active and its doctor reports zero failures/warnings.
- A fresh isolated Intel installation completed, `pip check` passed, the device probe selected adapter 1 (`Intel(R) Graphics`, driver `32.0.101.8331`) instead of the NVIDIA adapter, and WebUI start/stop and API generation completed.
- **Intel image-quality acceptance FAILED.** SD 1.5 generated 512×512 / Euler / CFG 6 / seed 1234 at 12 and 20 steps; both outputs had severe color/detail artifacts. A Deliberate v6 / 12-step comparison also produced a degraded result. CPU noise and alternate attention implementations did not resolve quality. The source of this numerical/decoder/driver issue has not been isolated. Do not market this as verified Intel support merely because the API returns an image.
- Logs and output evidence are retained locally under `data/hardware-validation/` (Git-ignored). The original NVIDIA runtime/configuration was not switched. No Arc or AMD physical-device validation and no fresh CPU-only installation test have been completed.

Next acceptance gate: resolve the Intel output-quality issue or validate a different Intel backend, then compare actual images and test setup → start → image → stop on target Arc hardware. Selecting Intel generation does not validate LoRA training, all models, or extensions.

Upstream references: [pinned fork](https://github.com/lshqqytiger/stable-diffusion-webui-amdgpu/tree/9cb6e4c5431b440b55dc5da037bcdbcf220bf511), [Microsoft DirectML](https://github.com/microsoft/DirectML). No model weights or vendor drivers are bundled.
