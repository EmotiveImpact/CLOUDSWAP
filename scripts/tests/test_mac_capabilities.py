import importlib.util
import pathlib
import subprocess
import unittest

spec = importlib.util.spec_from_file_location('capabilities', pathlib.Path(__file__).parents[1] / 'mac-capabilities.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class CapabilityTests(unittest.TestCase):
    def test_denied_is_not_unsupported(self):
        self.assertEqual(m.classify(1, '', 'Operation not permitted')['state'], 'access_denied')
        self.assertEqual(m.classify(1, '', 'unknown oid')['state'], 'not_exposed')
    def test_readable_prefix_does_not_claim_swap_support(self):
        def run(command, **kwargs):
            value = 'Darwin root:xnu-10063.121.3~5/RELEASE_ARM64_TEST' if command[-1] == '-v' else '/System/Volumes/VM/swapfile'
            return subprocess.CompletedProcess(command, 0, value, '')
        report = m.collect(run)
        self.assertEqual(report['capability_verdict'], 'unverified')
        self.assertFalse(report['external_swap_verified'])
        self.assertEqual(report['observations']['kernel_build']['xnu_version'], '10063.121.3')
    def test_timeout_and_missing_tools_are_recorded(self):
        def run(command, **kwargs):
            raise subprocess.TimeoutExpired(command, 10)
        self.assertTrue(all(x['state'] == 'unavailable' for x in m.collect(run)['observations'].values()))
    def test_inventory_commands_are_read_only(self):
        for command in m.COMMANDS.values():
            self.assertNotIn('-w', command)
            self.assertFalse(any('=' in arg for arg in command))
            self.assertNotIn('sudo', command)
            self.assertNotIn('-a', command)

if __name__ == '__main__':
    unittest.main()
