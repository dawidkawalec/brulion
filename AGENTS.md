# Brulion

> **Sprint Bielik Awards 2026 (do 15.11.2026).** Brulion to fork Captylo 1.0.17 (`9371dd7`), w którym cała AI działa na Bieliku na Macu użytkownika, a chmura Captylo (konto, Pro, przekaźnik, OpenRouter, ElevenLabs, Stripe, Sparkle) jest wycięta. Źródło prawdy na czas sprintu: [docs/PRD.md](docs/PRD.md); konkurs: [docs/bielik-awards.md](docs/bielik-awards.md). Gdy PRD i ten plik się rozjeżdżają, rozstrzyga PRD. Plane: projekt CAPTYLO, moduł "Captylo na Bieliku (Bielik Awards 2026)", CAPTYLO-98 do 103; stan aktualizuj skillem `plane-sync`. Nazwa: brulion to zeszyt na brudno - mówisz na brudno, Bielik oddaje tekst na czysto. Interfejs mówi wszędzie "Brulion" (odmiana: Brulionu, Brulionowi, Brulion (biernik), Brulionem, w Brulionie); "Captylo" zostaje tylko tam, gdzie chodzi o oryginalną aplikację (komentarze o forku, podziękowania w `NOTICE.md`), a `AppIdentityTests` pilnuje katalogów tekstów i Info.plist.

macOS dictation and meeting notes app: hold a hotkey, speak, the text lands at the cursor; meetings are recorded on the Mac (mic + system audio, no bot) with a live local transcript. Speech runs on local Whisper large-v3-turbo (WhisperKit). Every language task (dictation cleanup, AI modes, meeting notes, transcript fixes, "Zapytaj") runs on SpeakLeash's Bielik models through a bundled `llama-server` on 127.0.0.1. The only optional cloud is Bielik 11B in CloudFerro Sherlock on the user's own key, off by default. Description wording: "działa na Bieliku".

**Identity**: product `Brulion.app` (executable `Brulion`), bundle `pl.craftweb.brulion`, data in `~/Library/Application Support/Brulion/`, llama.cpp cache `~/Library/Caches/Brulion/llama.cpp/`, Keychain service and log subsystem `pl.craftweb.brulion`, URL scheme `brulion`, MCP server name `brulion`, macOS 14.4+, arm64 only. The Swift module, folders and project are named Brulion too: module `Brulion`, `Brulion/`, `BrulionTests/`, generated `Brulion.xcodeproj` with scheme `Brulion`, entry point `BrulionMain`, entitlements `Brulion/Brulion.entitlements`. Identity lives in one place: `Brulion/App/AppIdentity.swift`, the `APP_*` settings in `project.yml` and `PRODUCT` / `BUNDLE_ID` in the `Makefile`. Defaults differ from Captylo so both apps run side by side: dictation on Right Command, meeting ⌃⌥⇧M, voice note ⌃⌥⇧N, "Popraw" ⌃⌥⇧P.

**Open source**: GPLv3 (`LICENSE`), third-party code and models in `NOTICE.md`. Repo `github.com/dawidkawalec/brulion`, private until the public release (owner's go-ahead first). Everything committed may become public: no secrets, no personal data, no real dictations or meetings. "Bielik" is SpeakLeash's mark: never in the product name or the icon. The Captylo name, logo and icon are not licensed for this fork.

**No accounts, plans or telemetry.** No sign-in, no Pro, no payments, no update checks. Network use is only: huggingface.co and its CDN while a model downloads (pinned revision, sha256 checked), and CloudFerro Sherlock while "Bielik w chmurze" is on.

## Stack

- **App**: Swift 6 (strict concurrency), SwiftUI + AppKit panels → `Brulion/`; XcodeGen `project.yml` → generated `Brulion.xcodeproj` (git-ignored, never hand-edit)
- **Speech**: WhisperKit 1.1.0 (Whisper large-v3-turbo on the Neural Engine) → `Brulion/Transcription/`; FluidAudio 0.17.4 only for the meeting VAD and diarization
- **Local AI** → `Brulion/LocalAI/` ([docs/local-ai.md](docs/local-ai.md)): model catalog (Bielik 1.5B v3 Q8_0 for "korekta", Bielik Minitron 7B v3 Q4_K_M for "funkcje AI", Bielik 4.5B v3 Q8_0 as an alternative), hardware tiers (16 GB+ both local, under 16 GB experimental), downloader (Range resume, sha256), `LlamaServer` (one process per model, random port, token, idle stop), `LocalAIService`, `CorrectionGuard` + `CorrectionMerger` (word-level guard), `LocalDeadline`, `LocalUsageStats`. Helper: llama.cpp v0.9.0 (`cd959bae`), static, Metal, no SSL, built by `scripts/build-llama-server.sh` into `~/Library/Caches/Brulion/llama.cpp/`, embedded in `Contents/MacOS/`
- **AI routing** → `Brulion/Enhancement/`: `AIRouteProviding` resolves a route per `AIRole` (`correction`, `features`) to the local server, to Sherlock (`CloudAIRouteProvider`) or to nothing (raw text is pasted); `ChatCompletionsClient` is the OpenAI-compatible client; `Enhancer` runs dictation cleanup and AI modes with a hard deadline; `CleanupPrompt` holds the Polish few-shot correction prompt
- **Meetings** → `Brulion/Meetings/`: recording, live local Whisper per track, call detection, calendar (EventKit), FTS5 search (`Search.sqlite`), read-only MCP server (`--mcp`); meeting AI with open Polish prompts in `Meetings/AI/Instructions/` (`MeetingPrompts`, `TranscriptChunker`, `MeetingNotesWriter`, `CitationNormalizer`, `TranscriptFixGuard`); views in `Brulion/UI/Meetings/`
- **Notes**: typed, dictated and voice notes, recording import → `Brulion/Notes/`, `Brulion/UI/Notes/`
- **Data**: SwiftData store + `dictionary.json` + WAV recordings + meeting CAF tracks + `LocalModels/` → `Brulion/Data/`, `Brulion/Text/`
- **Tests**: Swift Testing → `BrulionTests/`

## Commands

```bash
make gen      # xcodegen generate (after adding/removing files)
make build    # Debug build into .local-build/
make test     # unit tests
make llama    # build (or reuse) the llama-server helper
make release  # Release build to ~/Downloads, signed with "Brulion Dev" (or ad-hoc)
make dist VERSION=x.y.z      # Developer ID, notarization, stapled DMG into dist/ (owner only)
make dist-dry VERSION=x.y.z  # the same with "Brulion Dev", nothing leaves the Mac
make run      # launch the last build
make check    # Debug binary --check as JSON
scripts/snap.sh <target> <out.png>   # screenshot one screen from the design preview
```

The real end-to-end test of the helper and a model (`LocalAIEndToEndTests`, off in `make test`) is described in docs/local-ai.md.

## Docs

- [docs/PRD.md](docs/PRD.md) - sprint scope, models, phases, decisions; [docs/bielik-awards.md](docs/bielik-awards.md) - the contest entry
- [docs/local-ai.md](docs/local-ai.md) - local AI module, helper, flags, tiers, requirements
- [docs/architecture.md](docs/architecture.md) - modules, data flow, debug CLI flags
- [docs/coding-standards.md](docs/coding-standards.md) - Swift 6 rules, UI language, naming
- [docs/release.md](docs/release.md) - Developer ID release and notarization
- [docs/design/dusk-glass.md](docs/design/dusk-glass.md) - Dusk Glass design language (binding for all UI)
- [README.md](README.md), [NOTICE.md](NOTICE.md)

## Critical Rules

- Never copy code or prompts from the private Captylo server (`vocatypecustom/server`). All prompts in this repo are written from scratch and stay open.
- Real dictations, meetings and personal data never enter git (fixtures, screenshots, benchmark samples, docs). Measurement data stays outside the repo; `docs/benchmark.md` holds only aggregated numbers. The cloud baseline is called "Captylo AI (chmura)", without its model's name.
- No silent network: a new host needs a privacy text update and the owner's decision. Never log user text, prompts or model output; `llama-server` runs with low log verbosity and its output stays in an in-memory tail.
- Every dictation cleanup answer passes `CorrectionGuard.apply`; every meeting transcript fix passes `TranscriptFixGuard`. On rejection, timeout, server failure or no route the raw text is pasted, never an error text: errors go to `errorMessage`. Never remove real Polish words deterministically.
- `llama-server` listens only on 127.0.0.1 with a random port and a token (passed by environment, not argv), starts with a clean environment, and stops with the app. The design preview and the test host never start it or touch the real data folder.
- Numbers for the contest come from local models below 10B only; never claim the local model matches the cloud.
- Swift 6 language mode, no default MainActor isolation: annotate UI/AppKit types `@MainActor`, keep audio callbacks nonisolated.
- UI strings are Polish in code (`String(localized:)` / SwiftUI literals) with English in `Localizable.xcstrings` (LocalAI has its own `LocalAI.xcstrings`); never hardcode English UI text. Only the plain hyphen "-" in any text, never em or en dashes.
- No new dependencies without a note in docs/architecture.md and an entry in NOTICE.md (GPLv3-compatible licences only). No secrets in the repo; the Sherlock key lives in the login Keychain.
- Meeting audio lives in `AppPaths.meetings/<meetingID>/` (never under `Recordings/`), voice notes in `AppPaths.notes/<noteID>.wav`. Every delete of a note, meeting or dictation writes a `Tombstone` in the same save; every write stamps `updatedAt` and `deviceID`.
- One local speech engine: `WhisperEngine`. Meeting utterances stay at most 14 s. Diarization only on macOS 15+ (FluidAudio #878).
- Meetings never record or stop without a visible prompt or click; the calendar never starts a recording; event titles and attendee names are never logged. Every store write that changes searchable meeting text also updates `Database.searchIndex`. The MCP mode (`--mcp`) stays read-only and offline (store `allowsSave: false`, index read-only, no AI calls); test it only with `BRULION_DATA_DIR` pointing at a copy.
- After adding files run `make gen`; a change is done only when `make build` and `make test` pass.
- Signing: development builds ad-hoc or "Brulion Dev"; public releases only through `make dist` (Developer ID, hardened runtime, notarized, helper signed inside-out by `scripts/sign-app.sh`), and only with the owner's go-ahead. Never commit a `.p12`, `.p8`, key or password.
- Git: commit in work branches; merging into `main`, making the repo public and pushing to `main` only on the owner's word. No AI traces in commits or PRs (no `Co-Authored-By`). Remote `captylo-local` is the local Captylo repo, for reference only; never push to `dawidkawalec/captylo`. `origin` is `dawidkawalec/brulion`.
