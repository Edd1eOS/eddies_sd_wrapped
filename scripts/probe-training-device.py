"""Exercise explicit training device, gradients and an optimizer; never fall back."""
import argparse
import json
import os
import sys
import threading
import torch

def check(backend):
    if backend not in ("cuda", "xpu", "cpu"):
        raise ValueError("Unsupported training backend")
    if backend != "cpu":
        api = getattr(torch, backend, None)
        if api is None or not api.is_available():
            raise RuntimeError(f"{backend} training device unavailable. Check GPU and driver; no CPU fallback.")
        name = api.get_device_name(0)
    else:
        name = "CPU (explicit choice)"
    device = torch.device(backend)
    torch.manual_seed(42)
    model = torch.nn.Linear(8, 4).to(device)
    x = torch.ones((4, 8), device=device)
    initial = model.weight.detach().cpu().clone()
    optimizer = torch.optim.AdamW(model.parameters(), lr=0.01)
    for _ in range(3):
        optimizer.zero_grad()
        loss = model(x).square().mean()
        if not torch.isfinite(loss).item():
            raise RuntimeError("Non-finite training loss")
        loss.backward()
        if not all(p.grad is not None and torch.isfinite(p.grad).all().item() for p in model.parameters()):
            raise RuntimeError("Invalid training gradients")
        optimizer.step()
    if torch.equal(initial, model.weight.detach().cpu()):
        raise RuntimeError("Optimizer did not update weights")
    return {"backend": backend, "name": name, "torch": torch.__version__, "backward": True,
            "optimizer": "AdamW", "full_lora_training_verified": False}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("backend", choices=["cuda", "xpu", "cpu"])
    args = parser.parse_args()
    def timed_out():
        print("Training device check timed out after 300 seconds; check GPU driver. No CPU fallback.",
              file=sys.stderr, flush=True)
        os._exit(2)
    watchdog = threading.Timer(300, timed_out)
    watchdog.daemon = True
    watchdog.start()
    try:
        print(json.dumps(check(args.backend)))
    finally:
        watchdog.cancel()
