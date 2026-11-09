#!/bin/sh
# Renders the Bielik Awards presentation (docs/awards/prezentacja.html) to the PDF served next to
# the landing page (site/brulion-bielik-awards-2026.pdf). See docs/bielik-awards-zgloszenie.md.
set -eu
cd "$(dirname "$0")/.."

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="site/brulion-bielik-awards-2026.pdf"

"$CHROME" --headless --disable-gpu --no-pdf-header-footer --allow-file-access-from-files \
  --virtual-time-budget=8000 --print-to-pdf="$OUT" "file://$PWD/docs/awards/prezentacja.html" 2>/dev/null

pages=$(mdls -raw -name kMDItemNumberOfPages "$OUT" 2>/dev/null || echo "?")
echo "$OUT: $(du -h "$OUT" | cut -f1), pages: $pages"
