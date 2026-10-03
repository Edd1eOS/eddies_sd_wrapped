import contextlib
import io
import json
from pathlib import Path
import runpy
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

PROBE = Path(__file__).resolve().parents[1] / 'scripts' / 'probe-device.py'

class Tensor:
    def __matmul__(self, other): return self
    def cpu(self): return self
    def sum(self): return self
    def item(self): return 4096

class ProbeTests(unittest.TestCase):
    def invoke(self, backend, vendor='', names=()):
        torch = SimpleNamespace(__version__='test', device=lambda name:name,
            ones=lambda *a, **kw:Tensor(),
            cuda=SimpleNamespace(is_available=lambda:False, get_device_name=lambda _: 'NVIDIA'))
        dml = SimpleNamespace(device_count=lambda:len(names), device_name=lambda i:names[i], device=lambda i:i)
        args = [str(PROBE), backend] + (['--vendor', vendor] if vendor else [])
        output = io.StringIO()
        with patch.dict(sys.modules, {'torch':torch,'torch_directml':dml}), patch.object(sys,'argv',args), contextlib.redirect_stdout(output):
            runpy.run_path(str(PROBE),run_name='__main__')
        return json.loads(output.getvalue())

    def test_arc_preferred_and_index_preserved(self):
        result=self.invoke('directml','intel',['NVIDIA RTX','Intel UHD','Intel Arc A770'])
        self.assertEqual(result['index'],2)
    def test_amd_does_not_select_intel(self):
        self.assertEqual(self.invoke('directml','amd',['Intel UHD','AMD Radeon'])['index'],1)
    def test_no_wrong_vendor_or_cpu_fallback(self):
        with self.assertRaises(RuntimeError): self.invoke('directml','intel',['NVIDIA RTX'])
    def test_missing_cuda_fails(self):
        with self.assertRaises(RuntimeError): self.invoke('cuda')
    def test_explicit_cpu(self):
        self.assertEqual(self.invoke('cpu')['backend'],'cpu')

if __name__=='__main__': unittest.main()
