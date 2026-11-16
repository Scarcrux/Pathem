"""Generate silent owned AAC data; never copy a document from the owner's library."""
from pathlib import Path
import subprocess
import wave


def prepare(directory):
    directory = Path(directory)
    wav = directory / 'owned-silence.wav'
    output = directory / 'owned-silence.m4a'
    with wave.open(str(wav), 'wb') as stream:
        stream.setnchannels(1)
        stream.setsampwidth(2)
        stream.setframerate(44100)
        stream.writeframes(b'\0\0' * (44100 * 4))
    subprocess.run(['/usr/bin/afconvert', '-f', 'm4af', '-d', 'aac', str(wav), str(output)],
                   check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    wav.unlink()
    data = output.read_bytes()
    if len(data) < 32 or data[4:8] != b'ftyp':
        raise ValueError('owned media conversion did not produce MPEG-4')
    return output
