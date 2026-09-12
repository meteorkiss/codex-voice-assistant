"""Combine existing self-authored speech fixtures. No microphone or cloud access."""
from pathlib import Path
import struct
import wave

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/tests/echo-preroll"
OUT.mkdir(parents=True, exist_ok=True)

def pcm(path):
    with wave.open(str(path), "rb") as source:
        assert (source.getframerate(), source.getnchannels(), source.getsampwidth()) == (16000, 1, 2)
        return source.readframes(source.getnframes())

wake = pcm(ROOT / "tests/fixtures/wake/positive-taiwan-chen.wav")
question = pcm(ROOT / "tests/fixtures/voice-taiwan.wav")
values = struct.unpack("<" + "h" * (len(wake)//2), wake)
last = max(i for i, value in enumerate(values) if abs(value) > 200)
wake = wake[:min(len(wake), (last+1280)*2)]
values = struct.unpack("<" + "h" * (len(question)//2), question)
first = next(i for i, value in enumerate(values) if abs(value) > 200)
question = question[max(0, first-640)*2:]
for name, data in [("combined.wav", wake+question), ("question.wav", question)]:
    with wave.open(str(OUT/name), "wb") as target:
        target.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        target.writeframes(data)
print(f"Self-authored fixtures prepared: wake={len(wake)/32000:.2f}s question={len(question)/32000:.2f}s")
