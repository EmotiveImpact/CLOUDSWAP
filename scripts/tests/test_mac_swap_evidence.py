import copy
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('evidence', Path(__file__).parents[1] / 'mac-swap-evidence.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class SwapEvidenceTests(unittest.TestCase):
    def pair(self):
        before = {'schema_version': 1, 'sample_monotonic_ns': 1,
                  'boot_session': {'state': 'observed', 'value': 'boot'},
                  'prefix': {'state': 'observed', 'value': '/test/swapfile'},
                  'prefix_matches_target': True,
                  'directory': {'state': 'observed', 'device': 4, 'inode': 8, 'files': [],
                                'rejected_entries': 0, 'allocated_bytes': 0},
                  'paging': {'state': 'observed', 'page_bytes': 16384, 'swapins': 10, 'swapouts': 20}}
        after = copy.deepcopy(before)
        after['sample_monotonic_ns'] = 2
        after['directory']['files'] = [{'name': 'swapfile0', 'device': 4, 'inode': 9}]
        after['directory']['allocated_bytes'] = 4096
        after['paging']['swapouts'] = 25
        return before, after

    def test_candidate_is_never_native_swap_proof(self):
        report = m.compare(*self.pair())
        self.assertTrue(report['candidate_placement_observed'])
        self.assertEqual(report['target_allocated_byte_delta'], 4096)
        self.assertFalse(report['native_external_swap_verified'])

    def test_file_growth_without_paging_is_not_candidate(self):
        before, after = self.pair()
        after['paging']['swapouts'] = 20
        self.assertFalse(m.compare(before, after)['candidate_placement_observed'])

    def test_paging_without_file_growth_is_not_candidate(self):
        before, after = self.pair()
        after['directory'] = copy.deepcopy(before['directory'])
        self.assertFalse(m.compare(before, after)['candidate_placement_observed'])

    def test_reboot_replaced_volume_and_counter_reset_are_rejected(self):
        for group, key, value in [('boot_session', 'value', 'another'), ('directory', 'device', 99),
                                  ('directory', 'inode', 99), ('paging', 'swapouts', 0),
                                  ('paging', 'page_bytes', 4096), ('prefix', 'value', '/other/swapfile')]:
            with self.subTest(group=group, key=key):
                before, after = self.pair()
                after[group][key] = value
                self.assertEqual(m.compare(before, after)['state'], 'incomparable')

    def test_denied_or_unmatched_prefix_is_not_unsupported(self):
        before, after = self.pair()
        after['prefix'] = {'state': 'access_denied'}
        result = m.compare(before, after)
        self.assertEqual(result['state'], 'insufficient_evidence')
        self.assertFalse(result['native_external_swap_verified'])
        before, after = self.pair()
        after['prefix_matches_target'] = False
        self.assertEqual(m.compare(before, after)['state'], 'insufficient_evidence')

    def test_out_of_order_samples_rejected(self):
        before, after = self.pair()
        after['sample_monotonic_ns'] = 1
        self.assertEqual(m.compare(before, after)['state'], 'incomparable')

    def test_metadata_inventory_rejects_symlinks_and_ignores_unrelated_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'swapfile0').write_bytes(b'a' * 4096)
            (path / 'private.txt').write_text('not read')
            (path / 'swapfile1').symlink_to(path / 'private.txt')
            result = m.inventory(tmp)
            self.assertEqual([f['name'] for f in result['files']], ['swapfile0'])
            self.assertEqual(result['rejected_entries'], 1)
            self.assertEqual(result['allocated_bytes'], (path / 'swapfile0').stat().st_blocks * 512)
            (path / 'alias').symlink_to(path, target_is_directory=True)
            self.assertEqual(m.inventory(str(path / 'alias'))['state'], 'unavailable')

    def test_vm_stat_parser_uses_swap_not_general_pageout_counts(self):
        text = 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPageouts: 900.\nSwapins: 5.\nSwapouts: 7.\n'
        self.assertEqual(m.counters(text)['swapouts'], 7)
        self.assertEqual(m.counters('Pageouts: 900.'), {'state': 'unavailable'})

    def test_snapshot_denied_and_commands_read_only(self):
        def denied(command, **kwargs):
            return subprocess.CompletedProcess(command, 1, '', 'Operation not permitted')
        with tempfile.TemporaryDirectory() as tmp:
            report = m.snapshot(tmp, denied)
        self.assertEqual(report['prefix']['state'], 'access_denied')
        self.assertFalse(report['system_swap_modified'])
        for command in m.COMMANDS.values():
            self.assertNotIn('-w', command)
            self.assertFalse(any('=' in part for part in command))

    def test_custom_prefix_name_is_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'testpages0').write_bytes(b'page')
            def run(command, **kwargs):
                value = tmp + '/testpages' if command == m.COMMANDS['prefix'] else 'boot'
                return subprocess.CompletedProcess(command, 0, value, '')
            result = m.snapshot(tmp, run)
            self.assertTrue(result['prefix_matches_target'])
            self.assertEqual(result['directory']['files'][0]['name'], 'testpages0')
