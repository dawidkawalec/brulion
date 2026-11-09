# Bielik Awards 2026 - zgłoszenie Brulionu

Gotowe pola formularza https://www.bielik.ai/konkurs-bielik-awards-2026 (stan formularza sprawdzony 9.11.2026). Kontekst, regulamin i kryteria: [bielik-awards.md](bielik-awards.md). Liczby pochodzą wyłącznie z [benchmark.md](benchmark.md). Zgłoszenie nie ma fragmentów poufnych: całą treść można opublikować.

Formularz wysyła Dawid (zgłoszenie tylko we własnym imieniu, reCAPTCHA, trzy zgody). Przed wysłaniem: publiczne repo i wydanie z DMG Brulionu, bo oba teksty odsyłają do kodu i instalatora.

## 01 Kategoria

Najlepsze użycie modelu SLM (<10B)

## 02 Zgłaszający

| Pole | Wartość |
|---|---|
| Typ zgłaszającego | Przedsiębiorca |
| Nazwa podmiotu | CRAFTWEB Sp. z o.o. |
| NIP | 7842535739 |

## 03 Osoba upoważniona

| Pole | Wartość |
|---|---|
| Imię i nazwisko | Dawid Kawalec |
| Stanowisko | Prezes Zarządu |
| E-mail | info@craftweb.pl |
| Telefon | wpisuje Dawid (pole wymagane, numeru nie trzymamy w repo) |

## 04 Projekt

**Nazwa projektu:** Brulion

**Prezentacja:** https://kawalec.pl/brulion/brulion-bielik-awards-2026.pdf (PDF, bez logowania, ma działać do 26.11.2026)

### Krótki opis (100-1500 znaków)

<!-- krotki:start -->
Brulion to aplikacja na Maca do dyktowania i notatek ze spotkań po polsku, w której cała warstwa językowa działa na Bieliku, lokalnie na komputerze użytkownika. Przytrzymujesz klawisz i mówisz: Whisper zamienia mowę na tekst, Bielik 1.5B dokłada interpunkcję, wielkie litery i polskie znaki, a gotowy tekst ląduje przy kursorze w dowolnej aplikacji. Opcjonalnie Bielik Minitron 7B pisze z dyktowania maile i listy zadań oraz inne definiowane promptem edycje nagrania, robi notatki ze spotkań z cytatami [mm:ss] i odpowiada na pytania o rozmowy. Oba modele działają w llama.cpp na GPU Maca, bez konta, abonamentu i wysyłania tekstu w sieć.

Pomiary na MacBooku Pro M3 Pro i 60 prawdziwych dyktowaniach: korekta trwa 1,37 s (mediana dla dyktowań do 60 słów), trafność interpunkcji rośnie z 0,82 do 0,89, a nasz strażnik słów sprawia, że mały model nie zmienia sensu (60 z 60 dyktowań). Godzina rozmowy daje notatki po ok. 6 minutach. W trakcie pracy aplikacja łączy się tylko z 127.0.0.1, co sprawdziliśmy też w klatce bez internetu.

Brulion wyrósł z wydanego Captylo. Ma otwarty kod (GPLv3), podpisany i poświadczony przez Apple instalator oraz publiczne, powtarzalne pomiary. Pokazuje, że do codziennej pracy z polskim tekstem wystarczą małe modele na własnym sprzęcie.
<!-- krotki:end -->

### Szczegółowy opis projektu i efektów wdrożenia (300-8000 znaków)

Pole formularza to zwykły tekst, więc nagłówki są wersalikami, a listy zaczynają się od dywizu.

<!-- szczegolowy:start -->
PROBLEM I KONTEKST
Dyktowanie to najszybszy sposób pisania na komputerze, ale po polsku zwykle oznacza wysyłanie głosu i tekstu do dużych chmur poza Europą. Sama transkrypcja też nie wystarcza: nie ma przecinków ani wielkich liter, za to są "yyy" i błędne formy. We wrześniu 2026 wydaliśmy Captylo, aplikację do dyktowania i notatek ze spotkań na Maca. Mowa zostawała tam na komputerze (Whisper), ale korekta i funkcje AI szły do chmury. Brulion sprawdza, czy tę samą pracę wykonają małe polskie modele na komputerze użytkownika.

CO WDROŻYLIŚMY
Brulion to fork Captylo 1.0.17. Usunęliśmy konto, płatności, przekaźnik AI, chmurową transkrypcję i automatyczne aktualizacje, a całą warstwę językową przenieśliśmy na Bielika:
- Bielik 1.5B v3.0 Instruct (Q8_0, 1,7 GB): korekta dyktowania i poprawki transkryptu spotkań.
- Bielik Minitron 7B v3.0 Instruct (Q4_K_M, 4,5 GB): tryby AI (e-mail, lista zadań, uporządkuj myśli, angielski, własne polecenia), notatki ze spotkań i "Zapytaj" o jedno spotkanie albo o wszystkie.
- Whisper large-v3 turbo na Neural Engine: mowa na tekst.
Modele działają w llama-server z llama.cpp (przypięta wersja, Metal), dołączonym do aplikacji jako podpisany helper. Serwer słucha tylko na 127.0.0.1, na losowym porcie i z tokenem, startuje razem z nagrywaniem i zwalnia pamięć po 10 minutach bezczynności. Modele pobieramy z oficjalnych repozytoriów SpeakLeash na Hugging Face i sprawdzamy sumą SHA-256. Od 16 GB RAM obie role działają lokalnie, na słabszych Macach jest tryb eksperymentalny. Opcjonalnie można włączyć Bielika 11B w polskiej chmurze (CloudFerro Sherlock, PCSS AI HUB) na własnym kluczu, bez naszego pośrednika. Wszystkie liczby w zgłoszeniu pochodzą z modeli lokalnych.

DLACZEGO MAŁE MODELE
Dobraliśmy rozmiar modelu do zadania, zamiast jednego dużego do wszystkiego. Korekta musi być gotowa chwilę po puszczeniu klawisza, więc robi ją 1.5B: pierwszy token po 0,07 s, ok. 47 tokenów na sekundę. Dłuższe treści (mail, notatki z godzinnej rozmowy, pytania o spotkanie) wymagają większego okna i lepszego rozumienia, więc idą do Minitrona 7B z kontekstem 24 576 tokenów. Efekt: praca bez internetu, 0 zł za użycie, brak limitów i tajemnica rozmów, bo nagrania, transkrypty i notatki nie opuszczają komputera.

EFEKTY W LICZBACH
MacBook Pro M3 Pro, 36 GB RAM. Zbiór: 60 prawdziwych dyktowań autora, bez danych klientów. Punkt odniesienia: wyniki chmurowego AI Captylo dla tych samych dyktowań.
- Korekta (1.5B) w aplikacji, dyktowania do 60 słów: mediana 1,37 s, 2,49 s w 95% przypadków. Chmura Captylo jest szybsza (0,80 s i 1,82 s). Od puszczenia klawisza do tekstu razem z Whisperem: mediana 2,77 s.
- Jakość: trafność interpunkcji (F1) rośnie z 0,82 (surowy Whisper) do 0,89. Odpowiedzi daleko od dyktowania (streszczenie, odpowiedź na treść, pętla): 18 z 60 przy prostym prompcie, 3 z 60 przy naszym, 0 z 60 ze strażnikiem słów. Sens zachowany w 60 z 60 dyktowań.
- Po strażniku Bielik 4.5B daje praktycznie to samo co 1.5B (WER wobec chmury 0,181 i 0,183), a jest 2,7 raza wolniejszy, dlatego domyślny jest najmniejszy model.
- Tryby AI (Minitron 7B): mediana ok. 10 s. Po dostrojeniu limitu czasu 3 z 36 dyktowań skończyło się wklejeniem surowego tekstu.
- Spotkania: notatki z 30-44 minut rozmowy po 2-3 minutach, z godziny po ok. 6 minutach (długi transkrypt dzielimy na części i scalamy). Testowaliśmy też na publicznych stenogramach Sejmu z 23 mówcami, które każdy pobierze naszym skryptem.
- Pamięć: serwer z 1.5B 2,0 GB (0,4 GB pamięci roboczej), z Minitronem 8,3-8,45 GB. Dysk: 6,2 GB modeli.
- Sieć: w ok. 150 dyktowaniach i 4 spotkaniach tylko połączenia z 127.0.0.1. Te same zadania przeszły w klatce sandbox-exec, która blokuje każde połączenie poza localhost.

ORYGINALNOŚĆ
W naszym przeglądzie rynku nie znaleźliśmy polskiej aplikacji do dyktowania ani notatnika spotkań, który działa lokalnie na Bieliku. Kluczowy pomysł to strażnik słów. Sam 1.5B zmieniał sens w 8-15% dyktowań (zmiana osoby, streszczenie, pętle). Zamiast przechodzić na większy model, porównujemy odpowiedź z transkrypcją słowo po słowie i przepuszczamy tylko interpunkcję, wielkie litery, polskie znaki, drobne literówki (słownik pisowni macOS), terminy ze słownika użytkownika i usunięte wypełniacze. Każdą inną zmianę cofamy. Dzięki temu najmniejszy Bielik poprawia tekst i nie dopisuje treści. Podobny strażnik linii pilnuje poprawek transkryptu spotkań: bez niego 1.5B psuł 62 z 306 czystych linii, z nim żadnej. Do tego nowe polskie prompty pisane pod Bielika oraz "Zapytaj" o długie spotkanie, które zamiast odmowy wysyła notatki i fragmenty pasujące do pytania.

JAKOŚĆ TECHNICZNA
- Natywna aplikacja w Swift i SwiftUI, ok. 51 tys. linii i ok. 1350 testów automatycznych. Lokalna AI to osobny moduł, który przeniesiemy do Captylo.
- Limity czasu rosną z długością tekstu. Po przekroczeniu albo awarii serwera aplikacja wkleja surowy tekst z komunikatem, nic się nie zawiesza. W pomiarach korekta przeszła 60 z 60 bez przekroczenia i awarii.
- Plan pamięci oparty na zmierzonym zużyciu: na Macu z 16 GB modele działają po kolei, od 24 GB oba zostają w pamięci.
- Pobieranie modeli ze wznawianiem i sumą SHA-256, okno kontekstu dobrane do modelu (8 192 i 24 576 tokenów).
- Lokalny licznik użycia bez telemetrii: dyktowania, korekty przyjęte i odrzucone, czasy. Eksport ręczny do JSON.
- Powtarzalne pomiary: tryb bez okna przechodzi przez prawdziwe trasy aplikacji, a metoda i tabele są w repozytorium.

DOJRZAŁOŚĆ WDROŻENIA
Brulion stoi na wydanej aplikacji (Captylo: podpis Developer ID, notaryzacja Apple, użytkownicy od września 2026), a nie na prototypie. Ma podpisany i poświadczony przez Apple instalator razem z helperem llama-server, otwarty kod na GPLv3, stronę z pomiarami, przewodnik pierwszego uruchomienia, który pobiera modele dobrane do Maca, i instrukcję budowania. Działa obok Captylo, z osobnymi danymi.

LINKI
- Strona: https://kawalec.pl/brulion/
- Kod: https://github.com/dawidkawalec/brulion
- Pomiary: https://github.com/dawidkawalec/brulion/blob/main/docs/benchmark.md
<!-- szczegolowy:end -->

## 05 Oświadczenia i zgody

Trzy pola wymagane: akceptacja regulaminu, przetwarzanie danych osobowych (RODO art. 6 ust. 1 lit. a) i publikacja wyników oraz materiałów promocyjnych (§ 10 ust. 3 lit. b). Zaznacza Dawid.

## Po wysłaniu

- Zrzut potwierdzenia zapisać jako `docs/bielik-awards-potwierdzenie.png`.
- PDF i strona muszą działać do 26.11.2026.
