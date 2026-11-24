# Speaker analysis components

The app includes a local speaker-embedding worker built using sherpa-onnx (Apache-2.0), NumPy (BSD-3-Clause), and the PyInstaller bootloader (GPL with the PyInstaller bootloader distribution exception). Bundled dependencies carry their own license notices in the worker distribution.

- sherpa-onnx: https://github.com/k2-fsa/sherpa-onnx
- Speaker embedding model: 3D-Speaker CAMPPlus, https://github.com/modelscope/3D-Speaker
- Model distribution: https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models
- PyInstaller: https://pyinstaller.org/en/stable/license.html

Speaker labels are anonymous estimates scoped to one listening session. They do not identify a person. Classification uses 2-second windows; overlapping voices and short turns are not reliably separated.
