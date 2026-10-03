import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class SDKTokenStoreTests(unittest.TestCase):
    def test_persistence_and_failure_contract(self):
        with tempfile.TemporaryDirectory() as temp:
            binary = str(Path(temp) / 'sdk-token-store')
            subprocess.run([*shlex.split(os.environ.get('CC', 'cc')), '-std=c11', '-Wall', '-Wextra', '-Werror',
                            '-I', str(ROOT / 'main'), str(ROOT / 'main/sdk_token_store.c'),
                            str(ROOT / 'tests/sdk_token_store_harness.c'), '-o', binary], check=True)
            subprocess.run([binary], check=True)
