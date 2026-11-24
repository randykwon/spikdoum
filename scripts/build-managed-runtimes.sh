#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .runtime-src .runtime-build/bin
fetch_source() {
    local project="$1" tag="$2" revision="$3" folder="$4"
    if [[ ! -d "$folder/.git" ]]; then git clone --depth 1 --branch "$tag" "https://github.com/ggml-org/$project.git" "$folder"; fi
    [[ "$(git -C "$folder" rev-parse HEAD)" == "$revision" ]] || { print -u2 "Unexpected runtime source revision: $folder"; exit 1; }
}
fetch_source whisper.cpp v1.9.5 d1be6fde11ac6e0407606b4e42fe72d34add8037 .runtime-src/whisper
fetch_source llama.cpp v1.0.0 b1b770d90d94cad9e9ea5b993bdbc383a522fb28 .runtime-src/llama
# Require an app-owned bearer token before accepting uploads/model-load requests.
python3 - <<'PATCH'
from pathlib import Path
p = Path('.runtime-src/whisper/examples/server/server.cpp')
s = p.read_text()
marker = '// SpikDoum loopback authorization'
if marker not in s and '// SpeakHelper loopback authorization' not in s:
    target = '    svr->set_default_headers('
    i = s.index(target)
    patch = '''    // SpikDoum loopback authorization
    const char * raw_key = std::getenv("SPIKDOUM_API_KEY") ? std::getenv("SPIKDOUM_API_KEY") : std::getenv("SPEAKHELPER_API_KEY");
    const std::string spikdoum_key = raw_key ? raw_key : "";
    svr->set_payload_max_length(32 * 1024 * 1024);
    svr->set_pre_routing_handler([spikdoum_key](const Request & req, Response & res) {
        if (req.path == "/health") return httplib::Server::HandlerResponse::Unhandled;
        if (!spikdoum_key.empty() && req.get_header_value("Authorization") != "Bearer " + spikdoum_key) {
            res.status = 401;
            res.set_content(R"({"error":"unauthorized"})", "application/json");
            return httplib::Server::HandlerResponse::Handled;
        }
        return httplib::Server::HandlerResponse::Unhandled;
    });
'''
    p.write_text(s[:i] + patch + s[i:])
PATCH
# Stop owned servers if their app process exits unexpectedly.
python3 - <<'PATCH'
from pathlib import Path
for name in ['.runtime-src/whisper/examples/server/server.cpp', '.runtime-src/llama/tools/server/main.cpp']:
    p = Path(name)
    s = p.read_text()
    marker = '// SpikDoum parent lifetime'
    if marker not in s and '// SpeakHelper parent lifetime' not in s:
        s = '#include <unistd.h>\n#include <cstdlib>\n#include <thread>\n#include <chrono>\n' + s
        target = 'int main(int argc, char ** argv) {'
        guard = '''
    // SpikDoum parent lifetime
    const char * value = std::getenv("SPIKDOUM_PARENT_PID") ? std::getenv("SPIKDOUM_PARENT_PID") : std::getenv("SPEAKHELPER_PARENT_PID");
    if (value) {
        const int parent = std::atoi(value);
        std::thread([parent]() {
            while (getppid() == parent) std::this_thread::sleep_for(std::chrono::seconds(1));
            std::_Exit(0);
        }).detach();
    }
'''
        assert target in s
        p.write_text(s.replace(target, target + guard, 1))
PATCH
common=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
cmake -S .runtime-src/whisper -B .runtime-build/whisper $common -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=ON -DWHISPER_CURL=OFF
cmake --build .runtime-build/whisper --config Release --target whisper-server -j 4
cmake -S .runtime-src/llama -B .runtime-build/llama $common -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_OPENSSL=OFF
cmake --build .runtime-build/llama --config Release --target llama-server -j 4
cp .runtime-build/whisper/bin/whisper-server .runtime-build/bin/whisper-server.new
mv -f .runtime-build/bin/whisper-server.new .runtime-build/bin/whisper-server
cp .runtime-build/llama/bin/llama-server .runtime-build/bin/llama-server.new
mv -f .runtime-build/bin/llama-server.new .runtime-build/bin/llama-server
cp .runtime-src/whisper/LICENSE .runtime-build/bin/whisper-LICENSE
cp .runtime-src/llama/LICENSE .runtime-build/bin/llama-LICENSE
python3 - <<'LICENSES'
from pathlib import Path
root = Path('.runtime-build/bin')
parts = []
for source in [Path('.runtime-src/whisper'), Path('.runtime-src/llama')]:
    for p in sorted(source.rglob('*')):
        if p.is_file() and p.name.upper() in ['LICENSE', 'LICENSE.TXT', 'LICENSE.MD', 'COPYING', 'COPYING.TXT', 'NOTICE'] and '.git' not in p.parts:
            parts.append(str(p.relative_to(source.parent)) + '\n' + p.read_text(errors='replace'))
(root/'THIRD_PARTY_LICENSES.txt').write_text('\n\n'.join(parts))
LICENSES
