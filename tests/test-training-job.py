"""Runtime test: stopping a training host also stops its child process."""
import ctypes
from ctypes import wintypes
import pathlib
import subprocess
import sys

host = pathlib.Path(__file__).resolve().parents[1] / 'scripts' / 'training-host.py'
code = (
    'import runpy,subprocess,sys,time; '
    f"ns=runpy.run_path({str(host)!r}); job=ns['attach_job'](); "
    "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(90)']); "
    'print(child.pid,flush=True); time.sleep(90)'
)
parent = subprocess.Popen([sys.executable, '-u', '-c', code], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True,
                          creationflags=subprocess.CREATE_NO_WINDOW)
kernel = ctypes.WinDLL('kernel32', use_last_error=True)
kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel.OpenProcess.restype = wintypes.HANDLE
kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel.CloseHandle.argtypes = [wintypes.HANDLE]
child_handle = None
try:
    child_pid = int(parent.stdout.readline().strip())
    child_handle = kernel.OpenProcess(0x100000, False, child_pid)
    assert child_handle, 'Cannot inspect test child process'
    parent.terminate()
    parent.wait(timeout=10)
    assert kernel.WaitForSingleObject(child_handle, 10000) == 0, 'Training child survived host termination'
    print('PASS: Windows job terminates owned training descendants.')
finally:
    if parent.poll() is None:
        parent.terminate()
        parent.wait(timeout=10)
    if child_handle:
        kernel.CloseHandle(child_handle)
