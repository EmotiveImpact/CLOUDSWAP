import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('r2_acceptance', Path(__file__).parents[1] / 'r2-acceptance.py')
LAB = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(LAB)


class R2AcceptanceTests(unittest.TestCase):
    def run_trial(self, results):
        env = {key: 'secret-do-not-log' for key in LAB.REQUIRED}
        report = LAB.readiness(env)
        calls = []
        def runner(args, **kwargs):
            calls.append(args[-1])
            value = next(results)
            if isinstance(value, Exception): raise value
            return value
        with tempfile.TemporaryDirectory() as temp:
            helper = Path(temp) / 'helper'; helper.write_text('synthetic test fixture'); helper.chmod(0o700)
            status = LAB.acceptance(helper, env, report, lambda: None, runner)
        self.assertNotIn('secret-do-not-log', json.dumps(report))
        return status, report, calls

    def test_missing_configuration_is_not_a_live_pass(self):
        report = LAB.readiness({})
        self.assertFalse(report['passed'])
        self.assertFalse(report['live_r2_tested'])
        self.assertEqual(report['missing_variables'], list(LAB.REQUIRED))
        self.assertEqual(LAB.acceptance('/absent', {}, report, lambda: None), 2)

    def test_whitespace_configuration_is_missing(self):
        self.assertFalse(LAB.readiness({key: '  ' for key in LAB.REQUIRED})['configured'])

    def test_both_verified_probes_required_and_credentials_redacted(self):
        results = iter(subprocess.CompletedProcess([], 0, marker, 'secret-do-not-log') for _, _, marker in LAB.PROBES)
        status, report, calls = self.run_trial(results)
        self.assertEqual(status, 0)
        self.assertTrue(report['passed'])
        self.assertEqual(calls, ['--live', '--pager-live'])
        self.assertTrue(all(p['cleanup_confirmed'] for p in report['probes']))
        self.assertFalse(report['cloud_system_swap_verified'])

    def test_success_exit_without_verification_is_failure(self):
        status, report, calls = self.run_trial(iter([subprocess.CompletedProcess([], 0, 'secret-do-not-log', '')]))
        self.assertEqual(status, 1)
        self.assertFalse(report['passed'])
        self.assertEqual(calls, ['--live'])

    def test_cleanup_failure_after_verification_is_failure(self):
        result = subprocess.CompletedProcess([], 1, LAB.PROBES[0][2], 'secret-do-not-log')
        status, report, _ = self.run_trial(iter([result]))
        self.assertEqual(status, 1)
        self.assertFalse(report['probes'][0]['cleanup_confirmed'])

    def test_timeout_is_not_cleanup_or_integrity_success(self):
        status, report, _ = self.run_trial(iter([subprocess.TimeoutExpired('secret-do-not-log', 120)]))
        self.assertEqual(status, 1)
        self.assertEqual(report['probes'][0]['failure'], 'timeout_cleanup_unconfirmed')


if __name__ == '__main__': unittest.main()
