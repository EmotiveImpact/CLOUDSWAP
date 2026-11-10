import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('placement_lab', ROOT / 'lab.py')
LAB = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(LAB)


class PlacementGuardTests(unittest.TestCase):
    def test_actual_mac_page_io_format_and_firmlink_alias(self):
        target = '/Volumes/CloudSwapLab-test'
        line = '15:36:17.081768 PgOut[AT2P] D=0x000014fc B=0x40000 /dev/disk3s1 ' + target + '/swapfile0 0.000752 W kernel_task.389'
        event = LAB.page_io(line, target, 'disk3s1')
        self.assertEqual(event['direction'], 'out')
        self.assertEqual(event['bytes'], 262144)
        self.assertEqual(event['process_pid'], 389)
        alias = line.replace('PgOut[AT2P]', 'PgIn[ST2]').replace(target, '/System/Volumes/Data' + target)
        self.assertEqual(LAB.page_io(alias, target, 'disk3s1')['direction'], 'in')
        self.assertIsNone(LAB.page_io(line, target, 'disk4s1'))
        self.assertIsNone(LAB.page_io(line.replace('swapfile0', 'swapfile0.other'), target, 'disk3s1'))
        self.assertIsNone(LAB.page_io('stat64 ' + target + '/swapfile0', target, 'disk3s1'))

    def test_memory_budget_always_reserves_two_gib_and_caps_twelve(self):
        for gib in (2, 3, 4, 7, 14, 16, 64):
            ram = gib * 1024 * LAB.MIB
            limit = LAB.workload_mib(ram) * LAB.MIB
            self.assertLessEqual(limit, max(0, ram - 2048 * LAB.MIB))
            self.assertLessEqual(limit, ram * 85 // 100)
            self.assertLessEqual(limit, 12288 * LAB.MIB)
            self.assertEqual(limit % (64 * LAB.MIB), 0)

    def test_lab_refuses_without_explicit_disposable_flag_before_writing(self):
        environment = dict(os.environ); environment.pop('CLOUDSWAP_CI_PLACEMENT', None)
        with tempfile.TemporaryDirectory() as temp:
            report = Path(temp) / 'report.json'
            result = subprocess.run([sys.executable, str(ROOT / 'lab.py'),
                '--ci-change-prefix-on-disposable-runner', '--probe', '/does/not/exist',
                '--report', str(report)], env=environment, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'Refused:', result.stderr)
            self.assertFalse(report.exists())


@unittest.skipUnless(os.environ.get('CLOUDSWAP_MEMORY_PROBE'), 'compiled Mac probe required')
class MemoryProbeTests(unittest.TestCase):
    def run_probe(self, value):
        environment = dict(os.environ); environment.pop('CLOUDSWAP_CI_PLACEMENT', None)
        return subprocess.run([os.environ['CLOUDSWAP_MEMORY_PROBE'], value], input='verify\n',
                              env=environment, capture_output=True, text=True, timeout=10)
    def test_small_workload_verifies_every_word(self):
        result = self.run_probe('32')
        self.assertEqual(result.returncode, 0, result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(events[-1]['event'], 'verified')
        self.assertEqual(events[-1]['bytes'], 32 * LAB.MIB)
    def test_large_workload_refused_without_explicit_ci_flag(self):
        result = self.run_probe('128')
        self.assertEqual(result.returncode, 3)
        self.assertFalse(result.stdout)
    def test_bad_sizes_refused_before_allocation(self):
        for value in ('0', '-1', 'x', '12289', '999999999999999999999999'):
            with self.subTest(value=value):
                result = self.run_probe(value)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(result.stdout)


if __name__ == '__main__': unittest.main()
