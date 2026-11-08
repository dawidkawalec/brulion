# Local AI (`Captylo/LocalAI/`)

In Szpak all AI runs on Bielik models on the user's Mac, through llama.cpp's `llama-server` bundled as a helper and listening on 127.0.0.1 only (PRD sections 5-7). The module is self-contained: it knows nothing about the app's settings, paths, AI routes or UI. The app hands it paths and settings and asks it for an endpoint per role; everything else (prompts, request bodies, parsing) stays in the app's OpenAI-compatible client.

## Pieces

| Type | What it does |
|---|---|
| `LocalRole` | `correction` (dictation cleanup, transcript fixes, note titles) and `features` (AI modes, custom prompts, meeting notes, "Zapytaj", style profile) |
| `LocalModelSpec`, `LocalModelCatalog` | the three Bielik GGUF files (repo, pinned revision, file, bytes, SHA-256, context, licence), download URL, allowed download hosts |
| `LocalAITuning` | every number F0 measured, in one place (see "Measured numbers") |
| `HardwareProfile`, `HardwareTier`, `LocalAIPlan`, `LocalAIRequirements` | memory -> tier -> default role/model plan, memory warning per model, memory budget of the servers, onboarding text (RAM, disk) |
| `LocalModelDownloader` (actor) | download into `<models>/<file>.part` with HTTP Range resume (also across launches), progress, cancel, streamed SHA-256, atomic rename, delete, free-space check |
| `LocalAIModelStore` (`@MainActor @Observable`) | per-model state for Modele and the onboarding: `notInstalled`, `downloading(progress)`, `verifying`, `installed`, `failed(message)`; partial bytes for "Wznów" |
| `LlamaServer` (actor) | one llama-server process per model file: port, token, health wait, crash detection, idle stop, cooldown, pid file |
| `LocalAIService` (actor) | role -> model -> server; two roles on one model share one process; memory budget (least recently used stops first); `endpoint(for:timeout:)` |
| `CorrectionMerger` | keeps only the model's safe word edits in the raw dictation (see "Correction merge") |
| `CorrectionGuard` | `apply(raw:output:vocabulary:spellCheck:)`, the one entry point for a cleanup answer: merge, then reject the merged text outside 50-150 % of the input length (inputs over 40 characters) or under 0.5 word similarity; returns the text to paste and a reason |
| `CorrectionSpelling` | the merger's spell check from the system dictionaries (Polish, English), asked on the main actor once per answer |
| `LocalDeadline` | `limit = base + input words x seconds per word x 1.5`, capped at 15 s (cleanup) and 30 s (modes) |
| `LocalUsageStats` (actor) | local counters (no network): dictations, corrections accepted / rejected by the guard (with reasons), timeouts, average and p95 correction time, mode uses, meetings, server failures; JSON at an injected URL; export to a file the user picks (`szpak.localai.usage.v1`) |
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

`make llama` runs `scripts/build-llama-server.sh`: the commit is `LLAMA_CPP_COMMIT` in `project.yml` (llama.cpp v0.9.0, `cd959bae99ff4bed22bef2604f45241c09bbb8c8`), a shallow clone of that one commit (or an existing checkout at that commit via `LLAMA_CPP_SOURCE`), built into `~/Library/Caches/Szpak/llama.cpp/<commit>/build/bin/llama-server` (`SZPAK_LLAMA_CACHE` overrides the root). A finished build with the same options is reused; a rebuild starts from an empty build folder. CMake options on top of Release, static, arm64, macOS 14.4:

| Option | Why |
|---|---|
| `GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON` | GPU inference, the shader library inside the binary |
| `LLAMA_OPENSSL=OFF` | the server speaks plain HTTP on loopback; with it on, a Mac with Homebrew links `/opt/homebrew/.../libssl`, which cannot ship |
| `LLAMA_SUBPROCESS=OFF` | compiles out process spawning (the server's shell and file tools, router mode) |
| `LLAMA_BUILD_UI=OFF`, `LLAMA_USE_PREBUILT_UI=OFF` | no web UI, and no download of it from Hugging Face at build time |
| `GGML_NATIVE=OFF`, `GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16` | CPU code for every Apple Silicon Mac, not only the build machine's (an M3 `-mcpu=native` build could crash on an M1) |
| `LLAMA_BUILD_TESTS/EXAMPLES/APP=OFF` | only the `llama-server` target is built |

The result links only system libraries (`otool -L`): Accelerate, Foundation, Metal, MetalKit, CoreFoundation, `libSystem`, `libc++`, `libobjc`. About 20 MB.

The "Embed llama-server" build phase (`project.yml`, the app target) copies `LLAMA_SERVER_PATH` into the app's `Contents/MacOS/llama-server` and signs it (ad-hoc in Xcode builds). A Debug build without the helper only warns (the app then has no local AI); a Release build fails. The phase reads a file outside the source tree that may be missing, so the target has user script sandboxing off. `scripts/sign-app.sh` signs every helper in `Contents/MacOS` inside-out with the app's identity and hardened runtime (no entitlements), before the app. Debug builds can also point at a helper with `SZPAK_LLAMA_SERVER` (`LlamaServerLocator`).

## Hosts contacted

For the privacy screen ("Prywatność", PRD 7.6): the local AI contacts the network only while a model downloads, and only `huggingface.co` and the CDN it redirects to (subdomains of `huggingface.co` and `hf.co`, e.g. `cdn-lfs.hf.co`, `cas-bridge.xethub.hf.co`), over HTTPS, without an account, cookies or a token. The downloader refuses any redirect elsewhere or to plain HTTP (`LocalModelCatalog.downloadHostSuffixes`). Inference only talks to 127.0.0.1. The optional cloud Bielik (CloudFerro Sherlock, PRD 7.5) lives outside this module.

## Requirements per tier

| Tier | Mac | Correction | AI features | Download | Free disk needed | Server memory budget |
|---|---|---|---|---|---|---|
| standard | 16 GB RAM and more | Bielik 1.5B Q8_0 | Bielik Minitron 7B Q4_K_M | 6.2 GB | 7.2 GB | 60 % of RAM (10.3 GB on 16 GB: both models, 9.8 GB) |
| experimental | under 16 GB | Bielik 1.5B Q8_0 | Bielik 1.5B (or the cloud Bielik when the user set it up) | 1.7 GB | 2.7 GB | 45 % of RAM (3.9 GB on 8 GB), one server at a time |

Planned memory per model (mapped file plus working memory): 1.5B 2.3 GB at -c 8192 (measured); Minitron 8.45 GB at the features context -c 24576 (measured by F3 in the app: 8.3-8.45 GB RSS, the 4.50 GB mapped file plus 4.0-4.4 GB physical footprint of KV cache and Metal buffers; the peak is the plan); 4.5B 7.5 GB (estimate, not measured). On a 16 GB Mac the budget (0.6 x 16 GiB = 10.3 GB) holds either model but not 1.5B + Minitron (10.75 GB), so the service stops the 1.5B while Minitron runs and starts it again for the next dictation (about 1-2 s). That is the owner's decision of 2026-11-08, over a bigger budget (swap risk) or a smaller features context on 16 GB (more meeting parts). From 24 GB both stay loaded. On the experimental tier a model over 35 % of the RAM (Minitron, 4.5B) is allowed with a memory warning (`HardwareProfile.needsMemoryWarning`).

## Measured numbers

F0, 2026-11-07, M3 Pro 36 GB, llama-server v0.9.0, -c 8192, -ngl 99, temperature 0, 60 real dictations (median 32 words). All constants live in `LocalAITuning`.

| | Bielik 1.5B Q8_0 (correction) | Bielik Minitron 7B Q4_K_M (features) |
|---|---|---|
| load, cold / warm | 1.4-1.7 s / 0.3 s | 3.9-7.7 s / 0.8 s |
| first token p50 | 0.07-0.09 s | 0.4 s |
| generation, prompt | ~47 tok/s, ~650-850 tok/s | ~18 tok/s, ~215 tok/s |
| seconds per input word p50 / p95 | 0.032 / 0.039 | 0.15 / 0.23 |
| dictations up to 60 words p50 / p95 | 0.99 s / 1.75 s | - |
| memory (file + working) | 1.70 + 0.45-0.6 GB, plan 2.3 GB | 4.50 + 1.7-2.1 GB, plan 6.6 GB |

| Constant | Value |
|---|---|
| `correctionContext`, `featuresContext` | 8192, 24576 (server `-c`). Bielik 1.5B was trained on 8192 tokens (never more); Minitron 7B on 32768; 24576 = the meeting code's 20k-token input budget (`TranscriptChunker.defaultInputBudget`) plus a 4k answer. A model serving both roles runs with the larger |
| `measuredPeakRAM` | 1.5B 2.3 GB (-c 8192), Minitron 8.45 GB (measured at -c 24576), 4.5B 7.5 GB (estimate at -c 24576); `ramFactor` 1.3 only for models without a value |
| deadline cleanup | 1.0 s + words x 0.04 s x 1.5, cap 15 s |
| deadline modes | 10.0 s + words x 0.23 s x 1.5, cap 30 s (F3: a mode's answer can be much longer than the dictation; with 3.0 s, 9 of 36 short dictations hit the limit) |
| `guardMinimumSimilarity` | 0.5 (on the merged text) |
| memory budget, warning | 0.6 / 0.45 of RAM per tier, warning above 0.35 on the experimental tier |

## Correction merge

The 1.5B changes the meaning in 8-15 % of dictations even with a good prompt: it turns "zrób" into "zrobię", "wyciąć" into "wyciszyć", "robiliśmy" into "robiłyśmy", summarizes and loops. `CorrectionMerger` keeps its useful edits and nothing else (with it the meaning held in 60 of 60 F0 samples):

1. Both texts are split into words with their glued punctuation and aligned on the lowercased, punctuation-stripped words with difflib-style opcodes.
2. **equal**: the model's token (punctuation, capitals).
3. **replace** of the same length (fillers in the block aside): the model's words only when every pair is safe: (a) the same word once diacritics and "ł" are folded, (b) a term from the user's vocabulary at least 50 % similar by characters, or (c) more than 85 % similar by characters; in (a) and (c) the model's word must also be spelled right (Polish or English, or in the vocabulary) and use Polish or English letters only. Otherwise the raw words come back with their own punctuation.
4. **delete**: only fillers (yyy, yy, eee, ee, mmm, hmm, hm, um, uh, uhm, eh) and repeats of the kept word next to them; otherwise the raw words come back.
5. **insert**: dropped.
6. Next to a reverted block or a dropped insertion the model's punctuation is not trusted: the word before takes the raw trailing punctuation, the word after the raw punctuation and loses a capital the model gave it only for its own sentence start (no "zadań. to do.", no "jesteś, na innym").
7. The final sentence mark of the model's answer is kept, the first letter and every sentence start get a capital (not after "np.", "itd.", "godz." and similar).

`CorrectionGuard.apply(raw:output:vocabulary:spellCheck:)` runs the merge, then the outer check on the merged text (length 50-150 % for inputs over 40 characters, word similarity at least 0.5) and returns the text to paste (the merged text, or the raw text with a reason) plus the counts (accepted edits, reverted words, dropped words). The spell check is a closure so the merge stays pure and testable: `CorrectionSpelling.knownWords(in: output)` asks `NSSpellChecker` on the main actor once per answer and `CorrectionSpelling.lookup` turns the result into the closure.

## Integration points (for the app)

All wired (F2, branch `bielik-f2-integration`); details in docs/architecture.md ("AI routes", "AI cleanup", "AI in Modele").

1. **Paths** - done. `App/LocalAIServices` builds the store, the service and the usage counter on `AppPaths.localModels` (`<data>/LocalModels`), `AppPaths.localAIRun` (`<data>/LocalAI`, pid files) and `AppPaths.localAIUsage` (`<data>/local-ai-usage.json`). The design preview and the test host get a temp folder and no service (`AppStateOverrides.localAIRoot`, `startsLocalAI = false`): they never start llama-server; the preview pins the download states (`LocalAIModelStore(pinnedStates:)`).
2. **Plan and settings** - done. `AIRoleRouting` takes `HardwareProfile.current.plan(cloudFeaturesAvailable:)` as the default and the user's pick per role from Modele > Zaawansowane (`AppSettings.aiCorrectionModel` / `aiFeaturesModel`); its `roleModels` go to `LocalAIService.setRoleModels`, the idle time (`AppSettings.localAIIdleMinutes`, 10 min by default, 0 = never) and `HardwareProfile.memoryBudgetBytes` to `setOptions`, live on every change (`AppState.applyAIRouting`). Under 16 GB the AI features default to the cloud when it is on with a key, else the 1.5B, decided per request.
3. **AIRole mapping** - done. `LocalRole(AIRole)` in `LocalAIRouteProvider`; a role on "Chmura" never reaches this module (`AIRoleRouteProvider`).
4. **Requests** - done. `LocalAIRouteProvider` turns the endpoint into an `AIRoute` for the app's `ChatCompletionsClient`. The cleanup sends the few-shot conversation in `<tekst>` tags (temperature 0, `max_tokens` = words x 3 + 32) and every cleanup answer goes through `CorrectionGuard.apply` with the dictionary terms, the learned forms and `CorrectionSpelling` (`Enhancer`); dictation waits `LocalDeadline.limit(for:input:)` (the mode's limit as the floor) on the local and the cloud route. Meeting transcript fixes use the meeting module's own line guard, `TranscriptFixGuard`, per line instead (stricter for numbered lines; in trials the 1.5B damaged 62 of 306 clean lines without it, none with it). Long meeting calls hold the endpoint (`withEndpoint` through `AIRouteProviding.withRoute`), so the idle stop never cuts them.
5. **Lifecycle hooks** - done. Prewarm of the active mode's role on hotkey down (`.correction` for "Czyszczenie", `.features` for other modes) and in `--transcribe --ai`; `LocalAIModelStore.willDelete` -> `LocalAIService.stop(modelID:)`; `stopServices()` (quit) and every headless debug run -> `terminateAllNow()`; `onUnexpectedExit` and timeouts -> `LocalUsageStats.record`.
6. **Usage counter** - done. `.dictation` per delivered dictation, `.correctionAccepted/Rejected` and `.timeout` from the dictation enhancer, `.modeUsed` (built-in key or mode id), `.meetingProcessed` when a finished meeting's notes were written, `.serverFailure`; shown in Modele > Zaawansowane > "Statystyki lokalnej AI" with "Eksportuj JSON" (`NSSavePanel`) and "Wyzeruj".
7. **Onboarding and privacy** - done. "Pobierz Bielika" (`BielikStep`) and the requirements box in Modele use `LocalAIRequirements`, `DiskSpace.availableBytes` and `BielikDownloadPlan`; Ustawienia > "Prywatność" names the hosts above.
8. **Release** - unchanged: `make llama` before `make release` / `make dist`; the notarization covers the helper because `scripts/sign-app.sh` signs it.

Checked end to end on 2026-11-07 (M3 Pro 36 GB, Debug build, `CAPTYLO_DATA_DIR` with `LocalModels` symlinked to the F0 model folder): `--check` found the helper, both models and the standard tier; `--transcribe --ai` on two invented Polish dictations spoken by the system voice ran Whisper and then the cleanup on the 1.5B through the app's route in 0.9 s and 1.8 s (server started by the prewarm), both accepted by the guard; without the prewarm a fresh process missed the 3 s floor, which is why the debug run now prewarms like the hotkey.

## Tests

`CaptyloTests/LocalAI*Tests.swift` (Swift Testing): catalog integrity, tiers and plans, downloader through a `URLProtocol` stub (fresh download, Range resume, a server that ignores Range, SHA mismatch removes the `.part`, cancel keeps it, no disk space, redirect to the CDN keeps the Range, redirect elsewhere refused, HTTP errors), the store, the guard and the merger with each of its rules (synthetic Polish sentences, a fixed spell check), the deadline, server arguments and environment, the server lifecycle and the service with a fake process launcher (shared process, port retry, crash, idle stop, cooldown, timeout, memory budget), pid files against a real `/bin/sleep`, usage stats round trip and export.

`LocalAIEndToEndTests` runs the real helper and a real model, off in `make test`:

```bash
lockf -k <shared heavy-work lock> env \
  TEST_RUNNER_SZPAK_LLAMA_E2E=1 \
  TEST_RUNNER_SZPAK_LLAMA_SERVER="$(scripts/build-llama-server.sh --path)" \
  TEST_RUNNER_SZPAK_LLAMA_MODEL=<path to Bielik-1.5B-v3.0-Instruct.Q8_0.gguf> \
  xcodebuild -project Captylo.xcodeproj -scheme Captylo -derivedDataPath .local-build \
  CODE_SIGN_IDENTITY="-" test -only-testing:CaptyloTests/LocalAIEndToEndTests
```

xcodebuild passes environment variables prefixed with `TEST_RUNNER_` to the tests without the prefix. The model file is only read where it is.
