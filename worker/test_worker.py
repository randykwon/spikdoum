"""Integration smoke test with optional official speaker samples."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import wave
import numpy as np

root = Path(__file__).resolve().parents[1]
worker = [sys.executable, str(root / "worker/speaker_worker.py"), str(root / "Models/speaker.onnx")]
if len(sys.argv) > 1:
    worker = [sys.argv[1], str(root / "Models/speaker.onnx")]
packets = [json.dumps({"kind": "reset", "segment": "test"})]
for name in ("fangjun", "leijun", "fangjun"):
    with wave.open(str(root / ".worker-test" / (name + ".wav")), "rb") as audio:
        assert audio.getsampwidth() == 2
        samples = np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(np.float32) / 32768
        samples = samples.reshape(-1, audio.getnchannels()).mean(axis=1)
        rate = audio.getframerate()
        count = rate * 2
        assert len(samples) >= count
        samples = samples[:count]
        packets.append(json.dumps({"kind": "audio", "rate": rate, "audio": base64.b64encode(samples.astype("<f4").tobytes()).decode()}))
result = subprocess.run(worker, input="\n".join(packets) + "\n", capture_output=True, text=True, timeout=90)
assert result.returncode == 0, result.stderr + result.stdout
lines = [json.loads(line) for line in result.stdout.splitlines()]
assert lines[0].get("status") == "ready", lines
intervals = [line for line in lines if "speaker" in line]
assert len(intervals) == 3, lines
labels = [line["speaker"] for line in intervals]
print("Speaker predictions (one window each, A / B / A):", labels)
assert labels[0] is not None and labels[1] is not None, labels
assert labels[0] != labels[1], labels
assert labels[2] == labels[0], labels
print("PASS: real speaker samples separated and returning speaker matched")
