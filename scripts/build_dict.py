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
import os
import re
import sqlite3
import sys
import time

CJK_RUN = re.compile(r"[\u3400-\u9fff][\u3400-\u9fff·]{0,11}")
POS_PREFIX = re.compile(r"^\s*(?:[a-z]{1,4}\.\s*)+")
PHRASE_SPLIT = re.compile(r"[，,；;。！？!?\s（）()【】\[\]「」『』/、]+")
MAX_ZH_LEN = 12


def zh_phrases(translation):
    """Extract normalized Chinese phrases from an ECDICT translation field."""
    out = []
    seen = set()
    for line in (translation or "").split("\n"):
        line = POS_PREFIX.sub("", line)
        for raw in PHRASE_SPLIT.split(line):
            for m in CJK_RUN.finditer(raw):
                p = m.group(0).strip("·")
                if 1 <= len(p) <= MAX_ZH_LEN and p not in seen:
                    seen.add(p)
                    out.append(p)
    return out


def word_score(row):
    """Higher = more common / authoritative English headword."""
    try:
        frq = int(row.get("frq") or 0)
    except ValueError:
        frq = 0
    try:
        bnc = int(row.get("bnc") or 0)
    except ValueError:
        bnc = 0
    if frq > 0:
        score = float(frq)
    elif bnc > 0:
        score = 100000.0 / bnc
    else:
        score = 0.5
    if (row.get("oxford") or "0").strip() == "1":
        score *= 4.0
    try:
        collins = int(row.get("collins") or 0)
    except ValueError:
        collins = 0
    if collins >= 3:
        score *= 2.0
    return score


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", help="ECDICT csv file (ecdict.csv)")
    ap.add_argument("-o", "--output", default="dist/ecdict.db")
    ap.add_argument("--max-per-word", type=int, default=0,
                    help="max english headwords kept per chinese phrase "
                         "(0 = keep all, full dictionary)")
    ap.add_argument("--min-score", type=float, default=0.0,
                    help="drop english words scoring below this (0 = keep all)")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    if os.path.exists(args.output):
        os.remove(args.output)

    # phrase -> list of (score, word); heap only used when capped
    index = {}

    t0 = time.time()
    n_words = 0
    with open(args.input, newline="", encoding="utf-8") as f:
        import csv
        reader = csv.DictReader(f)
        required = {"word", "translation"}
        if not required.issubset(set(reader.fieldnames or [])):
            sys.exit(f"csv missing columns {required}; got {reader.fieldnames}")
        for row in reader:
            word = (row.get("word") or "").strip()
            if not word or not word.isascii() or "_" in word:
                continue
            n_words += 1
            s = word_score(row)
            if s < args.min_score:
                continue
            k = args.max_per_word
            for p in zh_phrases(row.get("translation")):
                h = index.setdefault(p, [])
                if k > 0:
                    entry = (s, word)
                    if len(h) < k:
                        heapq.heappush(h, entry)
                    elif s > h[0][0]:
                        heapq.heapreplace(h, entry)
                else:
                    h.append((s, word))
            if n_words % 200000 == 0:
                print(f"  scanned {n_words} words, {len(index)} phrases...", file=sys.stderr)

    print(f"scanned {n_words} words -> {len(index)} chinese phrases "
          f"in {time.time()-t0:.1f}s", file=sys.stderr)

    db = sqlite3.connect(args.output)
    db.executescript("""
        PRAGMA journal_mode=OFF;
        PRAGMA synchronous=OFF;
        CREATE TABLE zh_en (
            zh TEXT PRIMARY KEY,
            en TEXT NOT NULL,
            score REAL NOT NULL DEFAULT 0
        ) WITHOUT ROWID;
        CREATE INDEX idx_zh_en_score ON zh_en(score DESC);
        CREATE TABLE ai_cache (
            zh TEXT PRIMARY KEY,
            en TEXT NOT NULL,
            created_at INTEGER NOT NULL
        );
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    """)
    batch = []
    for p, h in index.items():
        ranked = sorted(h, reverse=True)
        words = [w for _, w in ranked]
        top_score = ranked[0][0]
        batch.append((p, "|".join(words), top_score))
        if len(batch) >= 10000:
            db.executemany("INSERT OR REPLACE INTO zh_en VALUES (?,?,?)", batch)
            batch = []
    if batch:
        db.executemany("INSERT OR REPLACE INTO zh_en VALUES (?,?,?)", batch)
    db.executemany("INSERT INTO meta VALUES (?,?)", [
        ("source", "skywind3000/ECDICT"),
        ("license", "MIT"),
        ("built_at", str(int(time.time()))),
        ("words_scanned", str(n_words)),
        ("phrases", str(len(index))),
    ])
    db.commit()
    size_mb = os.path.getsize(args.output) / 1048576
    print(f"wrote {args.output} ({len(index)} phrases, {size_mb:.1f} MB)", file=sys.stderr)


if __name__ == "__main__":
    main()
