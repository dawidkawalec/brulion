# Brulion

**Mów, a Bielik poprawi tekst na Twoim Macu.** Speak, and the text appears wherever you type, with all of the AI running on Bielik on your own Mac.

Brulion is an open source dictation and meeting-notes app for macOS. Its whole language layer runs on **Bielik**, the Polish open language model by [SpeakLeash](https://speakleash.org), locally through llama.cpp. You need no account, no subscription and no server of ours. Speech recognition and AI stay on the Mac. If you want, the AI can run on Bielik 11B v3.0, the strongest Bielik, in the Polish cloud instead (CloudFerro Sherlock, with your own key): only the AI features, or everything.

The name is the Polish word for a rough-draft notebook: you speak "na brudno" (rough), and Bielik gives you the text "na czysto" (clean).

Brulion is a fork of [Captylo](https://captylo.com) 1.0.17, made for [Bielik Awards 2026](docs/bielik-awards.md) (category c, small language models under 10B parameters).

## How it works on Bielik

```text
Dictation (hold Right ⌘, speak, let go)
  microphone -> Whisper large-v3 turbo (Neural Engine)            raw text
             -> Bielik 1.5B + word guard     "Czyszczenie"         text pasted at the cursor   ~1.4 s
             -> Bielik Minitron 7B           AI modes (e-mail, list, English, your own prompts)  ~10 s

Meetings (⌃⌥⇧M: mic + system audio, no bot)
  live Whisper transcript -> speaker labels (on device)
             -> Bielik 1.5B + line guard     fixes of misheard words (optional)
             -> Bielik Minitron 7B           AI notes with [mm:ss] citations, "Zapytaj" (ask the meeting)
```

- **The model server:** `llama-server` from llama.cpp (pinned commit, Metal) ships inside the app. Brulion starts it when needed:
  - only on `127.0.0.1`, on a random port, with a token on every request;
  - it frees the memory after 10 idle minutes (you can change this) and quits with the app.
- **Two roles, two models:**
  - *dictation correction* (cleanup, meeting transcript fixes, note titles) on **Bielik 1.5B v3 Q8_0** (1.7 GB);
  - *AI features* (modes, meeting notes, "Zapytaj") on **Bielik Minitron 7B v3 Q4_K_M** (4.5 GB).

  In Modele you can pick another model for each role: Bielik 4.5B, Minitron or Bielik in the cloud.
- **Model downloads:** models come from SpeakLeash's official Hugging Face repositories at pinned revisions. Downloads resume after a break and each file is checked against its SHA-256 before use.
- **The word guard:** a small model asked to "fix punctuation" sometimes changes the meaning (the person, a summary, a loop). Brulion therefore merges the answer with the raw text word by word. It keeps only punctuation, capitals, Polish diacritics, small typos (macOS spell checker), your dictionary terms and removed fillers, and puts every other word back. In our 60-dictation test the meaning stayed intact in all 60.
- **Bielik in the cloud (optional):** "Gdzie działa Bielik" in Modele has three options:
  - "Na tym Macu" (the default): everything above, offline;
  - "Funkcje AI w chmurze": the correction stays on the Mac, while the modes, meeting notes and "Zapytaj" run on **Bielik 11B v3.0 Instruct** in CloudFerro Sherlock;
  - "Wszystko w chmurze": both roles on Bielik 11B.

  Under "Dostawca" you pick where the 11B runs, only places that keep the data in Poland: **CloudFerro Sherlock** (the default), **PCSS AI HUB** in Poznań, or your own OpenAI-compatible server (for example Bielik on your company's vLLM). You paste your own key, and the requests go straight from your Mac to that provider. The 11B model is above the 10B limit of the award category, so it is only an option: every number below comes from the local models.
- **When the model is late or down:** dictation never hangs. Past a time limit that grows with the text, or when the model server fails, Brulion pastes the raw text and says why.

## Numbers

MacBook Pro M3 Pro, 36 GB RAM. 60 real dictations of the author, with no client data. Full method and tables: [docs/benchmark.md](docs/benchmark.md) (in Polish).

| | Result |
|---|---|
| Correction on Bielik 1.5B, dictations up to 60 words | p50 1.37 s, p95 2.49 s in the app (Captylo's cloud AI: 0.80 s / 1.82 s) |
| Meaning kept after the correction | 60 of 60 (without the word guard the 1.5B changed it in 8-15%) |
| Punctuation F1 against the cloud output | 0.82 raw Whisper -> 0.89 |
| AI modes on Minitron 7B (e-mail, list, organize) | p50 ~10 s, p95 18-25 s; 3 of 36 fell back to the raw text |
| AI notes on Minitron 7B | 30-44 min meeting in 2-3 min, 60 min in 6 min (in the background) |
| Memory of the model server | 2.0 GB (1.5B), 8.3-8.5 GB (Minitron, incl. the mapped model file) |
| Network while working | none: every run used only 127.0.0.1, and the pipeline also runs in a sandbox with outbound internet blocked |

## Requirements

- macOS 14.4 or later on Apple Silicon (M1 or newer).
- **Full local AI: 16 GB of RAM** and about 7.2 GB of free disk space for the Bielik models (6.2 GB, plus 1 GB of headroom while downloading), plus 1.5 GB for the Whisper model.
- **Less than 16 GB (experimental):** the correction runs locally on Bielik 1.5B, and the AI features run either on the 1.5B (weaker) or on Bielik in the cloud with your own CloudFerro Sherlock key. Not tested on an 8 GB Mac.
- Permissions:
  - Microphone and Accessibility (for the global hotkey and for pasting);
  - for meetings, "System Audio Recording Only";
  - optional: Calendars.

## Install

1. Download `Brulion-x.y.z.dmg` from the [GitHub releases](https://github.com/dawidkawalec/brulion/releases). It is signed with a Developer ID and notarized by Apple.
2. Open it and drag Brulion to the Applications folder ("Programy").
3. Open Brulion. The onboarding:
   - asks for the microphone, then for Accessibility;
   - downloads the speech model;
   - in the "Pobierz Bielika" step, shows what your Mac can run and downloads the Bielik models.

After that, dictation and the AI work offline. Brulion runs side by side with Captylo, with its own data folder and its own shortcuts. There are no automatic updates: a new version is a new release.

## Features

- **Hotkey:** a short tap starts and stops dictation, holding it records push-to-talk. The default is Right Command; Right Option, Fn or your own combo also work.
- **Transcription:** local Whisper large-v3 turbo (WhisperKit, Neural Engine), with a live preview in a small floating widget.
- **Correction:** Bielik 1.5B with the word guard ("Czyszczenie", the default AI mode).
- **AI modes:** on Bielik Minitron 7B (e-mail, to-do list, organize your thoughts, English, your own prompts). Each mode has a hard time limit.
- **Learning:** fix a word once and Brulion remembers it, on your Mac.
- **Dictionary:** vocabulary hints and replacement rules for names and terms.
- **History and dashboard:** history with audio playback, search and CSV export; a dashboard with words, sessions and time saved.
- **File transcription:** drop an audio or video file, including voice notes from WhatsApp or Telegram.
- **Meetings:**
  - records the call (mic and system audio, no bot) and transcribes it live (⌃⌥⇧M starts and ends it);
  - notices call apps and asks whether to record;
  - after the call, all on Bielik: speaker labels (macOS 15+), AI fixes of misheard words (the original can be restored), and AI notes in parts with a merge for long meetings.
- **Meeting search:** finds anything said in any meeting, whatever the Polish word form.
- **"Zapytaj":** ask one meeting, or all of them, in plain language. The answer has clickable `[mm:ss]` sources. If the meetings do not say it, Brulion says so instead of guessing.
- **Local usage counter, with no telemetry:**
  - dictations;
  - corrections the guard accepted and rejected;
  - average time;
  - modes and meetings.

  It can be exported to JSON.
- **Other:** a local, read-only MCP server for your AI assistant (off by default), calendar names and reminders (optional), a menu bar menu, and a Polish UI with English translations.

## Build it yourself

You need a Mac with Apple Silicon, **Xcode 26** (installed and opened once) and Homebrew.

```bash
brew install xcodegen cmake
git clone https://github.com/dawidkawalec/brulion.git brulion
cd brulion
make llama     # builds llama-server from the pinned llama.cpp commit (once, cached in ~/Library/Caches/Brulion)
make install   # Release build of Brulion.app with llama-server inside, copied to ~/Downloads and /Applications
```

Other targets:

```bash
make gen      # generate Brulion.xcodeproj from project.yml
make build    # Debug build into .local-build/
make test     # unit tests
make release  # Release build, copied to ~/Downloads/Brulion.app
make check    # permissions, models, local AI and paths as JSON
```

Self-built copies are signed ad hoc, so macOS may forget the permissions after a rebuild. You can run `make reset-tcc` and grant them again, or run `scripts/setup-signing.sh` once to keep them across builds.

The headless flags (`--transcribe`, `--meeting-ai`, `--check`) and how to repeat the measurements are described in [docs/architecture.md](docs/architecture.md) and [docs/benchmark.md](docs/benchmark.md). How the local AI is built: [docs/local-ai.md](docs/local-ai.md).

## Privacy

Everything runs on your Mac: recordings, transcripts, AI answers, meeting notes and what Brulion learns from your corrections. There is no telemetry, no update check, no account and no server of ours. Brulion opens a network connection in only two cases:

- **huggingface.co,** while it downloads the speech model and the Bielik models;
- **The cloud provider you pick** (CloudFerro Sherlock, PCSS AI HUB or your own server), only if you choose one of the cloud options under "Gdzie działa Bielik" in Modele and paste your own key. The AI requests of the roles you put on the cloud then go straight from your Mac to that provider, with no proxy of ours. Each provider's key is kept in the macOS login Keychain.

Learning from your corrections reads back only the text field you dictated into, for a short while. It never reads password fields, password managers or terminals. What it learns stays in `learning.json` next to the dictionary.

The MCP server for AI assistants is off by default. It only reads your meetings and answers only the assistant that started it. The calendar is read on this Mac only while "Kalendarz" is on.

## Licence

Brulion is free software under the [GNU General Public License v3.0](LICENSE), like Captylo it was forked from.

- The Bielik models are made by SpeakLeash and released under Apache 2.0. They are downloaded from Hugging Face on first use, not bundled.
- llama.cpp is MIT.
- Brulion's mark and icon (a lowercase "b" whose stem is a pencil and whose bowl is a speech bubble, in the colours of the Bielik site) are our own drawing for Brulion (`scripts/make-brulion-brand.swift`, files in `docs/brand/`). They are not the Bielik or SpeakLeash logo. Like the Captylo name and logo, the Brulion name and mark are not licensed for other products (NOTICE.md).

[NOTICE.md](NOTICE.md) lists every third-party component with its licence.

Thanks to SpeakLeash and the Bielik team, llama.cpp, WhisperKit and FluidAudio.

Made by [Dawid Kawalec](https://kawalec.pl) (CRAFTWEB).
