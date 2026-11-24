# Managed local inference runtime

SpikDoum bundles the arm64 Metal-enabled server executables built from:

- whisper.cpp v1.9.5, commit d1be6fde11ac6e0407606b4e42fe72d34add8037, MIT: https://github.com/ggml-org/whisper.cpp
- llama.cpp v1.0.0, commit b1b770d90d94cad9e9ea5b993bdbc383a522fb28, MIT: https://github.com/ggml-org/llama.cpp

The corresponding LICENSE files are distributed beside these executables. whisper.cpp's server includes a SpikDoum patch that enforces a per-process bearer token (except health checks) and limits upload size to 32 MB. Both servers include a parent-lifetime guard that exits when their owning app process disappears. Servers bind only to 127.0.0.1. llama.cpp uses its built-in API key support. No third-party executable installation is required at runtime.

Models are downloaded separately from immutable Hugging Face revisions and validated by byte count and SHA-256. Download sources and model cards are linked in the model manager. Whisper weights originate from OpenAI Whisper (MIT); the Qwen2.5-1.5B-Instruct weights are Apache-2.0. Model files are stored in Application Support/SpikDoum/ManagedModels and are not included in the DMG.
