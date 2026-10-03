"""Passport regressions: release edges, ADC rollback and real font coverage."""
import os
import re
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class PassportTests(unittest.TestCase):
    def test_audio_stereo_reopen_and_fault_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "passport_audio"
            result = subprocess.run([
                *shlex.split(os.environ.get("CC", "cc")), "-std=c11",
                "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
                "-I", str(ROOT / "tests/passport_audio_stubs"),
                "-I", str(ROOT / "components/passport_bsp/include"),
                str(ROOT / "tests/passport_audio_harness.c"),
                str(ROOT / "components/passport_bsp/src/bsp_es8311_sleep_check.c"),
                "-o", str(binary)
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_adc_keys_and_release_with_fault_injection(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "passport_buttons"
            result = subprocess.run([
                *shlex.split(os.environ.get("CC", "cc")), "-std=c11",
                "-Wall", "-Wextra", "-Werror",
                "-I", str(ROOT / "tests/passport_stubs"),
                "-I", str(ROOT / "components/passport_bsp/include"),
                str(ROOT / "tests/passport_button_harness.c"), "-o", str(binary)
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_font_covers_gb2312_and_requested_symbols(self):
        fonts = ROOT / "components/muse/fonts"
        source = (fonts / "passport_font_16.c").read_text()
        glyphs = {int(cp, 16) for cp in re.findall(r'/\* U\+([0-9A-F]+) ', source)}
        wanted = {ord(c) for c in (fonts / "passport_font_symbols.txt").read_text()}
        self.assertFalse(wanted - glyphs, sorted(wanted - glyphs))
        chinese = set()
        for codepoint in range(0x4E00, 0xA000):
            try:
                chr(codepoint).encode("gb2312")
                chinese.add(codepoint)
            except UnicodeEncodeError:
                pass
        self.assertEqual(len(chinese), 6763)
        self.assertFalse(chinese - glyphs)
        # The compiled bitmap font has one descriptor per requested glyph,
        # plus the reserved missing-glyph descriptor.
        self.assertEqual(len(re.findall(r'\{\.bitmap_index =', source)), len(wanted) + 1)

    def test_font_covers_standard_big5_traditional_chinese(self):
        source = (ROOT / "components/muse/fonts/passport_font_16.c").read_text()
        glyphs = {int(cp, 16) for cp in re.findall(r'/\* U\+([0-9A-F]+) ', source)}
        wanted = set()
        for cp in range(0x4E00,0xA000):
            try:
                chr(cp).encode("big5")
                wanted.add(cp)
            except UnicodeEncodeError:
                pass
        self.assertEqual(len(wanted),13061)
        self.assertFalse(wanted - glyphs, sorted(wanted - glyphs))
        self.assertFalse({ord(c) for c in "繁體中文語音轉錄測試螢幕設定開關藍牙網路斷線"} - glyphs)
