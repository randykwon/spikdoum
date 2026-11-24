"""Local, approximate online speaker clustering. JSON lines over stdin/stdout."""
import base64
import json
import sys
import numpy as np
import sherpa_onnx


def emit(value):
    print(json.dumps(value), flush=True)


def main():
    config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=sys.argv[1], num_threads=2, provider="cpu")
    if not config.validate():
        raise RuntimeError("Invalid speaker embedding model")
    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
    profiles = []
    samples = np.zeros(0, dtype=np.float32)
    elapsed = 0.0
    segment = ""
    emit({"status": "ready"})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event["kind"] == "reset":
            segment = event["segment"]
            samples = np.zeros(0, dtype=np.float32)
            elapsed = 0.0
            continue
        audio = np.frombuffer(base64.b64decode(event["audio"]), dtype="<f4")
        rate = float(event.get("rate", 0))
        if len(audio) == 0 or rate <= 0:
            continue
        if rate != 16000:
            target_len = int(len(audio) * 16000 / rate)
            if target_len == 0:
                continue
            audio = np.interp(np.arange(target_len) * rate / 16000,
                              np.arange(len(audio)), audio).astype(np.float32)
        samples = np.concatenate((samples, audio))
        while len(samples) >= 32000:
            window, samples = samples[:32000], samples[32000:]
            start = elapsed
            elapsed += 2.0
            frames = window.reshape(-1, 320)
            active = np.sqrt(np.mean(frames * frames, axis=1)) > 0.008
            # Avoid assigning silence or a very short fragment to a new speaker.
            speaker = None
            confidence = 0.0
            if np.count_nonzero(active) >= 40:
                voiced = frames[active].reshape(-1)
                stream = extractor.create_stream()
                stream.accept_waveform(sample_rate=16000, waveform=voiced)
                stream.input_finished()
                if extractor.is_ready(stream):
                    embedding = np.asarray(extractor.compute(stream), dtype=np.float32)
                    embedding /= max(float(np.linalg.norm(embedding)), 1e-8)
                    similarities = [float(np.dot(p, embedding)) for p in profiles]
                    best = int(np.argmax(similarities)) if similarities else -1
                    if best >= 0 and similarities[best] >= 0.60:
                        speaker = best + 1
                        confidence = similarities[best]
                        if confidence >= 0.75:
                            profiles[best] = profiles[best] * 0.9 + embedding * 0.1
                            profiles[best] /= max(float(np.linalg.norm(profiles[best])), 1e-8)
                    elif len(profiles) < 6:
                        profiles.append(embedding)
                        speaker = len(profiles)
                        confidence = 0.0  # New cluster: identity is not yet confirmed.
            emit({"segment": segment, "start": start, "end": elapsed,
                  "speaker": speaker, "confidence": confidence})


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        emit({"error": str(error)})
        sys.exit(1)
