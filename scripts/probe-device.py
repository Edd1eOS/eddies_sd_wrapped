"""Check an explicit backend and select a matching DirectML adapter. No CPU fallback."""
import argparse
import json
import torch

parser = argparse.ArgumentParser()
parser.add_argument("backend", choices=["cuda", "cpu", "directml"])
parser.add_argument("--vendor", default="")
args = parser.parse_args()
index = None
if args.backend == "directml":
    import torch_directml as dml
    names = [dml.device_name(i).rstrip("\x00") for i in range(dml.device_count())]
    tokens = {"intel": ["intel"], "amd": ["amd", "radeon"]}[args.vendor]
    matches = [i for i, name in enumerate(names) if any(t in name.lower() for t in tokens)]
    if not matches:
        raise RuntimeError(f"No {args.vendor} DirectML adapter. Detected: {names}. Check the driver; no CPU fallback.")
    # Prefer Arc over an older integrated Intel device when both are present.
    index = next((i for i in matches if "arc" in names[i].lower()), matches[0])
    device, name = dml.device(index), names[index]
elif args.backend == "cuda":
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA unavailable; check NVIDIA driver and selected hardware profile")
    device, name = torch.device("cuda"), torch.cuda.get_device_name(0)
else:
    device, name = torch.device("cpu"), "CPU"
x = torch.ones((16, 16), device=device)
assert (x @ x).cpu().sum().item() == 4096, "Device computation failed"
print(json.dumps({"backend": args.backend, "name": name, "index": index, "torch": torch.__version__}))
