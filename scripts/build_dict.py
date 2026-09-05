#!/usr/bin/env python3
"""Build the rime-translate offline dictionary from ECDICT.

Reads the ECDICT csv (https://github.com/skywind3000/ECDICT, MIT) and produces
a compact SQLite db with a Chinese -> English inverted index:

    zh_en(zh TEXT PRIMARY KEY, en TEXT, score REAL)  -- en is pipe-separated
        english headwords sorted by frequency score (all by default)
    ai_cache(zh TEXT PRIMARY KEY, en TEXT, created_at INTEGER)
    meta(key TEXT PRIMARY KEY, value TEXT)

Usage:
    python3 scripts/build_dict.py ecdict.csv -o dist/ecdict.db
"""

import argparse
import heapq
import math
import os
import re
import sqlite3
import sys
import time

CJK_RUN = re.compile(r"[\u3400-\u9fff][\u3400-\u9fff·]{0,11}")
POS_PREFIX = re.compile(r"^\s*(?:[a-z]{1,4}\.\s*)+")
PHRASE_SPLIT = re.compile(r"[，,；;。！？!?\s（）()【】\[\]「」『』/、]+")
MAX_ZH_LEN = 12
# dictionary usage labels: "(美)merican usage", "[医]medical", "(口语)", ...
# these are NOT senses -- stripping them prevents 美->governor style junk
LABEL = ("美英口俚喻贬史古方谑废主宾定语法化医军经计物生植动宗音诗"
         "苏格兰澳新南非加拿大爱尔兰威尔士印度")
USAGE_LABEL = re.compile(
    r"[（\[(]\s*(?:%s){1,4}语?\s*[）\])]" % "|".join(LABEL))
# exchange field lists derivations as ".../0:<lemma>"; a word whose lemma
# differs from itself is an inflected form duplicating the lemma's senses
EXCHANGE_LEMMA = re.compile(r"(?:^|/)(?:\d+:)?0:([^/]+)")
# sane english headword: letters (+ ' - . space), must end alphanumeric
WORD_OK = re.compile(r"^[A-Za-z][A-Za-z'\-. ]{0,37}[A-Za-z]$|^[A-Za-z]{2}$")


def word_ok(word):
    return WORD_OK.match(word) is not None


def load_evidenced_words(path):
    """Lowercase set of dictionary words with human/corpus curation."""
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        rows = conn.execute(
            "SELECT lower(word) FROM stardict "
            "WHERE oxford > 0 OR collins > 0 OR frq > 0")
        return {r[0] for r in rows}
    finally:
        conn.close()


CEDICT_LINE = re.compile(r"^\S+ (\S+) \[[^\]]*\] /(.+)/\s*$")
# cross-reference fragments ("used in 自個兒", "variant of 個", pinyin
# citations "zi4 ge3 r5") are pointers, not translations
HAS_CJK = re.compile(r"[\u3400-\u9fff]")
PINYIN_CITE = re.compile(r"[a-z]+[1-5](\s|$)")


def cedict_def_ok(seg):
    if HAS_CJK.search(seg):
        return False
    if PINYIN_CITE.search(seg.lower()):
        return False
    return True


def parse_cedict(path):
    """Parse CC-CEDICT (native Chinese->English) into zh -> [en, ...].
    These definitions get front-of-list priority over inverted ECDICT."""
    mapping = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                continue
            m = CEDICT_LINE.match(line)
            if not m:
                continue
            zh, defs_raw = m.group(1), m.group(2)
            if not (1 <= len(zh) <= MAX_ZH_LEN):
                continue
            defs = []
            for seg in defs_raw.split("/"):
                seg = seg.strip()
                if not seg or seg.startswith("CL:") or seg.startswith("see "):
                    continue
                if not cedict_def_ok(seg):
                    continue
                if seg not in defs:
                    defs.append(seg)
            if defs:
                cur = mapping.setdefault(zh, [])
                for d in defs:
                    if d not in cur:
                        cur.append(d)
    # everyday senses first across ALL entries of a word: lowercase common
    # nouns beat proper nouns and parenthesized qualifiers
    for defs in mapping.values():
        defs.sort(key=lambda d: (d[:1].isupper(), "(" in d))
    return mapping


def load_zh_freq(path):
    """jieba-style word frequency list -> {word: freq}."""
    freq = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                try:
                    freq[parts[0]] = int(parts[1])
                except ValueError:
                    continue
    return freq


def is_inflection(word_lower, evidenced):
    """Catch derived forms that ECDICT's exchange field misses
    (e.g. 'beautifuler' whose exchange points at itself).
    Only called for words without Oxford/Collins curation."""
    n = len(word_lower)
    if n >= 6 and word_lower.endswith("iest"):
        return (word_lower[:-4] + "y") in evidenced
    if n >= 5 and word_lower.endswith("est"):
        return word_lower[:-3] in evidenced
    if n >= 5 and word_lower.endswith("er"):
        return word_lower[:-2] in evidenced
    return False


def zh_phrases(translation):
    """Extract (phrase, position) from an ECDICT translation field.
    Position = order of first appearance; earlier senses are primary."""
    out = []
    seen = {}
    i = 0
    for line in (translation or "").split("\n"):
        line = POS_PREFIX.sub("", line)
        line = USAGE_LABEL.sub(" ", line)  # drop (美)/(英)/[医] style labels
        for raw in PHRASE_SPLIT.split(line):
            for m in CJK_RUN.finditer(raw):
                p = m.group(0).strip("·")
                if 1 <= len(p) <= MAX_ZH_LEN:
                    if p not in seen:
                        seen[p] = i
                        out.append((p, i))
                    i += 1
    return out


def word_score(row, word):
    """Higher = better english headword for this chinese sense.

    Quality first (Oxford/Collins curation), frequency only as a log-scale
    tiebreaker -- raw web-corpus counts put niche jargon above everyday
    senses (e.g. 'logon' outranked 'computer' with raw frequencies).
    """
    try:
        frq = int(row.get("frq") or 0)
    except ValueError:
        frq = 0
    try:
        bnc = int(row.get("bnc") or 0)
    except ValueError:
        bnc = 0
    try:
        collins = int(row.get("collins") or 0)
    except (ValueError, TypeError):
        collins = 0

    if str(row.get("oxford") or "0").strip() == "1":
        quality = (1 + min(collins, 5)) * 4.0
    else:
        quality = 1.0 + min(collins, 5)

    if frq > 0:
        evidence = 1.0 + math.log10(1 + frq)
    elif bnc > 0:
        # bnc is a rank (lower = more common)
        evidence = 1.0 + math.log10(1 + 100000.0 / bnc)
    else:
        evidence = 1.0

    score = quality * evidence
    if " " in word:
        score *= 0.8  # prefer single-word headwords for candidate comments
    return score


def iter_rows(path):
    """Yield dict rows from either an ECDICT csv file or the official
    ecdict-sqlite release (stardict.db)."""
    import csv
    if path.lower().endswith((".db", ".sqlite", ".sqlite3")):
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        try:
            for row in conn.execute(
                    "SELECT word, translation, collins, oxford, bnc, frq, exchange FROM stardict"):
                yield {k: row[k] for k in row.keys()}
        finally:
            conn.close()
        return
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        required = {"word", "translation"}
        if not required.issubset(set(reader.fieldnames or [])):
            sys.exit(f"csv missing columns {required}; got {reader.fieldnames}")
        yield from reader


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", help="ECDICT csv file (ecdict.csv)")
    ap.add_argument("-o", "--output", default="dist/ecdict.db")
    ap.add_argument("--max-per-word", type=int, default=0,
                    help="max english headwords kept per chinese phrase "
                         "(0 = keep all, full dictionary)")
    ap.add_argument("--min-score", type=float, default=0.0,
                    help="drop english words scoring below this (0 = keep all)")
    ap.add_argument("--cedict",
                    help="CC-CEDICT file merged as a high-priority source")
    ap.add_argument("--zh-freq",
                    help="jieba-style word frequency list; ranks the hot cache")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    if os.path.exists(args.output):
        os.remove(args.output)

    # phrase -> list of (score, word); heap only used when capped
    index = {}
    phrase_seen = {}  # phrase -> set of lowercase words already added

    if args.input.lower().endswith((".db", ".sqlite", ".sqlite3")):
        print("loading evidenced-word set...", file=sys.stderr)
        evidenced = load_evidenced_words(args.input)
        print(f"  {len(evidenced)} evidenced words", file=sys.stderr)
    else:
        evidenced = set()

    cedict_map = parse_cedict(args.cedict) if args.cedict else {}
    print(f"cc-cedict: {len(cedict_map)} entries", file=sys.stderr) if cedict_map else None
    zh_freq = load_zh_freq(args.zh_freq) if args.zh_freq else {}
    print(f"zh-freq: {len(zh_freq)} words", file=sys.stderr) if zh_freq else None

    t0 = time.time()
    n_words = 0
    n_skipped = 0
    for row in iter_rows(args.input):
        if not isinstance(row, dict):
            row = dict(row)
        word = (row.get("word") or "").strip()
        if not word or not word.isascii() or "_" in word:
            continue
        exchange = row.get("exchange") or ""
        for m in EXCHANGE_LEMMA.finditer(exchange):
            lemma = m.group(1).strip().lower()
            if lemma and lemma != word.lower():
                n_skipped += 1
                break
        else:
            if not word_ok(word):
                n_skipped += 1
                continue
            wl = word.lower()
            try:
                oxford = str(row.get("oxford") or "0").strip() == "1"
                collins = int(row.get("collins") or 0)
                has_frq = int(row.get("frq") or 0) > 0
            except (ValueError, TypeError):
                oxford, collins, has_frq = False, 0, False
            # drop 1-3 letter tokens with no curation or web frequency
            # (pure corpus/typo noise: svq, aey, ...)
            if len(word) <= 3 and not oxford and not collins and not has_frq:
                n_skipped += 1
                continue
            if not oxford and collins == 0 and is_inflection(wl, evidenced):
                n_skipped += 1
                continue
            n_words += 1
            s = word_score(row, word)
            if s < args.min_score:
                continue
            k = args.max_per_word
            for p, pos in zh_phrases(row.get("translation")):
                # sense-position weighting: the first mention of a phrase in
                # a translation is its primary sense
                weighted = s / (1.0 + 0.15 * pos)
                variants = [p]
                if p.endswith(("的", "地", "得")) and len(p) >= 2:
                    variants.append(p[:-1])
                for v in variants:
                    h = index.setdefault(v, [])
                    counts = phrase_seen.setdefault(v, {})
                    cnt = counts.get(wl, 0)
                    if cnt == 0:
                        # counts is a pure mention counter (multi-sense
                        # evidence); heap membership is one-way: an evicted
                        # word never re-enters, and eviction must not rewind
                        # the mention history of words still in the heap
                        if k > 0:
                            entry = (weighted, word)
                            if len(h) < k:
                                heapq.heappush(h, entry)
                            elif weighted > h[0][0]:
                                heapq.heapreplace(h, entry)
                        else:
                            h.append((weighted, word))
                    counts[wl] = cnt + 1
        if n_words % 500000 == 0:
            print(f"  scanned {n_words} words (+{n_skipped} inflections skipped), "
                  f"{len(index)} phrases...", file=sys.stderr)

    print(f"scanned {n_words} words -> {len(index)} chinese phrases "
          f"in {time.time()-t0:.1f}s", file=sys.stderr)

    db = sqlite3.connect(args.output)
    db.executescript("""
        PRAGMA journal_mode=OFF;
        PRAGMA synchronous=OFF;
        CREATE TABLE zh_en (
            zh TEXT PRIMARY KEY,
            en TEXT NOT NULL,
            score REAL NOT NULL DEFAULT 0,
            zh_freq INTEGER NOT NULL DEFAULT 0
        ) WITHOUT ROWID;
        CREATE INDEX idx_zh_en_score ON zh_en(score DESC);
        CREATE INDEX idx_zh_en_freq ON zh_en(zh_freq DESC);
        -- exact cover for the helper's topPhrases() ORDER BY; without it the
        -- hot-cache export temp-B-tree sorts all 2.7M rows
        CREATE INDEX idx_zh_en_freq_score ON zh_en(zh_freq DESC, score DESC);
        CREATE TABLE ai_cache (
            zh TEXT PRIMARY KEY,
            en TEXT NOT NULL,
            created_at INTEGER NOT NULL
        );
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    """)
    batch = []
    for p, h in index.items():
        counts = phrase_seen.get(p, {})
        # multi-sense boost: a headword whose several senses carry this
        # chinese word is more strongly associated with it
        def rank(e):
            s, w = e
            return -(s * (1.0 + 0.25 * (counts.get(w.lower(), 1) - 1)))
        ranked = sorted(h, key=rank)
        words = [w for _, w in ranked]
        top_score = -rank(ranked[0])

        # CC-CEDICT is natively Chinese->English: clean defs go to the front
        # of the list, heavily qualified ones "(concept of) time" fall behind
        extra = cedict_map.get(p, [])
        if extra:
            extra_front = [d for d in extra if "(" not in d and not d[:1].isupper()]
            extra_back = [d for d in extra if d not in extra_front]
            merged, seen_l = [], set()
            for w in extra_front + words + extra_back:
                lw = w.lower()
                if lw not in seen_l:
                    seen_l.add(lw)
                    merged.append(w)
            words = merged

        freq = zh_freq.get(p, 0)
        batch.append((p, "|".join(words), top_score, freq))
        if len(batch) >= 10000:
            db.executemany("INSERT OR REPLACE INTO zh_en VALUES (?,?,?,?)", batch)
            batch = []
    if batch:
        db.executemany("INSERT OR REPLACE INTO zh_en VALUES (?,?,?,?)", batch)

    # phrases that only CC-CEDICT covers (e.g. 手机 -> cell phone)
    batch = []
    for p, defs in cedict_map.items():
        if p not in index:
            freq = zh_freq.get(p, 0)
            batch.append((p, "|".join(defs), 10.0 * len(defs), freq))
            if len(batch) >= 10000:
                db.executemany("INSERT OR REPLACE INTO zh_en VALUES (?,?,?,?)", batch)
                batch = []
    if batch:
        db.executemany("INSERT OR REPLACE INTO zh_en VALUES (?,?,?,?)", batch)
    db.executemany("INSERT INTO meta VALUES (?,?)", [
        ("source", "skywind3000/ECDICT + CC-CEDICT (MDBG)"),
        ("license", "ECDICT: MIT; CC-CEDICT: CC-BY-SA 4.0 (data package)"),
        ("built_at", str(int(time.time()))),
        ("words_scanned", str(n_words)),
        ("phrases", str(len(index))),
    ])
    db.commit()
    size_mb = os.path.getsize(args.output) / 1048576
    print(f"wrote {args.output} ({len(index)} phrases, {size_mb:.1f} MB)", file=sys.stderr)


if __name__ == "__main__":
    main()
