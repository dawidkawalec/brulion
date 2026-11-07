#!/bin/bash
# Builds the llama-server helper of the local AI (Captylo/LocalAI, docs/local-ai.md) from the
# pinned llama.cpp commit and prints the binary's path on stdout (progress goes to stderr).
#
#   scripts/build-llama-server.sh          build when needed, print the path
#   scripts/build-llama-server.sh --path   only print where the binary lives (or would live)
#
# The pinned commit is LLAMA_CPP_COMMIT in project.yml (one place for the script and the
# "Embed llama-server" build phase). The build lives outside the repo in a shared cache, so
# worktrees and clean checkouts reuse it:
#   SZPAK_LLAMA_CACHE     cache root (default ~/Library/Caches/Szpak/llama.cpp);
#                         a different root also needs LLAMA_SERVER_PATH for xcodebuild
#   LLAMA_CPP_SOURCE      an existing llama.cpp checkout at the pinned commit to build from
#                         (default: a shallow clone of just that commit inside the cache)
#   LLAMA_BUILD_JOBS      parallel compile jobs (default: the performance cores)
#
# What the binary must be: arm64, static (no dylibs of ours), Metal with the shader library
# embedded, linking only system frameworks and /usr/lib, so it can be signed, notarized and
# shipped inside the app. Hence:
#   LLAMA_OPENSSL=OFF              the server talks plain HTTP on 127.0.0.1 only; with it on, a
#                                  Mac with Homebrew links /opt/homebrew/.../libssl, which cannot ship
#   LLAMA_SUBPROCESS=OFF           compiles out process spawning (the server's shell/file tools
#                                  and router mode), which the app never uses
#   LLAMA_USE_PREBUILT_UI=OFF      no web UI download from Hugging Face at build time (the app
#                                  runs it with --no-webui anyway); keeps the build hermetic
#   GGML_NATIVE=OFF + ARM arch     code for every Apple Silicon Mac, not only the build machine's
#                                  CPU (an M3 build with -mcpu=native could crash on an M1)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMIT="$(sed -n 's/^[[:space:]]*LLAMA_CPP_COMMIT:[[:space:]]*"\{0,1\}\([0-9a-f]\{40\}\)"\{0,1\}.*/\1/p' "$ROOT/project.yml" | head -n 1)"
[ -n "$COMMIT" ] || { echo "LLAMA_CPP_COMMIT not found in project.yml" >&2; exit 1; }
REPO_URL="https://github.com/ggml-org/llama.cpp.git"
CACHE_ROOT="${SZPAK_LLAMA_CACHE:-$HOME/Library/Caches/Szpak/llama.cpp}"
WORK="$CACHE_ROOT/$COMMIT"
BUILD="$WORK/build"
BIN="$BUILD/bin/llama-server"
STAMP="$WORK/build.stamp"

CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.4
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
  -DGGML_NATIVE=OFF
  -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16
  -DLLAMA_OPENSSL=OFF
  -DLLAMA_SUBPROCESS=OFF
  -DLLAMA_BUILD_UI=OFF
  -DLLAMA_USE_PREBUILT_UI=OFF
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF
  -DLLAMA_BUILD_TOOLS=ON
  -DLLAMA_BUILD_SERVER=ON
  -DLLAMA_BUILD_APP=OFF
)
CONFIG="$COMMIT $(printf '%s ' "${CMAKE_ARGS[@]}")"

if [ "${1:-}" = "--path" ]; then
  echo "$BIN"
  exit 0
fi
[ $# -eq 0 ] || { echo "usage: $0 [--path]" >&2; exit 2; }

# Every linked library has to come with macOS.
links_only_system() {
  local foreign
  foreign="$(otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/System/Library/|/usr/lib/)' || true)"
  if [ -n "$foreign" ]; then
    echo "llama-server links libraries that do not ship with macOS:" >&2
    echo "$foreign" >&2
    return 1
  fi
}

if [ -x "$BIN" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$CONFIG" ] && links_only_system "$BIN"; then
  echo "Reusing $BIN" >&2
  echo "$BIN"
  exit 0
fi

mkdir -p "$WORK"
if [ -n "${LLAMA_CPP_SOURCE:-}" ]; then
  SRC="$LLAMA_CPP_SOURCE"
else
  SRC="$WORK/src"
  if [ ! -d "$SRC/.git" ]; then
    echo "Fetching llama.cpp $COMMIT" >&2
    rm -rf "$SRC"
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$REPO_URL"
    git -C "$SRC" fetch -q --depth 1 origin "$COMMIT"
    git -C "$SRC" -c advice.detachedHead=false checkout -q FETCH_HEAD
  fi
fi

HEAD="$(git -C "$SRC" rev-parse HEAD)"
[ "$HEAD" = "$COMMIT" ] || { echo "$SRC is at $HEAD, expected $COMMIT" >&2; exit 1; }
[ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ] || { echo "$SRC has local changes" >&2; exit 1; }

JOBS="${LLAMA_BUILD_JOBS:-$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.ncpu)}"
echo "Building llama-server ($JOBS jobs) in $BUILD" >&2
rm -f "$STAMP"
# A clean build directory: a moved cache or other options would trip CMake's cache.
rm -rf "$BUILD"
cmake -S "$SRC" -B "$BUILD" "${CMAKE_ARGS[@]}" >&2
cmake --build "$BUILD" -j "$JOBS" --target llama-server >&2

links_only_system "$BIN"
lipo -archs "$BIN" | grep -qx arm64 || { echo "llama-server is not arm64 only" >&2; exit 1; }
echo "$CONFIG" > "$STAMP"
echo "$BIN"
