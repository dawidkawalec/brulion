# Local AI (`Captylo/LocalAI/`)

All AI runs on Bielik models on the user's Mac, through llama.cpp's `llama-server` bundled as a helper and listening on 127.0.0.1 only (PRD sections 5-7). The module is self-contained: it knows nothing about the app's settings, paths, AI routes or UI. The app hands it paths and settings and asks it for an endpoint per role; everything else (prompts, request bodies, parsing) stays in the app's OpenAI-compatible client.

## Pieces

| Type | What it does |
|---|---|
| `LocalRole` | `correction` (dictation cleanup, transcript fixes, note titles) and `features` (AI modes, custom prompts, meeting notes, "Zapytaj", style profile) |
| `LocalModelSpec`, `LocalModelCatalog` | the three Bielik GGUF files (repo, pinned revision, file, bytes, SHA-256, context, licence), download URL, allowed download hosts |
| `LocalAITuning` | every number F0 measures, in one place (see "Pending numbers") |
| `HardwareProfile`, `HardwareTier`, `LocalAIPlan`, `LocalAIRequirements` | memory -> tier -> default role/model plan, memory warning per model, memory budget of the servers, onboarding text (RAM, disk) |
| `LocalModelDownloader` (actor) | download into `<models>/<file>.part` with HTTP Range resume (also across launches), progress, cancel, streamed SHA-256, atomic rename, delete, free-space check |
| `LocalAIModelStore` (`@MainActor @Observable`) | per-model state for Modele and the onboarding: `notInstalled`, `downloading(progress)`, `verifying`, `installed`, `failed(message)`; partial bytes for "Wznów" |
| `LlamaServer` (actor) | one llama-server process per model file: port, token, health wait, crash detection, idle stop, cooldown, pid file |
| `LocalAIService` (actor) | role -> model -> server; two roles on one model share one process; memory budget (least recently used stops first); `endpoint(for:timeout:)` |
| `CorrectionGuard` | rejects a correction outside 50-150 % of the input length (inputs over 40 characters) or under the word similarity threshold; returns a reason |
| `LocalDeadline` | `limit = base + input words x seconds per word x 1.5`, capped at 15 s (cleanup) and 30 s (modes) |
| `LocalUsageStats` (actor) | local counters (no network): dictations, corrections accepted / rejected by the guard (with reasons), timeouts, average and p95 correction time, mode uses, meetings, server failures; JSON at an injected URL; export to a file the user picks (`captylo.localai.usage.v1`) |
| `LocalAI.xcstrings` | the module's own string table (`table: "LocalAI"`), Polish source with English |

Logging goes through `LocalAILog` (category `localai`): states, model ids, sizes, ports, pids and exit codes only. Never a prompt, a model answer, the server's output or the token.

## Process lifecycle

1. **Start on demand.** `LocalAIService.endpoint(for:timeout:)` (or `prewarm`, e.g. when the dictation hotkey goes down) creates the role's `LlamaServer` and starts it. Concurrent callers join the same start. A caller that times out gets nil (the app pastes the raw text) while the start goes on for the next request.
2. **Launch.** A free port on 127.0.0.1 (bind to port 0, read it back), a random token (32 bytes, hex), the helper started with a clean environment (only `HOME`, `TMPDIR`, `USER`, `LOGNAME`, a fixed `PATH` and `LLAMA_API_KEY`). The token goes through `LLAMA_API_KEY`, the documented variable of `--api-key`, so it never shows in `ps`. The process output is drained into a 16 KB in-memory tail used only to classify a failure (port taken, out of memory, model load) and never logged.
3. **Ready.** `GET /health` every 200 ms until 200, for at most 60 s (`LocalAITuning.startTimeout`). A port taken in the meantime ("couldn't bind HTTP server socket") is retried with a new port, up to 3 times. The endpoint is `http://127.0.0.1:<port>/v1/` with `Authorization: Bearer <token>` and `model: <model id>` (the server runs with `--alias <model id>`).
4. **Crash.** An exit while running marks the server failed, calls `onUnexpectedExit` and the next request starts it again. Three failed starts or crashes within 2 minutes make the next start fail at once (`coolingDown`) until the window passes.
5. **Idle stop.** After `idleTimeout` (default 10 min, `Options.idleTimeout`, nil = never) without a request the server stops and frees its memory. Requests run through `withEndpoint` are never cut by the idle stop. As a second line of defence for a server orphaned by a crashed app, llama-server itself sleeps (frees the model) 2 minutes after the app's idle time (`--sleep-idle-seconds`).
6. **Memory budget.** Before a server starts, the least recently used other servers stop until the sum of the approximate peak memory fits `Options.memoryBudgetBytes` (`HardwareProfile.memoryBudgetBytes`). On 8 GB that is one server at a time. Starts are admitted one at a time so two never fit into the same free memory.
7. **Stop.** SIGTERM, SIGKILL after 3 s. `shutdown()` stops all and waits; `terminateAllNow()` (nonisolated, for `applicationWillTerminate`) sends SIGTERM to every process at once.
8. **Stale servers.** Each running server has `<runDirectory>/<model id>.pid` (pid and executable path). `LocalAIService.init` and every start kill a process left by a crashed run, but only while that pid still runs the recorded executable (pids get reused; other llama-server binaries on the Mac, e.g. a benchmark, are never touched).

## llama-server flags

`--model <gguf> --alias <model id> --host 127.0.0.1 --port <free port> --ctx-size <context> --n-gpu-layers 99 --parallel 1 --jinja --flash-attn auto --cache-ram 512 --no-webui --no-slots --offline --log-verbosity 2 --log-colors off [--sleep-idle-seconds <idle + 120>]`, token in `LLAMA_API_KEY`.

- `--parallel 1`: one request at a time per model; every slot would take its own share of the context.
- `--ctx-size`: the largest context of the roles that share the model (`LocalAITuning.correctionContext` / `featuresContext`).
- `--cache-ram 512`: the prompt cache in RAM; the default (8 GiB) would make memory use unpredictable on small Macs.
- `--no-slots`: `/slots` would expose the cached prompts. `--no-webui`: no web UI. `--offline`: no downloads.
- `--log-verbosity 2`: errors and warnings only. Request and response bodies are logged only at debug level (5), and the output is never written anywhere anyway.
- Not used on purpose: `--metrics`, `--props`, `--tools`, `--log-file`, `--log-prompts-dir`, `--slot-save-path`, `--api-key` on the command line.
- The clean environment matters: llama-server reads `LLAMA_ARG_*` (e.g. `LLAMA_ARG_TOOLS`, `LLAMA_ARG_HOST`) and `HF_*` from its environment.

## Building the helper

`make llama` runs `scripts/build-llama-server.sh`: the commit is `LLAMA_CPP_COMMIT` in `project.yml` (llama.cpp v0.9.0, `cd959bae99ff4bed22bef2604f45241c09bbb8c8`), a shallow clone of that one commit (or an existing checkout at that commit via `LLAMA_CPP_SOURCE`), built into `~/Library/Caches/CaptyloBielik/llama.cpp/<commit>/build/bin/llama-server` (`CAPTYLO_LLAMA_CACHE` overrides the root). A finished build with the same options is reused. CMake options on top of Release, static, arm64, macOS 14.4:

| Option | Why |
|---|---|
| `GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON` | GPU inference, the shader library inside the binary |
| `LLAMA_OPENSSL=OFF` | the server speaks plain HTTP on loopback; with it on, a Mac with Homebrew links `/opt/homebrew/.../libssl`, which cannot ship |
| `LLAMA_SUBPROCESS=OFF` | compiles out process spawning (the server's shell and file tools, router mode) |
| `LLAMA_BUILD_UI=OFF`, `LLAMA_USE_PREBUILT_UI=OFF` | no web UI, and no download of it from Hugging Face at build time |
| `GGML_NATIVE=OFF`, `GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16` | CPU code for every Apple Silicon Mac, not only the build machine's (an M3 `-mcpu=native` build could crash on an M1) |
| `LLAMA_BUILD_TESTS/EXAMPLES/APP=OFF` | only the `llama-server` target is built |

The result links only system libraries (`otool -L`): Accelerate, Foundation, Metal, MetalKit, CoreFoundation, `libSystem`, `libc++`, `libobjc`. About 20 MB.

The "Embed llama-server" build phase (`project.yml`, target Captylo) copies `LLAMA_SERVER_PATH` into `Captylo.app/Contents/MacOS/llama-server` and signs it (ad-hoc in Xcode builds). A Debug build without the helper only warns (the app then has no local AI); a Release build fails. The phase reads a file outside the source tree that may be missing, so the target has user script sandboxing off. `scripts/sign-app.sh` signs every helper in `Contents/MacOS` inside-out with the app's identity and hardened runtime (no entitlements), before the app. Debug builds can also point at a helper with `CAPTYLO_LLAMA_SERVER` (`LlamaServerLocator`).

## Hosts contacted

For the privacy screen ("Prywatność", PRD 7.6): the local AI contacts the network only while a model downloads, and only `huggingface.co` and the CDN it redirects to (subdomains of `huggingface.co` and `hf.co`, e.g. `cdn-lfs.hf.co`, `cas-bridge.xethub.hf.co`), over HTTPS, without an account, cookies or a token. The downloader refuses any redirect elsewhere or to plain HTTP (`LocalModelCatalog.downloadHostSuffixes`). Inference only talks to 127.0.0.1. The optional cloud Bielik (CloudFerro Sherlock, PRD 7.5) lives outside this module.

## Requirements per tier

| Tier | Mac | Correction | AI features | Download | Free disk needed | Server memory budget |
|---|---|---|---|---|---|---|
| standard | 16 GB RAM and more | Bielik 1.5B Q8_0 | Bielik Minitron 7B Q4_K_M | 6.2 GB | 7.2 GB | 60 % of RAM (placeholder) |
| experimental | under 16 GB | Bielik 1.5B Q8_0 | Bielik 1.5B (or the cloud Bielik when the user set it up) | 1.7 GB | 2.7 GB | 45 % of RAM (placeholder), one server at a time |

Peak memory per model is a placeholder (file size x 1.3) until F0 sends the measurements: 1.5B about 2.2 GB, Minitron about 5.9 GB, 4.5B about 6.6 GB. On the experimental tier a model over 35 % of the RAM (Minitron, 4.5B) is allowed with a memory warning (`HardwareProfile.needsMemoryWarning`).

## Pending numbers

All in `LocalAITuning`; the values below are placeholders:

| Constant | Placeholder | Measured in F0 |
|---|---|---|
| `correctionContext`, `featuresContext` | 8192, 16384 | context lengths that fit and stay fast |
| `measuredPeakRAM` (per model id), `ramFactor` | empty, 1.3 | peak RSS of llama-server per model at its context |
| `standardMemoryBudgetFraction`, `experimentalMemoryBudgetFraction`, `memoryWarningFraction` | 0.6, 0.45, 0.35 | follow from the peak memory |
| `cleanupBaseSeconds`, `modeBaseSeconds` | 1.5, 4.0 | fixed part of the deadline |
| `correctionSecondsPerWord`, `featuresSecondsPerWord` | 0.02, 0.02 | generation time per input word |
| `guardMinimumSimilarity` | 0.5 | word similarity threshold of the guard |

## Integration points (for the app)

1. **Paths** (from the app's data folder): `modelsDirectory` for `LocalAIModelStore` / `LocalModelDownloader` / `LocalAIService` (e.g. `<data>/LocalModels`), `runDirectory` for the pid files (e.g. `<data>/LocalAI`), the usage stats file (e.g. `<data>/local-ai-usage.json`).
2. **Plan and settings**: `HardwareProfile.current.plan(cloudFeaturesAvailable:)` gives the defaults; the user's model choice per role in Modele becomes `LocalAIService.setRoleModels`; the idle time in Ustawienia and `HardwareProfile.memoryBudgetBytes` become `LocalAIService.setOptions`.
3. **AIRole mapping**: the app's roles map onto `LocalRole` (cleanup, transcript fixes, note titles -> `correction`; modes, custom prompts, "Przetwórz przez AI", meeting notes, "Zapytaj", `StyleDistiller` -> `features`). A role assigned to `.cloud` never reaches this module.
4. **Requests**: the OpenAI-compatible client posts to `endpoint.chatCompletionsURL` with `endpoint.authorizationHeader` and `model: endpoint.modelID`; dictation waits at most `LocalDeadline.limit(for:input:)` and checks cleanup answers with `CorrectionGuard.check` (raw text on rejection, timeout or nil endpoint).
5. **Lifecycle hooks**: `prewarm(.correction)` on hotkey down; `LocalAIModelStore.willDelete` -> `LocalAIService.stop(modelID:)`; `applicationWillTerminate` -> `terminateAllNow()`; `onUnexpectedExit` and timeouts -> `LocalUsageStats.record`.
6. **Usage counter**: record `.dictation`, `.correctionAccepted/Rejected`, `.timeout`, `.modeUsed`, `.meetingProcessed`, `.serverFailure`; show `counters`; "Eksportuj" -> `export(to:)` with an `NSSavePanel` URL.
7. **Onboarding and privacy**: `LocalAIRequirements.title()` / `summary()`, `LocalAIModelStore.spaceNeeded(for:)` with `DiskSpace.availableBytes`, the hosts above.
8. **Release**: `make llama` before `make release` / `make dist`; the notarization covers the helper because `scripts/sign-app.sh` signs it.

## Tests

`CaptyloTests/LocalAI*Tests.swift` (Swift Testing): catalog integrity, tiers and plans, downloader through a `URLProtocol` stub (fresh download, Range resume, a server that ignores Range, SHA mismatch removes the `.part`, cancel keeps it, no disk space, redirect to the CDN keeps the Range, redirect elsewhere refused, HTTP errors), the store, the guard (synthetic Polish sentences), the deadline, server arguments and environment, the server lifecycle and the service with a fake process launcher (shared process, port retry, crash, idle stop, cooldown, timeout, memory budget), pid files against a real `/bin/sleep`, usage stats round trip and export.

`LocalAIEndToEndTests` runs the real helper and a real model, off in `make test`:

```bash
lockf -k <shared heavy-work lock> env \
  TEST_RUNNER_CAPTYLO_LLAMA_E2E=1 \
  TEST_RUNNER_CAPTYLO_LLAMA_SERVER="$(scripts/build-llama-server.sh --path)" \
  TEST_RUNNER_CAPTYLO_LLAMA_MODEL=<path to Bielik-1.5B-v3.0-Instruct.Q8_0.gguf> \
  xcodebuild -project Captylo.xcodeproj -scheme Captylo -derivedDataPath .local-build \
  CODE_SIGN_IDENTITY="-" test -only-testing:CaptyloTests/LocalAIEndToEndTests
```

xcodebuild passes environment variables prefixed with `TEST_RUNNER_` to the tests without the prefix. The model file is only read where it is.
