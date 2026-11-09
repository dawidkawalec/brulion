# Landing page (`site/`)

The product page of Brulion, made for the Bielik Awards entry and the DMG download (Plane CAPTYLO-106). One static Polish page: plain HTML, CSS and two small scripts, no build step, no dependencies.

```
site/
  index.html              the whole page (copy, meta, JSON-LD, the inline mark)
  assets/css/site.css     tokens (Bielik palette of the app), layout, the notebook demo
  assets/js/grainient.js  the Grainient fields (one shared WebGL2 context, "Ciemny" palette of the app)
  assets/js/site.js       header, mobile menu, notebook demo, use case tabs, "how it works" steps, measurements rail
  assets/fonts/           Geologica Bold (wordmark) and Inter, woff2 subsets (Latin with Polish), OFL texts
  assets/img/             app screenshots (webp), the author's portrait, brand files copied from docs/brand/
  brulion-bielik-awards-2026.pdf   the contest presentation, rendered from docs/awards/ (see docs/bielik-awards-zgloszenie.md)
```

Preview: `cd site && python3 -m http.server 8765`, then http://127.0.0.1:8765/.

## Design

- Layout language after the Mosa AI template the owner picked on 2026-11-09 (rebuilt in our own code, no files of the paid template): a black page (#0B0B09), a framed full-height hero, a pill navigation and joined mono buttons, mono labels with a dot, two-tone headings (white, then 42 % white), framed fields with floating UI mocks, tabs, a step list on a vertical line, a 3 x 2 card grid, a card rail, plan cards, framed FAQ, a closing field and a column footer. The template's landscape photos are our animated Grainient; its testimonials are our measurements (no invented quotes); its logo wall is a grid of the open projects, names only.
- Type: Inter Regular for headings and text, the system monospace (SF Mono on a Mac) for labels, navigation, buttons and card titles, Geologica Bold only for the "brulion" wordmark.
- Section order: hero, Brulion w skrócie (three tiles), Spotkania (tabs with screenshots), Jak to działa, Funkcje, Pomiary, Otwarty kod, Prywatność (three cards for "Gdzie działa Bielik"), Pobierz, Pytania, Autor, the closing field, Skąd nazwa (at the very bottom, the owner's wish), footer.
- The hero notebook stays the signature motion: a Polish squared sheet with a red margin, the raw dictation appears word by word in graphite while the app's recorder widget records, then Bielik "corrects in red pen" (punctuation, capitals, struck fillers) and the clean text is pasted whole below, with a line that counts the changes. It plays once when it comes into view; the tabs and the replay button play it again; Reduce Motion shows the finished example.
- The examples in `site.js` (`EXAMPLES`) are invented and follow the word guard: a token may only gain punctuation, a capital or a Polish letter, or be a dropped filler. Never swap a word for another one there.
- Grainient fields: every `[data-grainient]` element with a `<canvas class="grainient">` child (hero, the three tiles, the use case stage, the "how it works" stage, the closing field). One WebGL2 context renders the visible ones into their own 2D canvases; options `data-seed`, `data-zoom`, `data-cx`, `data-cy`. The "how it works" steps advance by themselves while on screen until the visitor picks one.
- Hero: the app's own "Zmierzch" photo (`hero-zmierzch.webp`, from `Brulion/Resources/Assets.xcassets/DuskWallpaper`, our dusk lake graded to the Bielik palette, no stock) with the Grainient over it in `mix-blend-mode: screen` at 55 %, and a darker scrim on the text side. The copy and the notebook are centred on one line; "Działa na" sits under the buttons.
- Left-right sections (Spotkania, Jak to działa, Pobierz, Pytania, Autor, Skąd nazwa) are top-aligned on wide screens and their left column is `position: sticky` (top 104 px), so the right column can grow. Below 1101 px they stack and nothing sticks.
- The author section uses Dawid's portrait from omniralab.com (`zesp-dawid.jpg` in `~/clienty/omniralab/www/public/media/`, his choice on 2026-11-09), saved as `dawid-kawalec.webp`; the copy is first person.
- Contrast is checked to WCAG AA. Lighthouse mobile on 2026-11-09 after the redesign: accessibility, best practices and SEO 100.

## Content rules

- Numbers come from [benchmark.md](benchmark.md) only, for the local models under 10B. Never claim the local model matches the cloud: the table says the Captylo cloud is faster.
- Wording "działa na Bieliku"; Bielik is SpeakLeash's mark and never part of the product name. The footer says Brulion is not a SpeakLeash product.
- No external requests: fonts are self-hosted, no analytics, no cookies, no storage. The privacy section says so; keep it true.
- Only the plain hyphen "-", never long dashes.

## Refreshing assets

- Screenshots come from the design preview (invented data, nothing from the real data folder), for example `SNAP_BACKDROP=dusk BRULION_PREVIEW_TAB=ai scripts/snap.sh main-spotkania out.png`, then `cwebp -q 80`. Avoid full `main-modele` captures: that screen shows this Mac's RAM and disk.
- Fonts: `python3 -m fontTools.subset Brulion/Resources/Fonts/<face>.ttf --unicodes="U+0020-007E,U+00A0-00FF,U+0100-017F,U+2010-2011,U+2018-201E,U+2022,U+2026,U+20AC,U+2190-2193,U+2212,U+2303,U+2318,U+2325,U+21E7" --layout-features='*' --flavor=woff2`.
- Brand files: copy from `docs/brand/` (drawn by `scripts/make-brulion-brand.swift`), never edit the PNGs.
- Bump the `?v=` of the CSS and JS links in `index.html` after changing those files.

## Live

- Live at https://kawalec.pl/brulion/ since 2026-11-09 (a static folder behind the owner's web server; the server details stay outside this public repo). `canonical`, `og:url`, `og:image` and the JSON-LD `url` point there: change them together if the address moves.
- Assets are linked relatively, so the page needs the trailing slash: the server redirects `/brulion` to `/brulion/`.
- After a change: bump `?v=` in `index.html`, then the owner (or an agent with his go-ahead) uploads `site/` again.
- `brulion-bielik-awards-2026.pdf` is the presentation linked in the Bielik Awards form: keep it at that address at least until 2026-11-26.
- Still open: the download buttons point at `github.com/dawidkawalec/brulion/releases/latest`, which works only after the repo is public and a notarized DMG is released (Ster t578).
