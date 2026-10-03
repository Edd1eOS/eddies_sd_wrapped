import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import torch

spec = importlib.util.spec_from_file_location('training_probe', Path(__file__).parents[1] / 'scripts/probe-training-device.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

class TrainingProbeTests(unittest.TestCase):
    def test_cpu_backward_and_weight_update(self):
        self.assertTrue(probe.check('cpu')['backward'])
    def test_cuda_cannot_fall_back(self):
        with patch.object(torch.cuda, 'is_available', return_value=False):
            with self.assertRaisesRegex(RuntimeError, 'no CPU fallback'):
                probe.check('cuda')
    def test_xpu_cannot_fall_back(self):
        with patch.object(torch.xpu, 'is_available', return_value=False):
            with self.assertRaisesRegex(RuntimeError, 'no CPU fallback'):
                probe.check('xpu')
    def test_unknown_backend_rejected(self):
        with self.assertRaises(ValueError):
            probe.check('directml')

if __name__ == '__main__':
    unittest.main()
