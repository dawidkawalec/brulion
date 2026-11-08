#!/usr/bin/env python3
"""A window of a Sejm sitting (public transcripts, api.sejm.gov.pl) as a meeting transcript for
`Szpak --meeting-ai` (docs/benchmark.md, docs/architecture.md "Debug CLI flags").

Realistic, public and reproducible input for the meeting benchmark: real speakers and the real
start and end time of every statement. Each statement is cut into transcript-like segments of
at most ~25 words, timed linearly by words between its start and end; a statement running past
the window keeps only the words spoken inside it. Stage notes such as "(Oklaski)" are dropped.

    python3 -I scripts/benchmark/sejm_meeting.py <term> <sitting> <YYYY-MM-DD> <HH:MM> <minutes> <out.json>
    python3 -I scripts/benchmark/sejm_meeting.py 10 67 2026-10-21 09:25 60 sejm-60.json
"""
import datetime as dt
import html
import json
import re
import sys
import urllib.request
from html.parser import HTMLParser

API = "https://api.sejm.gov.pl/sejm/term{term}/proceedings/{sitting}/{date}/transcripts"


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "szpak-benchmark/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8")


class Speech(HTMLParser):
    """Paragraph text after the speaker heading; headings and the agenda item are skipped."""

    def __init__(self):
        super().__init__()
        self.paragraphs, self.current, self.inside, self.started = [], [], False, False

    def handle_starttag(self, tag, attrs):
        if tag == "h2" and ("class", "mowca") in attrs:
            self.started = True
        if tag == "p" and self.started:
            self.inside, self.current = True, []

    def handle_endtag(self, tag):
        if tag == "p" and self.inside:
            self.inside = False
            text = " ".join("".join(self.current).split())
            if text:
                self.paragraphs.append(text)

    def handle_data(self, data):
        if self.inside:
            self.current.append(data)


def speech_text(page):
    parser = Speech()
    parser.feed(page)
    text = html.unescape(" ".join(parser.paragraphs))
    return " ".join(re.sub(r"\([^()]{0,80}\)", " ", text).split())


def segments_of(text, start, end, max_words=25):
    sentences = re.split(r"(?<=[.!?])\s+", text)
    chunks, current = [], []
    for sentence in sentences:
        words = sentence.split()
        if current and len(current) + len(words) > max_words:
            chunks.append(current)
            current = []
        current += words
        while len(current) > max_words * 2:
            chunks.append(current[:max_words])
            current = current[max_words:]
    if current:
        chunks.append(current)
    total = sum(len(c) for c in chunks) or 1
    span = max(end - start, 1.0)
    out, done = [], 0
    for chunk in chunks:
        s = start + span * done / total
        done += len(chunk)
        e = start + span * done / total
        out.append((round(s, 2), round(max(e - 0.2, s + 0.5), 2), " ".join(chunk)))
    return out


def main(term, sitting, date, clock, minutes, out_path):
    base = API.format(term=term, sitting=sitting, date=date)
    index = json.loads(fetch(base))["statements"]
    window_start = dt.datetime.fromisoformat(f"{date}T{clock}:00")
    window_end = window_start + dt.timedelta(minutes=int(minutes))
    labels, names, segments, items = {}, {}, [], set()
    for statement in index:
        if statement["num"] == 0 or statement.get("unspoken"):
            continue
        start = dt.datetime.fromisoformat(statement["startDateTime"])
        end = dt.datetime.fromisoformat(statement["endDateTime"])
        if start < window_start or start >= window_end:
            continue
        page = fetch(f"{base}/{statement['num']}")
        item = re.search(r'<p class="punkt-tytul">\s*(.*?)\s*</p>', page, re.S)
        if item:
            items.add(" ".join(html.unescape(item.group(1)).split()))
        text = speech_text(page)
        if not text:
            continue
        if end > window_end:
            words = text.split()
            kept = max(1, int(len(words) * (window_end - start) / (end - start)))
            text = " ".join(words[:kept])
            end = window_end
        who = statement["name"]
        label = labels.setdefault(who, str(len(labels) + 1))
        names[label] = who
        offset = (start - window_start).total_seconds()
        for s, e, chunk in segments_of(text, offset, (end - window_start).total_seconds()):
            segments.append({"track": "them", "start": s, "end": e, "text": chunk, "speaker": label})
    title = f"Posiedzenie Sejmu nr {sitting}, {date} {clock}, {minutes} min"
    data = {"title": title, "participants": list(labels), "speakerNames": names, "segments": segments, "agenda": sorted(items)}
    with open(out_path, "w", encoding="utf-8") as out:
        json.dump(data, out, ensure_ascii=False, indent=1)
    words = sum(len(s["text"].split()) for s in segments)
    last = segments[-1]["end"] if segments else 0
    print(f"{out_path}: {len(segments)} segments, {len(labels)} speakers, {words} words, ends at {last / 60:.1f} min")


if __name__ == "__main__":
    if len(sys.argv) != 7:
        sys.exit(__doc__)
    main(*sys.argv[1:7])
