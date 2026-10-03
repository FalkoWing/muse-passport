import base64
import ctypes
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from audio_codec import AudioUpload, WAV, TAIL

ROOT = Path(__file__).resolve().parents[2]

class State(ctypes.Structure):
    _fields_ = [('pred', ctypes.c_int16), ('index', ctypes.c_int8)]

class AudioCodecTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        library = Path(cls.tmp.name) / 'adpcm.so'
        subprocess.run(['cc', '-shared', '-fPIC', '-I', str(ROOT/'esp32/components/muse'),
            str(ROOT/'esp32/components/muse/muse_adpcm.c'), '-o', str(library)], check=True,
            env={**os.environ, 'SDKROOT': os.environ.get('SDKROOT', '/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')})
        cls.lib = ctypes.CDLL(str(library))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_real_firmware_encoder_matches_python_preserves_duration(self):
        enc, dec = State(), State()
        upload = AudioUpload()
        expected = bytearray()
        wire = bytearray()
        chunks = []
        for seq in range(150):  # three seconds of normal speech-frequency PCM
            samples = (ctypes.c_int16*320)(*[round(8000*math.sin((seq*320+n)*2*math.pi*440/16000)) for n in range(320)])
            packed = (ctypes.c_uint8*160)()
            header = struct.pack('<hBHI', enc.pred, enc.index, 320, seq)
            self.lib.muse_adpcm_encode_block(ctypes.byref(enc), samples, 320, packed)
            decoded = (ctypes.c_int16*320)()
            self.lib.muse_adpcm_decode_block(ctypes.byref(dec), packed, 320, decoded)
            expected.extend(bytes(decoded))
            wire.extend(header + bytes(packed))
            if seq%4 == 3:
                chunks.append(upload.feed(wire));wire.clear()
        chunks.append(upload.feed(wire, end=True))
        encoded = b''.join(chunks)
        self.assertTrue(encoded.endswith(TAIL))
        wav = base64.b64decode(encoded[:-len(TAIL)], validate=True)
        self.assertEqual(wav, WAV + expected)
        self.assertEqual(upload.samples, 48000)
        self.assertEqual(len(wav)-44, 3*16000*2)
        self.assertLessEqual(len(upload.pending), 2)
        with self.assertRaises(ValueError):upload.feed(b'')

    def test_gap_bad_state_and_truncated_block_rejected(self):
        block = struct.pack('<hBHI', 0, 0, 320, 0)+bytes(160)
        cases = [block[:-1], block[:4], struct.pack('<hBHI',0,89,320,0)+bytes(160),
                 struct.pack('<hBHI',0,0,320,1)+bytes(160), struct.pack('<hBHI',0,0,321,0)+bytes(161)]
        for data in cases:
            with self.subTest(length=len(data)):
                with self.assertRaises(ValueError):AudioUpload().feed(data)
