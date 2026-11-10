import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('survey', Path(__file__).resolve().parents[1] / 'verify-mac-candidates.py')
survey = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(survey)

class ResearchManifestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.path = 'research/mac-candidates/sources/example--source'
        self.sha = 'a' * 40
        subprocess.run(['git', 'update-index', '--add', '--cacheinfo', '160000,' + self.sha + ',' + self.path], cwd=self.root, check=True)
        (self.root / '.gitmodules').write_text('[submodule "' + self.path + '"]\npath = ' + self.path + '\nurl = https://github.com/example/source.git\n')
        self.manifest = self.root / 'research/mac-candidates/manifest.json'
        self.manifest.parent.mkdir(parents=True)
        self.record = dict(repository='example/source', path=self.path, commit=self.sha, url='https://github.com/example/source.git', root_documents=[])
        self.save()

    def save(self):
        self.manifest.write_text(json.dumps({'repositories': [self.record]}))

    def test_uninitialised_source_is_valid(self):
        self.assertEqual(survey.verify(self.root), (1, 0))

    def test_changed_pin_is_rejected(self):
        self.record['commit'] = 'b' * 40
        self.save()
        with self.assertRaisesRegex(ValueError, 'Gitlink mismatch'):
            survey.verify(self.root)

    def test_changed_remote_is_rejected(self):
        p = self.root / '.gitmodules'
        p.write_text(p.read_text().replace('example/source.git', 'other/source.git'))
        with self.assertRaisesRegex(ValueError, 'URL/path mismatch'):
            survey.verify(self.root)

    def test_unregistered_gitlink_is_rejected(self):
        subprocess.run(['git', 'update-index', '--add', '--cacheinfo', '160000,' + self.sha + ',research/mac-candidates/sources/unknown'], cwd=self.root, check=True)
        with self.assertRaisesRegex(ValueError, 'Unregistered'):
            survey.verify(self.root)
