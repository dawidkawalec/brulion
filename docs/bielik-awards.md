# Bielik Awards 2026 - co musimy oddać

Źródła: https://www.bielik.ai/konkurs-bielik-awards-2026 oraz regulamin (PDF) https://www.bielik.ai/assets/awards/regulamin-bielik-awards-2026.pdf (wersja z 28.10.2026). Stan na 7.11.2026.

## Najważniejsze z regulaminu

- **Organizator**: Fundacja SpeakLeash; nagrody funduje Deviniti Sp. z o.o.
- **Terminy**: zgłoszenia do **15.11.2026, 23:59**, ocena 16-17.11, laureaci dowiadują się do 20.11, ogłoszenie i statuetki 26.11.2026 na Bielik Summit (Muzeum Wojska Polskiego, Warszawa).
- **Nasza kategoria (c)**: "Najlepsze użycie modelu SLM (<10B), dla wdrożenia opartego o model SLM (np. Gemma, Qwen, Mistral, Bielik), pokazującego wartość mniejszych modeli, w tym instalacji on premise i on device". Nagroda 7 500 zł brutto i statuetka. Spółka dostaje kwotę w całości jako przychód.
- **Kryteria oceny (§ 7 ust. 2)**:
  - a) realna wartość i umiejętność wykazania efektów (oszczędność, jakość, czas, satysfakcja, KPI);
  - b) oryginalność i innowacyjność;
  - c) jakość techniczna;
  - d) dojrzałość wdrożenia.
- **Komisja**: Sebastian Kondracki, Sonia Staniek, Waldemar Boszko, Krzysztof Ociepa, Adrian Gwoździej. W składzie są twórcy Bielika, więc docenią szczegóły techniczne (kwantyzacja, okno kontekstu, pomiary).
- **Zgłaszający**: CRAFTWEB Sp. z o.o. Zgłoszenia składa się tylko we własnym imieniu.
- **Licencja dla organizatora**: niewyłączna, na 5 lat, na treść zgłoszenia (§ 9 ust. 1). Fragmenty oznaczone jako poufne widzi tylko komisja (§ 9 ust. 4), np. liczby z produkcji Captylo.
- **Gala**: udział oznacza zgodę na utrwalenie wizerunku (§ 9 ust. 2). Dawid jedzie.
- Limitu zgłoszeń na podmiot nie ma.

## Formularz (pola)

| Pole | Limit | Uwagi |
|---|---|---|
| Kategoria | - | (c) SLM <10B |
| Typ zgłaszającego, nazwa, NIP | - | przedsiębiorca, CRAFTWEB Sp. z o.o., NIP z `oferty-umowy-etc/data/company.yaml` |
| Osoba upoważniona: imię i nazwisko, stanowisko, e-mail, telefon | - | Dawid Kawalec, info@craftweb.pl |
| Nazwa projektu | - | **Brulion** (decyzja 9.11, PRD sekcje 4 i 12; mówisz na brudno, dostajesz na czysto); w opisie "działa na Bieliku" |
| Krótki opis | **100-1500 znaków** | publikowany, idzie do kapituły |
| Szczegółowy opis | **300-8000 znaków** | wdrożenie, kontekst, efekty; fragmenty poufne oznaczyć |
| Prezentacja (opcjonalnie) | link do PDF/PPTX | publiczny, bez logowania, aktywny do 26.11.2026 |
| Zgody | - | regulamin, dane osobowe, publikacja |

## Lista do oddania

Gotowe pola formularza: [bielik-awards-zgloszenie.md](bielik-awards-zgloszenie.md).

- [ ] Wydanie publiczne: repo na GitHubie (GPLv3) i release z notaryzowanym DMG Brulionu (Ster t578); oba teksty i PDF odsyłają do kodu i instalatora
- [x] `docs/benchmark.md` z liczbami (PRD sekcja 8); wykresy są w PDF
- [x] Krótki opis: 1211 z 1500 znaków (9.11)
- [x] Szczegółowy opis: 6153 z 8000 znaków, bez fragmentów poufnych (9.11)
- [x] PDF prezentacji, 8 stron: źródło `docs/awards/prezentacja.html`, render `scripts/render-awards-pdf.sh`, plik `site/brulion-bielik-awards-2026.pdf`, adres https://kawalec.pl/brulion/brulion-bielik-awards-2026.pdf (musi działać do 26.11)
- [ ] Opcjonalnie film demo 60-90 s (promo-kit), link w PDF
- [ ] Opcjonalnie liczby z licznika użycia (eksport JSON z aplikacji) dopisane do szczegółowego opisu przed wysłaniem
- [ ] Formularz wysłany przez Dawida 14.11 i zrzut potwierdzenia zachowany w `docs/`

## Szkielet szczegółowego opisu (pod kryteria)

1. **Problem i kontekst**: dyktowanie i notatki ze spotkań po polsku zwykle wysyłają głos i tekst do amerykańskich chmur. Captylo (wydane we wrześniu 2026) dyktowało lokalnie Whisperem, ale AI szło do chmury.
2. **Co zrobiliśmy (wdrożenie)**:
   - cała warstwa językowa na Bieliku na Macu użytkownika;
   - 1.5B do korekty, Minitron 7B do funkcji AI i spotkań;
   - llama.cpp z akceleracją Metal, modele pobierane z oficjalnych repozytoriów SpeakLeash;
   - zero połączeń w pracy.
3. **Dlaczego mały model (wartość SLM)**: czas korekty, praca offline, 0 zł za użycie, tajemnica rozmów, dobór modelu do RAM (8 i 16 GB).
4. **Efekty w liczbach (kryterium a)**: WER i interpunkcja przed i po korekcie, odsetek zachowanego sensu, czas p50/p95, RAM, porównanie z modelem chmurowym. Do tego liczby z Captylo (poufne, jeśli trzeba).
5. **Oryginalność (kryterium b)**: pierwsza polska aplikacja do dyktowania i notatek ze spotkań na Bieliku (zgodnie z naszym researchem konkurencji); własne prompty spotkań pod Bielika; poziomy modeli według RAM.
6. **Jakość techniczna (kryterium c)**:
   - architektura: serwer zgodny z OpenAI na 127.0.0.1;
   - twarde limity czasu i strażnik sensu;
   - dzielenie długich spotkań;
   - testy, otwarty kod.
7. **Dojrzałość (kryterium d)**: podpisane i notaryzowane wydanie, baza w produkcyjnym Captylo, publiczne repo, instrukcja.
8. **Co dalej**: włączenie trybu lokalnego do głównego Captylo, kolejne modele Bielika, Bielik-Guard.

## Szkielet krótkiego opisu (do 1500 znaków)

Dwa-trzy zdania o produkcji (co robi, dla kogo), jedno o Bieliku (które modele, lokalnie, bez chmury), jedno z najmocniejszą liczbą z pomiarów, jedno o otwartym kodzie i wydaniu.
