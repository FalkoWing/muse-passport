"""Passport IMA ADPCM framing and streaming WAV/base64, Apache-2.0.

State is explicit on every block; sequence gaps reject the turn. Sample rate
and duration are preserved. Only BLE is compressed; Muse receives PCM WAV.
"""
import base64
import struct

STEPS = (7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767)
INDEX = (-1,-1,-1,-1,2,4,6,8)
HEAD = b'{"message":"","output_modality":"text","items":[{"type":"file","mime_type":"audio/wav","filename":"voice_note.wav","data_base64":"'
TAIL = b'"}]}'
WAV = struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', 0xffffffff, b'WAVE', b'fmt ', 16, 1, 1, 16000, 32000, 2, 16, b'data', 0xffffffff)


class AudioUpload:
    def __init__(self):
        self.pending = bytearray(WAV)
        self.sequence = 0
        self.samples = 0
        self.ended = False

    def feed(self, data, end=False):
        if self.ended:
            raise ValueError('Audio already ended')
        pos = 0
        pcm = bytearray()
        while pos < len(data):
            if len(data) - pos < 9:
                raise ValueError('Short audio header')
            pred, index, count, sequence = struct.unpack_from('<hBHI', data, pos)
            pos += 9
            if index > 88 or count == 0 or count > 320 or count % 2 or sequence != self.sequence or len(data)-pos < count//2:
                raise ValueError('Invalid audio block or missing samples')
            self.sequence += 1
            self.samples += count
            for packed in data[pos:pos+count//2]:
                for code in (packed & 15, packed >> 4):
                    step = STEPS[index]
                    diff = (step >> 3) + (step if code & 4 else 0) + (step >> 1 if code & 2 else 0) + (step >> 2 if code & 1 else 0)
                    pred = max(-32768, min(32767, pred + (-diff if code & 8 else diff)))
                    index = max(0, min(88, index + INDEX[code & 7]))
                    pcm.extend(struct.pack('<h', pred))
            pos += count//2
        self.pending.extend(pcm)
        size = len(self.pending) if end else len(self.pending)//3*3
        result = base64.b64encode(self.pending[:size])
        del self.pending[:size]
        if end:
            self.ended = True
            result += TAIL
        return result
