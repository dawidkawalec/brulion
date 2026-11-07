# PRD - Captylo na Bieliku (nazwa do wyboru, sekcja 4)

Wersja 1, 2026-11-07. Właściciel: Dawid Kawalec (CRAFTWEB Sp. z o.o.).
Twardy termin: zgłoszenie do Bielik Awards 2026 do **15.11.2026, 23:59**. Cel: formularz wysłany **14.11** (dzień zapasu).
Konkurs, kryteria i lista rzeczy do zgłoszenia: [bielik-awards.md](bielik-awards.md).

## 1. Po co to robimy

- **Konkurs**: Bielik Awards 2026 (Fundacja SpeakLeash), kategoria **(c) "Najlepsze użycie modelu SLM (<10B)"**: wdrożenie na małym modelu, pokazujące wartość mniejszych modeli, w tym instalacji on-premise i on-device. Nagroda 7 500 zł i statuetka, gala 26.11 w Warszawie (Dawid jedzie). Zgłaszający: CRAFTWEB Sp. z o.o.
- **Produkt**: kopia Captylo (dyktowanie i notatki ze spotkań na Macu, open source GPLv3), w której **cała AI działa na Bieliku na Macu użytkownika**, a nasza chmura (konto, Pro, przekaźnik "Captylo AI", OpenRouter, ElevenLabs, Stripe, Sparkle) znika. Tekst nie wychodzi z komputera. Wyjątek: świadomie włączony Bielik w chmurze na słabszych Macach (sekcja 6).
- **Dlaczego to ma szansę**:
  - W naszym researchu konkurencji Captylo nie znaleźliśmy polskiej aplikacji do dyktowania ani notatnika spotkań na Bieliku.
  - Pokazuje dokładnie to, o co pyta kategoria: mały model na urządzeniu daje prywatność, pracę offline, zero kosztów i krótki czas odpowiedzi.
  - Otwarty kod, więc komisja SpeakLeash może to sprawdzić.
  - Bazą jest wydana aplikacja (Captylo 1.0.17, Developer ID, notaryzacja, użytkownicy), nie prototyp.
- **Kryteria oceny (§ 7 regulaminu)**: realna wartość z liczbami, oryginalność, jakość techniczna, dojrzałość wdrożenia. Liczby zbieramy sami (sekcja 8).

## 2. Cele, nie-cele, anty-cele

**Cele**
1. Dyktowanie: korekta transkrypcji (interpunkcja, wielkie litery, wypełniacze, autopoprawki, słownik) na **najmniejszym** Bieliku, lokalnie.
2. Funkcje AI (tryby wbudowane i własne prompty, "Przetwórz przez AI" w notatkach i historii) na **mocniejszym** Bieliku, lokalnie.
3. Spotkania: poprawki transkryptu, notatki AI według szablonów i "Zapytaj" (o jedno spotkanie i o całą bibliotekę), lokalnie.
4. Zero połączeń sieciowych w pracy. Jedyne wyjątki to pobranie modelu z Hugging Face i opcjonalny Bielik w chmurze. Da się to sprawdzić (Little Snitch, `nettop`).
5. Liczby do zgłoszenia: jakość, czas i pamięć na naszych nagraniach oraz porównanie z obecnym Captylo.
6. Publiczne wydanie przed 13.11: repo na GitHubie (GPLv3) i podpisany, notaryzowany DMG.

**Nie-cele**: konto, płatności i plany; przekaźnik; transkrypcja w chmurze; automatyczne aktualizacje (Sparkle); iOS i Windows; nowe funkcje poza AI; zmiany wyglądu poza ekranem modeli, onboardingiem i usuniętymi kartami.

**Anty-cele** (porażka, nawet jeśli wszystko "działa"):
- korekta zmienia sens, dopisuje treść, tłumaczy albo odpowiada na pytanie z dyktowania, zamiast je wyczyścić;
- dyktowanie czeka na AI dłużej niż limit z sekcji 5; zawsze wklejamy surowy tekst jako zapas;
- aplikacja po cichu łączy się z jakimkolwiek serwerem, w tym z naszym;
- Mac z 8 GB zaczyna mocno swapować przy Whisperze i Bieliku naraz;
- do repo trafia kod albo prompty z prywatnego serwera Captylo (`vocatypecustom/server`), prawdziwe dyktowania albo dane użytkowników;
- słowo "Bielik" w nazwie produktu (to znak SpeakLeash); piszemy "działa na Bieliku".

## 3. Punkt wyjścia: Captylo 1.0.17 (commit `9371dd7`)

Ok. 49 tys. linii Swifta, 127 plików testów. Mapa poniżej pochodzi z `rg`. Wykonawca potwierdza ją w F1 tym samym `rg` (`AccountStore|isPro|trial|relay|OpenRouter|ElevenLabs|Sparkle|SiteLinks`).

| Co | Pliki | Decyzja |
|---|---|---|
| Nagrywanie, skróty, wklejanie, tekst | `Audio/`, `Hotkeys/`, `Output/`, `Text/` | zostaje |
| Lokalna transkrypcja | `Transcription/WhisperEngine`, `LocalModelStore`, `LivePreview`, `LocalTranscribing`, `WordErrorRate`, `ModelBenchmark` | zostaje (`WordErrorRate` i `ModelBenchmark` przydadzą się w pomiarach) |
| Spotkania: nagrywanie, etykiety mówców (lokalne), wyszukiwanie FTS5, serwer MCP | `Meetings/` poza `AI/` i `Cloud/` | zostaje |
| Uczenie (słownik, pary "słyszy -> znaczy", styl), notatki | `Learning/`, `Notes/` | zostaje, AI przez nową trasę |
| Konto, Pro, przekaźnik | `Account/*` (`AccountClient`, `AccountStore`, `AccountInfo`, `CloudRouter`, `CloudCredential`, `CaptyloAITask`, `AIRoute`) | **wycinamy**; `AIRoute` przepisujemy na trasę lokalną albo chmurową (sekcja 5) |
| OpenRouter | `Enhancement/OpenRouterClient.swift`, `OpenRouterModels.swift` | zastępuje go klient serwera lokalnego zgodny z OpenAI; z OpenRoutera zostaje tylko format zapytań |
| Chmurowa transkrypcja | `Transcription/ElevenLabsSTT.swift`, trasa chmurowa w `TranscriptionRouter`, `Meetings/Cloud/*` | **wycinamy** |
| Aktualizacje | `App/AppUpdater*.swift`, `SUFeedURL` w `Info.plist`, Sparkle w `project.yml` | **wycinamy** (wersje ręcznie z GitHub Releases) |
| Linki do captylo.com/pro, karta wsparcia, karty Pro | `App/SiteLinks.swift`, `UI/Main/SupportCard.swift`, `UI/Main/Account/*`, `UI/Meetings/MeetingProCard.swift`, `MeetingProBanner.swift` | **wycinamy** |
| Klucze chmurowe | `Networking/KeyStore.swift`, "Zaawansowane > własne klucze" w `UI/Main/ModelsView.swift` | zostaje tylko klucz CloudFerro Sherlock (sekcja 7.5) |
| Blokady Pro w funkcjach AI | m.in. `UI/Meetings/MeetingAINotesView`, `MeetingAskView`, `LibraryAskPanel`, `MeetingsView`, `MeetingDetailView`, `UI/Main/HistoryReprocessMenu`, `UI/Notes/NoteDetailView`, `NotesView`, `UI/MenuBar/MenuBarMenu`, `UI/Onboarding/OnboardingSteps` | funkcje AI dostępne zawsze, gdy model jest pobrany |
| AI dyktowania | `Enhancement/Enhancer.swift` (aktor z twardym terminem, `Prewarmer`), `BuiltInAIModes`, `CleanupPrompt` | **zmieniamy trasę** na lokalny serwer; prompty dostrajamy pod Bielika |
| AI spotkań | `Meetings/AI/*`: dziś aplikacja wysyła same dane, a instrukcje trzyma serwer | **instrukcje wracają do aplikacji** jako nowe, otwarte, polskie prompty pod Bielika. Promptów z serwera nie kopiujemy |

## 4. Tożsamość: działa obok Captylo na tym samym Macu

- **Nazwa**: wybiera Dawid na starcie F1. Wymagania (Dawid, 7.11):
  - bez "Offline" i "Lokalnie", bo może dojść Bielik w chmurze;
  - ma nawiązywać do Bielika albo do innego ptaka kojarzonego z szeptem, mową lub dyktowaniem;
  - słowa "Bielik" nie wstawiamy (znak SpeakLeash; regulamin zabrania sugerowania afiliacji, § 3 ust. 2-3), a w opisie piszemy "działa na Bieliku".

  Kandydaci:
  - **Szpak**: szpaki naśladują ludzką mowę;
  - **Pióro**: pióro ptaka i pióro do pisania;
  - **Kruk**: kruki uczą się słów, a kruki Odyna to Myśl i Pamięć.

  Odrzucone: Sowa (afera taśmowa), Słowik (skojarzenia z Pruszkowem). Przed decyzją sprawdzić kolizje: App Store, GitHub, domeny .pl i .app.
- Identyfikatory techniczne ustalamy raz, zaraz po wyborze nazwy, i potem ich nie zmieniamy. Uprawnienia macOS (mikrofon, dostępność, nagrywanie dźwięku) są przypisane do bundle id.
- Wzór identyfikatorów:
  - bundle `com.captylo.<nazwa>` (albo `pl.craftweb.<nazwa>`, decyzja przy nazwie);
  - produkt `<Nazwa>.app`, dane w `~/Library/Application Support/<Nazwa>/`;
  - Keychain i subsystem logów jak bundle, schemat URL `<nazwa>`.
- Domyślny skrót inny niż w Captylo, bo dwie aplikacje z tym samym skrótem się gryzą.
- Ikona: wariant ikony Captylo (np. inny kolor tła), bez logo Bielika.
- Licencja GPLv3 dziedziczona po Captylo. `NOTICE.md` uzupełnione o llama.cpp (MIT) i modele Bielik (Apache 2.0; aplikacja je pobiera, nie dołącza do instalatora).

## 5. Architektura AI

```
<Nazwa>.app
 ├─ Whisper large-v3-turbo (WhisperKit, lokalnie)  ->  surowa transkrypcja
 ├─ Enhancer / Meetings AI  ── klient zgodny z OpenAI (chat/completions) ──┬─> 127.0.0.1:<port>  llama-server + model "korekta"
 │                                                                         ├─> 127.0.0.1:<port>  llama-server + model "funkcje AI"
 │                                                                         └─> (opcja) CloudFerro Sherlock, Bielik 11B, klucz użytkownika
 └─ ModelManager: pobieranie GGUF z huggingface.co/speakleash (bez logowania), sha256, wznawianie, usuwanie
```

- **Silnik (propozycja, do potwierdzenia w F0)**: `llama-server` z llama.cpp dołączony do aplikacji jako helper (przypięty commit, build arm64 z Metal, podpisany i w notaryzacji). Za tym wyborem:
  - są oficjalne pliki GGUF Bielika;
  - API zgodne z OpenAI, więc kod wysyłki i obsługi błędów z `Enhancer` zostaje;
  - pamięć podręczna promptu: prompt systemowy liczy się raz;
  - wymuszony JSON (`json_schema` / GBNF) tam, gdzie potrzebny;
  - osobny proces łatwo zatrzymać i zwolnić RAM.
  Alternatywa: MLX Swift w procesie aplikacji (oficjalny MLX 8-bit istnieje tylko dla 4.5B). Wybieramy ją, jeśli helper nie przejdzie notaryzacji albo startuje za wolno.
- **Cykl życia serwera**:
  - startuje przy pierwszym użyciu, z rozgrzewką przy wciśnięciu skrótu (jak dzisiejszy `Prewarmer`);
  - zwalnia model po 10 min bezczynności (do zmiany w Ustawieniach) i kończy się razem z aplikacją;
  - słucha tylko na 127.0.0.1, na losowym porcie, z tokenem w nagłówku.
- **Terminy**: dzisiejsze stałe limity (czyszczenie 3 s, tryby 6-8 s w `BuiltInAIModes`) są dobrane pod szybką chmurę. Lokalnie czas rośnie z długością odpowiedzi, więc na trasie lokalnej limit też rośnie:
  - wzór: `limit = stała trybu + liczba słów wejścia x czas na słowo zmierzony w F0 x 1,5`;
  - sufit: 15 s dla czyszczenia, 30 s dla trybów;
  - bramka F0 dotyczy typowego dyktowania do 60 słów: p95 korekty najwyżej 3 s na M3 Pro.

  Po przekroczeniu limitu wklejamy surowy tekst. Spotkania liczą się w tle bez limitu, z paskiem postępu.
- **Przenoszalność**: lokalna AI to samodzielny moduł (`Captylo/LocalAI/`: ModelManager, serwer modelu, klient) za protokołem trasy, a wycinanie chmury idzie osobnymi commitami. Dzięki temu tryb lokalny da się później przenieść do głównego Captylo. Poprawek wydanych w Captylo w trakcie sprintu nie przenosimy, chyba że są krytyczne.

## 6. Modele i poziomy

Stan Hugging Face z 7.11.2026: wszystkie modele na licencji Apache 2.0, repozytoria GGUF otwarte bez logowania (`gated: false`).

| Rola | Domyślnie | Repozytorium / plik | Rozmiar | Alternatywy do testu w F0 |
|---|---|---|---|---|
| **Korekta** (dyktowanie, poprawki transkryptu spotkań) | Bielik 1.5B v3.0 Instruct, Q8_0 | `speakleash/Bielik-1.5B-v3.0-Instruct-GGUF` / `Bielik-1.5B-v3.0-Instruct.Q8_0.gguf` | 1,7 GB | Bielik 4.5B v3.0 Q8_0 (5,06 GB) |
| **Funkcje AI** (tryby, własne prompty, notatki, Zapytaj) | Bielik Minitron 7B v3.0 Instruct, Q4_K_M | `speakleash/Bielik-Minitron-7B-v3.0-Instruct-GGUF` / `minitron-Bielik-7B-v3.0-Instruct-GGUF.Q4_K_M.gguf` | 4,5 GB | 4.5B Q8_0 (5,06 GB), Minitron Q5_K_M (5,29 GB) |
| **Chmura** (opcja dla słabszych Maców) | Bielik 11B v3.0 Instruct | CloudFerro Sherlock, `https://api-sherlock.cloudferro.com/openai/v1/`, klucz użytkownika | - | - |

- Okno kontekstu (F0, `n_ctx_train` z serwera): 1.5B ma 8 192 tokeny i własny tokenizer (ok. 3,7 bajta na token po polsku), Minitron 7B ma 32 768 (ok. 2,35 bajta na token), 4.5B ma 32 768. Serwer korekty startuje z `-c 8192`, serwer funkcji AI z `-c 24576` (20 tys. tokenów wejścia i 4 tys. odpowiedzi).
- Minitron 7B Q4_K_M jest mniejszy od 4.5B Q8_0. Do tego jest nowszy (2026) i wg karty modelu zachowuje ok. 90% jakości 11B. Dlatego jest domyślny, a F0 to weryfikuje.
- **Poziomy według RAM** (wykrywane automatycznie, do zmiany w Ustawieniach):
  - **16 GB i więcej**: korekta i funkcje AI lokalnie (1.5B + Minitron 7B).
  - **8 GB**: korekta lokalnie (1.5B). Funkcje AI na Bieliku w chmurze, jeśli użytkownik podał klucz, a bez klucza lokalnie na 1.5B z uczciwym opisem jakości. Minitron jest dostępny z ostrzeżeniem o pamięci.
- **Ważne dla zgłoszenia**: kategoria (c) obejmuje modele poniżej 10B. 11B w chmurze to tylko zapas, a wszystkie liczby w zgłoszeniu pochodzą z modeli lokalnych.

## 7. Wymagania funkcjonalne

**7.1 Pobieranie modeli.**
- Krok onboardingu "Pobierz Bielika" pokazuje rozmiar i wolne miejsce na dysku.
- Pobieranie w tle: wznawianie, anulowanie, sprawdzanie sha256 (wartość `lfs.sha256` z API HF), usuwanie w zakładce Modele.
- Bez pobranego modelu aplikacja działa jak dziś bez AI, czyli wkleja surową transkrypcję.

**7.2 Korekta dyktowania.**
- Obecny tryb "Czyszczenie" działa na modelu korekty.
- `CleanupPrompt` dostrajamy pod Bielika; w F0 porównujemy instrukcje po polsku i po angielsku.
- Słownik i pary z uczenia działają jak dziś.
- Strażnik: odpowiedź modelu jest odrzucana i wklejamy surowy tekst, gdy:
  - długość wypada poza 50-150% wejścia,
  - albo podobieństwo słów spada poniżej progu ustalonego w F0.

**7.3 Funkcje AI.**
- Tryby wbudowane (Po angielsku, Uporządkuj myśli, Mail, Zadania), własne prompty oraz "Przetwórz przez AI" w notatkach i historii działają na modelu funkcji AI.
- Limity według sekcji 5.
- Pozostałe miejsca, które dziś wołają AI, idą tą samą trasą lokalną:
  - profil stylu (`StyleDistiller`): model funkcji AI, w tle;
  - tytuły notatek: model korekty;
  - AI po transkrypcji plików: jak dyktowanie.

**7.4 Spotkania.**
- Poprawki transkryptu na modelu korekty, porcjami.
- Notatki AI według `BuiltInMeetingTemplates` oraz "Zapytaj" o spotkanie i o bibliotekę z cytatami `[mm:ss]` na modelu funkcji AI.
- Nowe polskie prompty w aplikacji (otwarte); format wyjścia zgodny z tym, co dziś czytają `MeetingNotesDocument` i `MeetingCitations`.
- Transkrypt dłuższy niż ok. 20 tys. tokenów dzielimy: notatki z części, potem scalenie.

**7.5 Bielik w chmurze (opcja).**
- W Ustawieniach (Zaawansowane): pole klucza CloudFerro Sherlock i test połączenia.
- Jasna informacja, że tekst idzie wtedy do polskiej chmury. Domyślnie wyłączone.
- Bez naszego pośrednika: klient łączy się wprost z Sherlockiem.

**7.6 Prywatność.**
- Zero telemetrii, zero Sparkle, zero naszych serwerów.
- Ekran "Prywatność" mówi wprost, z czym łączy się aplikacja: huggingface.co przy pobieraniu i Sherlock tylko po włączeniu.

## 8. Liczby do zgłoszenia (pomiary)

- **Zbiór testowy** (decyzja Dawida 7.11: z jego własnej historii Captylo):
  - źródło: lokalna baza Captylo w `~/Library/Application Support/Captylo/` (surowy tekst, wynik Captylo AI, WAV);
  - 40-60 dyktowań różnego typu (maile, notatki, listy, terminy, nazwy własne, liczby, wtrącenia angielskie) plus 2-3 spotkania;
  - bez dyktowań z danymi klientów; kopia poza gitem, nigdy w fixtures;
  - wynik Captylo AI zapisany w historii od razu daje punkt odniesienia, więc nie trzeba niczego wysyłać ponownie;
  - pierwszą ocenę (sens, wzorzec) robi agent, Dawid ślepo ocenia końcowe ok. 30 próbek (ok. 20 min).
  Nic z danych innych użytkowników.
- **Realne użycie** (decyzja Dawida 7.11):
  - od pierwszego działającego builda Dawid używa go na co dzień zamiast Captylo, do tego 1-2 osoby, jeśli się uda;
  - lokalny licznik użycia bez telemetrii: liczba dyktowań, korekt przyjętych i odrzuconych przez strażnika, średni czas, użycie trybów i spotkań;
  - licznik widać w aplikacji, a do zgłoszenia eksportuje się go ręcznie do JSON.
- **Miary**:
  - WER i CER: surowy Whisper wobec tekstu po korekcie (`WordErrorRate.swift` już jest);
  - trafność interpunkcji (F1);
  - odsetek odpowiedzi, które zmieniły sens (ślepa ocena Dawida);
  - czas p50 i p95: korekta i tryby (pierwszy token i całość), notatki dla spotkania 30 i 60 min;
  - szczytowe zużycie RAM i rozmiar na dysku;
  - test "zero sieci" podczas pracy.
- **Punkt odniesienia**: te same próbki przez obecne Captylo, przez przekaźnik Pro na koncie Dawida.
  - W publicznym `docs/benchmark.md` nazywamy go "Captylo AI (chmura)", bez nazwy modelu (zasada open core). Nazwa modelu może się pojawić najwyżej w poufnej części zgłoszenia.
  - Dla spotkań porównujemy wyniki, nie prompty.
- **Maszyny**: M3 Pro 36 GB. Bez Maca z 8 GB nie obiecujemy w zgłoszeniu, że 8 GB działa. Poziom 8 GB jest wtedy oznaczony jako eksperymentalny:
  - korekta lokalnie;
  - funkcje AI domyślnie w chmurze albo na 1.5B;
  - Whisper i Bielik ładowane po kolei.
- **Wynik**: `docs/benchmark.md` i wykresy do PDF zgłoszenia.
- **Dojrzałość**: liczby z wydanego Captylo, czyli instalacje z logów serwera (mechanizm z CAPTYLO-84, bez telemetrii) i konta. Odczyt produkcji tylko po zgodzie Dawida.

## 9. Kryteria odbioru

1. Na czystym Macu: instalacja z DMG, onboarding pobiera modele, a dyktowanie po polsku z korektą działa przy wyłączonym Wi-Fi.
2. `rg` nie znajduje Account, relay, OpenRouter, ElevenLabs, Stripe ani Sparkle. Aplikacja nie łączy się z niczym poza HF (i Sherlockiem, gdy jest włączony).
3. Tryby AI, notatki ze spotkania i Zapytaj działają lokalnie na Minitronie 7B.
4. Przekroczony limit albo awaria serwera modelu kończą się wklejeniem surowego tekstu i komunikatem, bez zawieszenia.
5. `make test` jest zielone: testy chmury usunięte, nowe dla ModelManager, serwera modelu, strażnika korekty i dzielenia spotkań.
6. `docs/benchmark.md` zawiera liczby z sekcji 8.
7. Jest publiczne repo na GitHubie, release z notaryzowanym DMG i README "jak to działa na Bieliku".
8. Teksty zgłoszenia i PDF są gotowe (`docs/bielik-awards.md`).

## 10. Harmonogram

| Faza | Dni | Co | Bramka |
|---|---|---|---|
| F0 | 7-8.11 | Próba: llama-server i 3 modele na M3, wstępny zbiór testowy, decyzje (silnik, modele, język promptów) | korekta na 1.5B nie zmienia sensu w co najmniej 95% próbek i mieści się w 3 s na M3; jeśli nie, korekta idzie na 4.5B |
| F1 | 8-9.11 | Nowa tożsamość, wycięcie chmury, przepisany `AGENTS.md` | build i testy zielone, `rg` czysty |
| F2 | 9-11.11 | ModelManager, serwer modelu, trasy AI, tryby, spotkania, chmura jako opcja | kryteria 1-5 |
| F3 | 11-12.11 | Pomiary, publiczne repo (po popupie), DMG, README | kryteria 6-7 |
| F4 | 13-14.11 | Teksty zgłoszenia, PDF, wysyłka formularza (Dawid) | wysłane 14.11 |

**Cel Dawida (7.11)**: rdzeń (F0-F2) zamknąć jeszcze dziś, z agentami pracującymi równolegle w gałęziach. Daty w tabeli to bufor, nie plan.

Gdy zabraknie czasu, tniemy od końca tej listy. Rdzeń zgłoszenia to dyktowanie i tryby AI.
1. Dyktowanie z korektą i tryby AI.
2. Notatki ze spotkań.
3. Zapytaj o spotkanie i o bibliotekę.
4. Bielik w chmurze.

## 11. Ryzyka

| Ryzyko | Co robimy |
|---|---|
| 1.5B psuje sens albo tłumaczy | strażnik z 7.2 i przejście na 4.5B |
| helper `llama-server` nie przechodzi notaryzacji | MLX Swift w procesie aplikacji |
| za mało pamięci na 8 GB | poziomy z sekcji 6, zwalnianie modelu po bezczynności, opcja chmury |
| spotkanie przekracza 32 tys. tokenów | dzielenie na części i scalenie |
| 8 dni to mało czasu | kolejność cięcia z sekcji 10; agenci pracują równolegle na osobnych modułach |
| znak "Bielik" | tylko "działa na Bieliku", bez logo SpeakLeash w ikonie |

## 12. Decyzje

**Podjęte przez Dawida (7.11.2026)**
- Osobne repo, kopia Captylo.
- Zero naszej chmury, cała AI na Bieliku.
- Korekta na najmniejszym modelu, funkcje AI na mocniejszym.
- Bielik w chmurze jako zapas dla słabszych Maców.
- Wszystko w otwartym kodzie.
- Kategoria (c), zgłaszający CRAFTWEB.

**Podjęte przeze mnie (Dawid może zmienić)**
- Silnik `llama-server`.
- Minitron 7B Q4_K_M jako domyślny model funkcji AI zamiast 4.5B Q8_0.
- Chmura przez klucz użytkownika do CloudFerro Sherlock, bez naszego pośrednika ("zero naszej chmury").
- Bez Sparkle i telemetrii.
- Nowe polskie prompty spotkań zamiast kopiowania serwerowych.
- Po przeglądzie wykonawcy:
  - limity czasu rosnące z długością tekstu (sekcja 5);
  - stała tożsamość techniczna (sekcja 4);
  - anonimowy punkt odniesienia "Captylo AI (chmura)" (sekcja 8);
  - poziom 8 GB eksperymentalny bez testu na sprzęcie (sekcja 8);
  - lokalna AI jako przenoszalny moduł `Captylo/LocalAI/` (sekcja 5);
  - tytuły notatek, `StyleDistiller` i transkrypcja plików na trasie lokalnej (7.3).

**Dawid, 7.11, po przeglądzie wykonawcy**
- realne użycie: Dawid na co dzień, do tego 1-2 osoby, plus lokalny licznik;
- commity w gałęziach roboczych;
- zbiór testowy z jego historii Captylo;
- nazwa nawiązująca do Bielika albo do ptaka kojarzonego z mową, bez "Offline" i "Lokalnie".

**Wynik F0 i decyzje (7.11, M3 Pro 36 GB, llama.cpp v0.9.0, 60 dyktowań Dawida, wzorzec Captylo AI z historii)**
- Bramka z sekcji 10 w pierwotnej postaci nie przeszła: sam 1.5B zmieniał sens w 8-15% próbek nawet na najlepszym prompcie (zmiana osoby, streszczanie, zmiana rodzaju, pętle, wklejanie przykładów).
- Pomiary (dyktowania do 60 słów):
  | Model | p50 | p95 | Zmieniony sens bez strażnika |
  |---|---|---|---|
  | 1.5B Q8_0 | 0,99 s | 1,75 s | 8-15% |
  | 4.5B Q8_0 | 2,33 s | 4,76 s | ok. 5% |
  | Minitron 7B Q4_K_M | 4,4 s | 11 s | ok. 10% |
- Rozwiązanie: nowy polski prompt z dwoma przykładami i transkrypcją w znacznikach `<tekst>` oraz strażnik na poziomie słów (`CorrectionMerger`). Strażnik przepuszcza tylko interpunkcję, wielkie litery, ogonki, drobne literówki ze słownikiem pisowni macOS, terminy ze słownika i usunięte wypełniacze; resztę cofa do oryginału. Z nim sens zostaje w 60/60 próbek, a interpunkcja F1 wobec chmury rośnie z 0,82 do 0,89. Po strażniku 4.5B daje praktycznie to samo co 1.5B (WER wobec chmury 0,181 i 0,183), a jest 2,7 raza wolniejszy.
- Decyzje (Dawid wybrał najpierw test 4.5B, wynik powyżej):
  - korekta domyślnie na 1.5B ze strażnikiem; w Modele można wybrać do korekty 4.5B, Minitrona albo chmurę;
  - funkcje AI na Minitronie 7B (tryby z limitem do 30 s);
  - poprawki transkryptu spotkań na modelu korekty, zawsze przez `TranscriptFixGuard` (bez niego 1.5B psuł 62 z 306 czystych linii).
- Nazwa: **Szpak** (7.11, po sprawdzeniu kolizji; szpak.app wolne). Identyfikatory na stałe: `Szpak.app`, bundle `pl.craftweb.szpak`, dane w `~/Library/Application Support/Szpak/`, schemat URL `szpak`.
- Prywatne repo `dawidkawalec/captylo-bielik` założone 7.11 (zgoda Dawida); publiczne dopiero w F3, po popupie.

**Do Dawida**
1. Ikona Szpaka (wariant ikony Captylo w przygotowaniu).
2. Zgoda na upublicznienie repo na GitHubie (popup przed zmianą widoczności).
3. Czy ogłosić nową wersję użytkownikom Captylo (mail przez `tbsend`, po popupie).
4. Odczyt liczb z produkcji Captylo.

## 13. Zasady pracy w tym repo

- `AGENTS.md` jest źródłem prawdy; w F1 przepisujemy go pod ten fork. Do tego czasu jego treść opisuje stan wyjściowy Captylo.
- Nigdy nie trafiają do repo: kod ani prompty z prywatnego `vocatypecustom/server`, prawdziwe dyktowania w fixtures i na zrzutach, sekrety. Tylko zwykły dywiz "-", nigdy długie myślniki.
- **Commity (decyzja Dawida 7.11, na czas sprintu do 15.11)**:
  - wolno commitować w gałęziach roboczych i worktree tego repo;
  - merge do `main`, utworzenie publicznego repo i każdy push tylko na słowo Dawida (publiczne repo i push po popupie);
  - zero śladów AI w commitach: bez `Co-Authored-By` i bez wzmianek o AI.
- Pliki zmieniamy narzędziami Edit/Write. Bash służy do czytania, gita, buildów i testów.
- Remote `captylo-local` wskazuje na lokalne repo Captylo (do podglądu i cherry-picków); do publicznego `dawidkawalec/captylo` nic nie wypychamy.
