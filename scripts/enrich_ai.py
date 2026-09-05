#!/usr/bin/env python3
"""Batch-enrich the local dictionary with Cloudflare Workers AI translations.

Uses the FREE neuron allowance of Workers AI. Cost per request depends
on the model: m2m100 ~0.3 neurons (=> 30k+ free translations/day on the
10k-neuron free plan); llama-3.3-70b ~11 neurons (=> ~900/day).

Targets common Chinese words (high zh_freq) whose current English list is
missing or looks low-quality, translates them with the configured model and
stores results in ai_cache -- which the helper already merges into the hot
cache. Fully resumable; a checkpoint file remembers progress.

Usage:
    python3 scripts/enrich_ai.py --db ~/Library/Application\\ Support/rime-translate/ecdict.db \
        --account <CF_ACCOUNT_ID> --token <CF_API_TOKEN> [--model @cf/meta/m2m100-1.2b] \
        [--limit 500] [--min-freq 100]
"""

import argparse
import json
import sqlite3
import sys
import time
import urllib.request

NEURON_FREE_PER_DAY = 10000

# approximate neurons per single-word request, matched by substring against
# --model (Cloudflare's per-model pricing; LLMs cost ~30x more than m2m100)
NEURON_COSTS = [
    ("m2m100", 0.3),
    ("llama-3.3-70b", 11.0),
]
DEFAULT_NEURON_COST = 11.0     # conservative for unknown chat models


def neurons_per_call(model):
    for needle, cost in NEURON_COSTS:
        if needle in model:
            return cost
    return DEFAULT_NEURON_COST


def looks_weak(en):
    """Heuristic: translation list has no plain lowercase word headwords."""
    if not en:
        return True
    for w in en.split("|"):
        if w and w[0].islower() and w.isalpha() and 2 <= len(w) <= 20:
            return False
    return True


def translate(text, account, token, model, timeout=20):
    url = f"https://api.cloudflare.com/client/v4/accounts/{account}/ai/run/{model}"
    if "m2m100" in model:
        body = {"text": text, "source_lang": "chinese", "target_lang": "english"}
    else:
        body = {
            "messages": [
                {"role": "system",
                 "content": "Translate the Chinese word or phrase to English. "
                            "Reply with up to 3 English translations separated "
                            "by | , nothing else."},
                {"role": "user", "content": text},
            ],
            "max_tokens": 40,
        }
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            obj = json.loads(r.read())
    except Exception as e:
        print(f"  ! {text}: {e}", file=sys.stderr)
        return None
    if not obj.get("success"):
        return None
    result = obj.get("result")
    if isinstance(result, dict):
        t = result.get("translated_text") or result.get("response")
        if isinstance(t, str) and t.strip():
            return t.strip()
        choices = result.get("choices")
        if choices:
            c = choices[0].get("message", {}).get("content", "").strip()
            if c:
                return c
    if isinstance(result, list):
        parts = [x.get("translated_text", "") for x in result]
        joined = " ".join(parts).strip()
        return joined or None
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", required=True)
    ap.add_argument("--account", required=True)
    ap.add_argument("--token", required=True)
    ap.add_argument("--model", default="@cf/meta/llama-3.3-70b-instruct-fp8-fast")
    ap.add_argument("--limit", type=int, default=500,
                    help="max words to enrich this run")
    ap.add_argument("--min-freq", type=int, default=50,
                    help="only consider words with zh_freq >= this")
    ap.add_argument("--interval", type=float, default=0.25,
                    help="seconds between API calls")
    args = ap.parse_args()

    ckpt_path = args.db + ".enrich_ckpt"
    done = set()
    try:
        done = set(open(ckpt_path, encoding="utf-8").read().split())
    except FileNotFoundError:
        pass

    db = sqlite3.connect(args.db)
    db.execute("CREATE TABLE IF NOT EXISTS ai_cache "
               "(zh TEXT PRIMARY KEY, en TEXT NOT NULL, created_at INTEGER NOT NULL)")

    rows = db.execute(
        "SELECT zh, en FROM zh_en WHERE zh_freq >= ? ORDER BY zh_freq DESC",
        (args.min_freq,)).fetchall()

    todo = [zh for zh, en in rows if zh not in done and looks_weak(en)]
    print(f"candidates: {len(todo)} (scanned {len(rows)}, "
          f"already enriched {len(done)})", file=sys.stderr)

    npc = neurons_per_call(args.model)
    budget = int(NEURON_FREE_PER_DAY / npc)
    print(f"model {args.model}: ~{npc} neurons/call -> free-tier budget "
          f"~{budget} calls/day", file=sys.stderr)
    n = 0
    for zh in todo:
        if n >= args.limit or n >= budget:
            break
        en = translate(zh, args.account, args.token, args.model)
        time.sleep(args.interval)
        if not en:
            continue
        db.execute("INSERT OR REPLACE INTO ai_cache VALUES (?,?,?)",
                   (zh, en, int(time.time())))
        done.add(zh)
        with open(ckpt_path, "w") as f:
            f.write("\n".join(done))
        db.commit()
        n += 1
        if n % 20 == 0:
            print(f"  {n}: last={zh} -> {en[:40]}", file=sys.stderr)

    print(f"done: enriched {n} words (checkpoint {ckpt_path})", file=sys.stderr)


if __name__ == "__main__":
    main()
