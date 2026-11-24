#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
if [[ ! -x .speaker-venv/bin/python ]]; then python3 -m venv .speaker-venv; fi
.speaker-venv/bin/python -m pip install -r worker/requirements.txt
mkdir -p Models
if [[ ! -f Models/speaker.onnx ]]; then
    curl -L --fail --retry 2 -o Models/speaker.onnx.download https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx
    mv Models/speaker.onnx.download Models/speaker.onnx
fi
.speaker-venv/bin/pyinstaller --noconfirm --onedir --name SpeakerWorker --distpath .worker-build --workpath .worker-tmp --specpath .worker-tmp --collect-all sherpa_onnx worker/speaker_worker.py
