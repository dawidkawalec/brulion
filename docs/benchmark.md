# Brulion na Bieliku: pomiary

Pomiary do zgłoszenia na Bielik Awards 2026 (kategoria c, SLM poniżej 10 mld parametrów). Mierzymy, jak Brulion radzi sobie wtedy, gdy cała warstwa językowa działa na Bieliku na Macu użytkownika: korektę dyktowania, tryby AI, notatki ze spotkań i pytania o spotkanie, a do tego pamięć, dysk i brak ruchu sieciowego.

Punktem odniesienia jest "Captylo AI (chmura)", czyli warstwa AI wydanego Captylo, z którego wyrósł Brulion. Jej wyniki dla tych samych dyktowań są zapisane w historii aplikacji.

## Sprzęt, wersje, metoda

- **Mac:** MacBook Pro M3 Pro (Mac15,7), 36 GB RAM, macOS 26.5.2.
- **Brulion:** 0.9.0, build Release.
- **Silnik:** llama.cpp v0.9.0 (commit `cd959bae`), `llama-server` wbudowany w aplikację, Metal, wszystkie warstwy na GPU.
- **Modele** z oficjalnych repozytoriów SpeakLeash na Hugging Face:

  | Model | Plik | Rola w Brulionie | Kontekst serwera |
  |---|---|---|---|
  | Bielik 1.5B v3.0 Instruct, Q8_0 | 1,70 GB | korekta dyktowania, poprawki transkryptu | 8192 |
  | Bielik Minitron 7B v3.0 Instruct, Q4_K_M | 4,50 GB | tryby AI, notatki, Zapytaj | 24576 |
  | Bielik 4.5B v3.0 Instruct, Q8_0 | 5,06 GB | tylko porównanie w F0 | - |

- **Transkrypcja:** Whisper large-v3 turbo (WhisperKit, Neural Engine), lokalnie, tak samo jak w Captylo.

Pomiary mają dwa poziomy:

1. **F0, serwer:** te same prompty co w aplikacji, wysyłane prosto do `llama-server` ze streamingiem. Mierzy też czas do pierwszego tokenu.
2. **F3, aplikacja:** Brulion.app uruchomiony bez okna, przez flagi `--transcribe` i `--meeting-ai`, na osobnym folderze danych. Każdy wynik przechodzi przez prawdziwe trasy AI, strażnika korekty, limity czasu i helper `llama-server`. W trakcie każdego przebiegu co 0,5 s próbkowaliśmy pamięć procesów (`ps`, `vmmap`) i ich gniazda sieciowe (`lsof`).

## Zbiór testowy

- **60 dyktowań** z własnej historii Captylo autora:
  - bez dyktowań z danymi klientów; zbiór trzymamy poza repozytorium;
  - 12 krótkich, 30 średnich i 18 długich, mediana 32 słowa, najdłuższe 91, razem 1979 słów;
  - typowa praca: maile, notatki, listy, terminy, nazwy własne, liczby i wtrącenia angielskie.
- **Wzorzec:** tekst Captylo AI (chmura), zapisany w historii przy tych samych dyktowaniach.
- **Audio do pomiarów w aplikacji:** oryginalne nagrania wygasły już z historii. Surowy tekst każdego dyktowania przeczytał więc polski głos macOS (Zosia), a aplikacja przepisała go swoim Whisperem. Czasy AI to nie zmienia. Jakość korekty mierzymy na poziomie F0, na prawdziwych transkrypcjach.
- **Spotkania:**
  - fikcyjne: przegląd projektu aplikacji (44 min, 3 osoby), rozmowa z klientem (5 min);
  - publiczne: 30 i 60 minut 67. posiedzenia Sejmu z 21.10.2026 od 9:25. Stenogramy pochodzą z `api.sejm.gov.pl`, mają prawdziwe czasy wystąpień i 23 mówców. Skrypt: [`scripts/benchmark/sejm_meeting.py`](../scripts/benchmark/sejm_meeting.py), więc każdy może pobrać to samo.

## 1. Korekta dyktowania (Bielik 1.5B)

### Jakość (F0, serwer, 60 dyktowań)

WER liczymy wobec tekstu Captylo AI (chmura). Surowy Whisper różni się od niego o 17,6% słów. Interpunkcja F1 to trafność przecinków, kropek i znaków zapytania wobec chmury.

| Wariant | WER wobec chmury | Interpunkcja F1 | Odpowiedzi daleko od surowego tekstu* |
|---|---|---|---|
| Surowy Whisper | 0,176 | 0,82 | - |
| 1.5B, prosty prompt | 0,771 | 0,85 | 18 z 60 |
| 1.5B, prompt Brulionu (polski, 2 przykłady, `<tekst>`) | 0,260 | 0,91 | 3 z 60 |
| **1.5B, prompt Brulionu + strażnik słów** (domyślnie) | **0,183** | **0,89** | **0 z 60** |
| 4.5B, prompt Brulionu + strażnik | 0,181 | 0,90 | 0 z 60 |
| Minitron 7B, prompt Brulionu + strażnik | 0,191 | 0,88 | 0 z 60 |

\* Podobieństwo do surowego tekstu poniżej 0,4, czyli streszczenie, odpowiedź na treść albo pętla zamiast korekty.

**Strażnik słów** (`CorrectionMerger`) przepuszcza tylko:
- interpunkcję i wielkie litery;
- polskie znaki i drobne literówki (słownik pisowni macOS);
- terminy ze słownika użytkownika;
- usunięte wypełniacze ("yyy", "no").

Każdą inną zmianę słowa cofa do oryginału.

Bez strażnika sam 1.5B zmieniał sens w 8-15% dyktowań (zmiana osoby lub rodzaju, streszczanie, pętle). Ze strażnikiem sens został zachowany w 60 z 60 dyktowań (ocena agenta). Ślepa ocena autora na 30 próbkach jest jeszcze do zrobienia.

Cena strażnika jest taka, że lokalna korekta nie robi przeróbek słów, które robi chmura. Poprawia interpunkcję, wielkie litery i polskie znaki, a sensu nie zmienia. Dlatego WER wobec chmury stoi w miejscu, a interpunkcja wyraźnie rośnie. Po strażniku 4.5B daje praktycznie ten sam wynik co 1.5B, a jest 2,7 raza wolniejszy, więc domyślnie korektę robi 1.5B.

### Czas

| Pomiar | p50 | p95 | Uwagi |
|---|---|---|---|
| F0, serwer, 1.5B, do 60 słów | 0,99 s | 1,75 s | pierwszy token p50 0,07 s, generowanie ok. 47 tok/s |
| F0, serwer, 4.5B, do 60 słów | 2,33 s | 4,76 s | pierwszy token 0,18 s |
| F0, serwer, Minitron 7B, do 60 słów | 4,37 s | 11,06 s | pierwszy token 0,41 s |
| **F3, aplikacja, 1.5B, do 60 słów** (rozgrzany serwer) | **1,37 s** | **2,49 s** | z HTTP i strażnikiem, 52 dyktowania |
| F3, aplikacja, 1.5B, wszystkie (rozgrzany) | 1,42 s | 4,01 s | 59 dyktowań, najdłuższe 91 słów |
| F3, aplikacja, 1.5B, zimny start | 1,30 s | 2,47 s | 6 dyktowań, każde w nowym procesie; serwer startuje razem z nagrywaniem |
| F3, od puszczenia klawisza do tekstu (Whisper + korekta) | 2,77 s | 6,79 s | 59 dyktowań |
| Captylo AI (chmura), do 60 słów | 0,80 s | 1,82 s | z historii, te same dyktowania |

W aplikacji korekta dała wynik w 60 z 60 dyktowań: ani jednego przekroczenia limitu czy awarii serwera. Bramka z PRD (p95 do 3 s dla dyktowań do 60 słów na M3 Pro) jest spełniona: 2,49 s.

## 2. Tryby AI (Bielik Minitron 7B)

Trzy tryby wbudowane, każdy na tych samych 12 dyktowaniach (po 4 krótkie, średnie i długie, od 5 do 104 słów), wszystkie w jednym procesie. Pierwsze dyktowanie trafia na zimny serwer, kolejne na rozgrzany.

| Tryb | Bez wyniku AI, limit 3 s + słowa | **Bez wyniku AI, limit 10 s + słowa** | Czas AI p50 / p95 | Od puszczenia klawisza do tekstu p50 / p95 |
|---|---|---|---|---|
| E-mail | 2 z 12 | **0 z 12** | 10,1 s / 20,3 s | 11,8 s / 22,9 s |
| Lista zadań | 4 z 12 | **1 z 12** | 10,7 s / 18,0 s | 11,8 s / 20,6 s |
| Uporządkuj myśli | 3 z 12 | **2 z 12** | 10,3 s / 24,9 s | 12,3 s / 27,5 s |

- **Czas zależy od długości odpowiedzi, nie dyktowania:** ok. 2 s plus ok. 0,2 s na każde słowo odpowiedzi. E-mail z pięciu słów potrafi mieć 44 słowa.
- **Limit:** pierwszy pomiar z limitem "3 s + słowa wejścia × 0,23 s × 1,5" zostawił bez wyniku 9 z 36 krótkich dyktowań. Po podniesieniu stałej do 10 s (sufit dalej 30 s) zostały 3 z 36, w tym przypadki, w których model sam się rozgadał. Po przekroczeniu limitu Brulion wkleja surowy tekst z komunikatem, nic się nie zawiesza.
- **Zimny start:** pierwsze dyktowanie trwało 3,0-7,5 s, bo serwer Minitrona startuje razem z nagrywaniem, a krótkie dyktowanie daje mu mało czasu na wczytanie modelu.

Brulion nie streamuje odpowiedzi do okna, tylko wkleja cały tekst naraz. Dla użytkownika liczy się więc czas całości, a nie pierwszego tokenu. Na serwerze Minitron ma pierwszy token po 0,41 s (p50), przetwarza prompt z prędkością ok. 212 tok/s i generuje ok. 18 tok/s.

## 3. Spotkania

Po zakończeniu spotkania wszystko liczy się w tle, bez limitu czasu i z paskiem postępu. Kolejność: poprawki transkryptu na 1.5B, potem notatki na Minitronie. Zapytaj działa na żądanie, na Minitronie.

| Spotkanie | Długość, słowa | Poprawki transkryptu (1.5B) | Notatki AI (Minitron) | Zapytaj (Minitron) |
|---|---|---|---|---|
| Fikcyjne, przegląd projektu | 44 min, 3396 | 202 s, 0 zmienionych linii* | 178 s, 1 wywołanie, 422 słowa | 141 s, 142 s, 35 s (3 pytania) |
| Sejm, 30 min | 30 min, 3071 | - | 118 s, 1 wywołanie | 119 s, 54 s (2 pytania) |
| Sejm, 60 min | 60 min, 5818 | - | 358 s, 3 wywołania (2 części + scalenie) | odmowa: spotkanie za długie na jedno pytanie |
| Fikcyjne, rozmowa z klientem (bez sieci) | 5 min, 535 | 28 s, 0 zmienionych linii* | 64 s, 1 wywołanie | 41 s (1 pytanie) |

\* Fikcyjne transkrypty są czyste, więc strażnik linii (`TranscriptFixGuard`) nie miał czego poprawiać. Na zaszumionych próbkach z F2 bez strażnika 1.5B zepsuł 62 z 306 czystych linii, a ze strażnikiem żadnej.

- **Notatki:** godzina rozmowy daje notatki po ok. 6 minutach, 30-44 minuty po 2-3 minutach. Notatki mają podsumowanie, decyzje, zadania z osobami i terminami oraz otwarte pytania, a każdy punkt ma cytat `[mm:ss]` do odsłuchania.
- **Zapytaj:**
  - czas zależy głównie od długości odpowiedzi (80-440 słów); przetworzony transkrypt serwer trzyma w pamięci podręcznej między pytaniami;
  - odpowiedzi mają cytaty `[mm:ss]`;
  - spotkania dłuższe niż budżet ok. 20 tys. tokenów (gęsta rozmowa powyżej ok. 45 minut) Zapytaj na razie odrzuca z komunikatem i odsyła do notatek.
- **Poprawki transkryptu:** 1.5B przepisuje transkrypt porcjami, więc 44 minuty zajmują ok. 3,5 minuty w tle.

## 4. Pamięć i dysk

| Proces | Plik na dysku | RAM, szczyt (RSS) | w tym pamięć robocza (footprint) |
|---|---|---|---|
| `llama-server` z Bielikiem 1.5B (`-c 8192`) | 1,70 GB | 2,0 GB | 0,40-0,42 GB |
| `llama-server` z Minitronem 7B (`-c 24576`) | 4,50 GB | 8,3-8,45 GB | 4,0-4,4 GB |
| Brulion (aplikacja z Whisperem) | 59 MB aplikacja + 1,5 GB model Whispera | 0,1-0,3 GB, chwilowo do 1,35 GB przy ładowaniu Whispera | - |

- **RSS** obejmuje zmapowany plik modelu, który macOS może zwolnić bez swapu. **Footprint** to pamięć robocza: KV cache i bufory Metal.
- **Wymagania:** pełna lokalna AI to Mac z Apple Silicon i co najmniej 16 GB RAM oraz ok. 7,2 GB wolnego miejsca (6,2 GB modeli plus 1 GB zapasu przy pobieraniu). Poniżej 16 GB działa tryb eksperymentalny: korekta lokalnie, a funkcje AI na 1.5B albo na Bieliku w chmurze, na kluczu użytkownika do CloudFerro Sherlock. Nie testowaliśmy go na Macu z 8 GB, więc w zgłoszeniu go nie obiecujemy.
- **Modele w pamięci:** serwer modelu zwalnia pamięć po 10 minutach bezczynności (do zmiany w ustawieniach) i kończy się razem z aplikacją. Przy żadnym z pomiarów `llama-server` nie został w tle.
- **Mac z 16 GB (decyzja 8.11):** plan pamięci przyjmuje zmierzone 8,45 GB dla Minitrona. 1.5B i Minitron razem (10,75 GB) nie mieszczą się w budżecie Maca z 16 GB (60% RAM, 10,3 GB), więc na takim Macu modele działają po kolei: gdy startuje Minitron, serwis zatrzymuje 1.5B, a następne dyktowanie czeka ok. 1-2 s na jego ponowne wczytanie. Od 24 GB oba modele zostają w pamięci.

## 5. Zero sieci

- **Gniazda:** w każdym przebiegu F3 (ok. 150 dyktowań i 4 spotkania) aplikacja i `llama-server` miały otwarte tylko połączenia z 127.0.0.1. Helper słucha na losowym porcie, a żądania niesie token.
- **Klatka bez internetu:** te same zadania przeszły pod `sandbox-exec`, z profilem blokującym wszystkie połączenia wychodzące poza localhost:
  - korekta 6 z 6;
  - tryb e-mail 3 z 3;
  - spotkanie od początku do końca: poprawki, notatki i Zapytaj.

  Kontrola: w tej samej klatce `curl` do huggingface.co nie łączy się wcale.
- **Z czym łączy się Brulion:** z huggingface.co tylko przy pobieraniu modeli, a z CloudFerro Sherlock tylko wtedy, gdy użytkownik sam go włączy i poda klucz. Nie ma telemetrii, automatycznych aktualizacji ani naszego serwera.
- **Do zrobienia:** test na czystym Macu, czyli instalacja z DMG, pobranie modeli w onboardingu i dyktowanie po polsku przy wyłączonym Wi-Fi.

## 6. Realne użycie

Brulion liczy lokalnie, bez telemetrii:
- dyktowania;
- korekty przyjęte i odrzucone przez strażnika;
- średni czas;
- użycie trybów i spotkań.

Licznik widać w aplikacji, a do zgłoszenia eksportuje się go ręcznie do JSON. Liczby z codziennego używania przez autora dopiszemy przed wysłaniem zgłoszenia.

## Jak powtórzyć

```bash
# osobny folder danych z modelami (dowiązania), żeby nie mieszać pomiarów z własnym licznikiem użycia
mkdir -p ~/brulion-bench
ln -s ~/Library/Application\ Support/Brulion/LocalModels ~/brulion-bench/LocalModels
ln -s ~/Library/Application\ Support/Brulion/WhisperModels ~/brulion-bench/WhisperModels
APP=/Applications/Brulion.app/Contents/MacOS/Brulion

# dyktowania: kilka plików w jednym procesie (pierwszy to zimny start), tryb na jedno uruchomienie
BRULION_DATA_DIR=~/brulion-bench $APP --transcribe a.wav b.wav --mode cleanup --language pl -ai.enabled YES
BRULION_DATA_DIR=~/brulion-bench $APP --transcribe a.wav b.wav --mode email --language pl -ai.enabled YES

# spotkania: transkrypt z posiedzenia Sejmu, poprawki, notatki i pytania
python3 -I scripts/benchmark/sejm_meeting.py 10 67 2026-10-21 09:25 60 sejm-60.json
BRULION_DATA_DIR=~/brulion-bench $APP --meeting-ai sejm-60.json --fix --ask "Jakie stanowiska przedstawiły kluby?" -ai.enabled YES
```

- `-ai.enabled YES` włącza AI tylko dla tego jednego procesu (argument domeny ustawień macOS).
- Format wyjścia obu flag opisuje [docs/architecture.md](architecture.md), w sekcji "Debug CLI flags".
- Zbiór 60 dyktowań i skrypty F0 zostają poza repozytorium, bo zawierają prywatne dyktowania autora.
