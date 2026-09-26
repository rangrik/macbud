#!/usr/bin/env python3
"""Replay MacBud's recorded opens through TypeSafe's Jev and score it against what the owner actually used.

Modes:
  --dry-run   print the request bodies, call nothing
  --probes    six hand-written contexts with an obvious right answer (does Jev react to the signals at all?)
  default     every scored open in predictions.jsonl, history = the scored opens before it
Key: $TYPESAFE_API_KEY or ~/Library/Application Support/MacBud/typesafe-api-key
"""
import argparse, json, os, sys, time, urllib.request, urllib.error
from datetime import datetime, timezone
from pathlib import Path

ENDPOINT = "https://api.typesafe.ai/v1/systemone"
SUPPORT = Path.home() / "Library/Application Support/MacBud"
PRICE_PER_MTOK = 0.042

MEANINGS = {
    "text": "text they copied earlier (the clipboard history)",
    "link": "a web link they copied",
    "image": "an image they copied",
    "screenshot": "a screenshot or screen recording they saved to disk",
    "dictation": "the transcript of something they dictated",
    "snippet": "a saved piece of reusable text they paste often",
    "app": "an app or window to switch to",
}


def key():
    k = os.environ.get("TYPESAFE_API_KEY")
    if not k:
        f = SUPPORT / "typesafe-api-key"
        if f.exists():
            k = f.read_text().strip()
    if not k:
        sys.exit("No API key: set TYPESAFE_API_KEY or write it to " + str(SUPPORT / "typesafe-api-key"))
    return k


def age(seconds):
    # Jev reads numbers as text, so ages become named buckets (docs: model-jaggedness).
    if seconds is None:
        return "never"
    if seconds < 15:
        return "seconds ago"
    if seconds < 60:
        return "under a minute ago"
    if seconds < 300:
        return "1 to 5 minutes ago"
    if seconds < 1800:
        return "5 to 30 minutes ago"
    if seconds < 7200:
        return "30 minutes to 2 hours ago"
    if seconds < 8 * 3600:
        return "2 to 8 hours ago"
    return "more than 8 hours ago"


def short(bundle):
    if not bundle:
        return "unknown"
    return bundle.split(".")[-1]


def part(hour):
    return ("night" if hour < 6 else "morning" if hour < 12 else "afternoon" if hour < 18 else "evening")


def describe_open(s):
    c = s["context"]
    o = s.get("outcome") or {}
    t = datetime.fromisoformat(s["t"].replace("Z", "+00:00")).astimezone()
    used = o.get("kind", "nothing")
    if o.get("newest") is not None:
        used += " (newest)" if o["newest"] else " (older)"
    if o.get("app"):
        used += " " + short(o["app"])
    return (f"{t.strftime('%a %H:%M')} · front app {short(c.get('app'))} · latest copy {c.get('clipboardKind') or 'none'} "
            f"{age(c.get('clipboardAge'))} · screenshot {age(c.get('screenshotAge'))} · dictation {age(c.get('dictationAge'))}"
            f" → used {used}")


def state(context, history, strategies):
    c = context
    st = {
        "now": {"weekday": c["weekday"], "hour": f"{c['hour']:02d}:00", "part_of_day": part(c["hour"])},
        "front_app": {"bundle_id": c.get("app") or "unknown", "name": short(c.get("app"))},
        "latest_clipboard_item": {"kind": c.get("clipboardKind") or "none", "copied_from": short(c.get("clipboardSource")),
                                  "copied": age(c.get("clipboardAge"))},
        "latest_screenshot": {"kind": c.get("screenshotKind") or "none", "saved": age(c.get("screenshotAge"))},
        "latest_dictation": {"finished": age(c.get("dictationAge"))},
    }
    if c.get("previousApp"):
        st["previous_app"] = short(c["previousApp"])
    if c.get("runningApps"):
        st["running_apps"] = [short(a) for a in c["runningApps"]]
    st["recent_opens_oldest_first"] = [describe_open(s) for s in history[-15:]] or ["none yet"]
    if strategies:
        st["rules_written_by_a_reviewer_from_past_misses"] = strategies
    return st


def questions(kinds):
    # The same two questions the app asks (PredictionPrompts.jev).
    return {
        "kind": {
            "type": "choice",
            "instructions": "The owner of a Mac utility just pressed its open key. Which kind of item are they most likely "
                            "reaching for right now? Weigh `front_app`, how recently each item arrived, and `recent_opens_oldest_first`.",
            "criteria": {k: MEANINGS[k] for k in kinds},
        },
        "which_item": {
            "type": "choice",
            "instructions": "Within the kind they are reaching for, do they want the most recent item of that kind, "
                            "or an earlier one they will search for?",
            "criteria": {"newest": "the most recent item of that kind (for an app: the window they just left)",
                         "older": "an earlier item of that kind that they will look for",
                         "either": "nothing here says which; they will pick either way"},
        },
    }


def call(api_key, body, timeout=20):
    req = urllib.request.Request(ENDPOINT, data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"})
    started = time.perf_counter()
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r), int((time.perf_counter() - started) * 1000)
        except urllib.error.HTTPError as e:
            text = e.read().decode(errors="replace")
            if e.code in (429, 529) and attempt < 3:
                time.sleep(2 ** attempt)
                continue
            raise SystemExit(f"HTTP {e.code}: {text}")


def pick(answers, hint_floor):
    k = answers["kind"]
    w = answers["which_item"]
    hint = w["choice"] if w.get("confidence", 0) >= hint_floor and w["choice"] != "either" else "any"
    return {"kind": k["choice"], "hint": hint, "kind_confidence": round(k.get("confidence", 0), 2),
            "hint_confidence": round(w.get("confidence", 0), 2),
            "hint_probs": {a: round(b, 2) for a, b in w["probabilities"].items()}, "kind_probs": {a: round(b, 2) for a, b in k["probabilities"].items()}}


def hit(intent, outcome):
    if not outcome or outcome["kind"] != intent["kind"]:
        return False
    if outcome.get("newest") is None or intent["hint"] == "any":
        return True
    return outcome["newest"] == (intent["hint"] == "newest")


def load(name):
    p = SUPPORT / "predict" / name
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()] if p.exists() else []


PROBES = [
    ("screenshot 5 s ago in Finder", {"hour": 15, "weekday": "Wed", "app": "com.apple.finder", "clipboardKind": "text",
                                       "clipboardSource": "com.google.Chrome", "clipboardAge": 900, "screenshotKind": "image",
                                       "screenshotAge": 5, "dictationAge": 40000}, ("screenshot", "newest")),
    ("dictation just finished in Slack", {"hour": 10, "weekday": "Tue", "app": "com.tinyspeck.slackmacgap", "clipboardKind": "text",
                                          "clipboardSource": "com.apple.Notes", "clipboardAge": 3000, "screenshotKind": "image",
                                          "screenshotAge": 20000, "dictationAge": 8}, ("dictation", "newest")),
    ("copied a link 3 s ago in Chrome", {"hour": 11, "weekday": "Mon", "app": "com.google.Chrome", "clipboardKind": "link",
                                         "clipboardSource": "com.google.Chrome", "clipboardAge": 3, "screenshotKind": "image",
                                         "screenshotAge": 5000, "dictationAge": 90000}, ("link", "newest")),
    ("copied an image 10 s ago in Preview", {"hour": 14, "weekday": "Thu", "app": "com.apple.Preview", "clipboardKind": "image",
                                             "clipboardSource": "com.apple.Preview", "clipboardAge": 10, "screenshotKind": "image",
                                             "screenshotAge": 4000, "dictationAge": None}, ("image", "newest")),
    ("nothing recent, in Terminal", {"hour": 9, "weekday": "Fri", "app": "com.apple.Terminal", "clipboardKind": "text",
                                     "clipboardSource": "com.apple.Terminal", "clipboardAge": 5400, "screenshotKind": "image",
                                     "screenshotAge": 40000, "dictationAge": 80000}, ("text", None)),
    ("just switched from Xcode to Chrome, copy 2 h old", {"hour": 16, "weekday": "Wed", "app": "com.google.Chrome",
                                                          "previousApp": "com.apple.dt.Xcode",
                                                          "runningApps": ["com.google.Chrome", "com.apple.dt.Xcode", "com.apple.finder"],
                                                          "clipboardKind": "text", "clipboardSource": "com.apple.dt.Xcode",
                                                          "clipboardAge": 7200, "screenshotKind": "image", "screenshotAge": 30000,
                                                          "dictationAge": 90000}, (None, None)),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--probes", action="store_true")
    ap.add_argument("--no-rules", action="store_true", help="leave the reviewer's strategies out of the state")
    ap.add_argument("--no-history", action="store_true", help="leave recent opens out of the state")
    ap.add_argument("--hint-floor", type=float, default=0.5, help="below this confidence the hint becomes any")
    ap.add_argument("--out", default="/tmp/jev-replay.jsonl")
    a = ap.parse_args()

    kinds_all = list(MEANINGS)
    strategies = "" if a.no_rules else (SUPPORT / "predict" / "strategies.md").read_text().strip() if (SUPPORT / "predict" / "strategies.md").exists() else ""
    sessions = load("predictions.jsonl")
    scored = [s for s in sessions if s.get("hit") is not None]

    cases = []
    if a.probes:
        for name, ctx, expect in PROBES:
            ctx = {**ctx, "kinds": kinds_all}
            cases.append({"name": name, "context": ctx, "history": [], "expect": expect})
    else:
        for s in scored:
            hist = [] if a.no_history else [h for h in scored if h["t"] < s["t"]]
            cases.append({"name": describe_open(s), "context": s["context"], "history": hist, "session": s})

    api_key = None if a.dry_run else key()
    results, tokens_total, ms_all = [], 0, []
    out = open(a.out, "w")
    for c in cases:
        body = {"model": "jev-latest", "state": state(c["context"], c["history"], strategies), "questions": questions(c["context"]["kinds"])}
        if a.dry_run:
            print(json.dumps(body, indent=1)[:3000], "\n...\n")
            continue
        reply, ms = call(api_key, body)
        p = pick(reply["answers"], a.hint_floor)
        toks = reply.get("usage", {}).get("input_tokens", 0)
        tokens_total += toks
        ms_all.append(ms)
        row = {"case": c["name"], "jev": p, "ms": ms, "input_tokens": toks, "model": reply.get("model")}
        if "session" in c:
            s = c["session"]
            row["luna_or_rule"] = {"source": s["source"], "kind": s["landed"]["kind"], "hint": s["landed"]["hint"], "hit": s["hit"]}
            row["rule"] = {"kind": (s.get("heuristic") or {}).get("kind"), "hint": (s.get("heuristic") or {}).get("hint"),
                           "hit": hit(s["heuristic"], s.get("outcome")) if s.get("heuristic") else None}
            row["outcome"] = s.get("outcome")
            row["jev_hit"] = hit(p, s.get("outcome"))
            row["jev_kind_hit"] = p["kind"] == s["outcome"]["kind"]
        else:
            ek, eh = c["expect"]
            row["expect"] = c["expect"]
            row["jev_hit"] = (ek is None or p["kind"] == ek) and (eh is None or p["hint"] == eh)
        out.write(json.dumps({**row, "request": body, "response": reply}) + "\n")
        results.append(row)
        print(json.dumps({k: v for k, v in row.items()}, ensure_ascii=False))
    out.close()
    if a.dry_run or not results:
        return
    n = len(results)
    print(f"\n{n} calls · median {sorted(ms_all)[n // 2]} ms · mean {sum(ms_all) // n} ms · "
          f"{tokens_total // n} input tokens/call · ${tokens_total / 1e6 * PRICE_PER_MTOK:.5f} total")
    jev = sum(r["jev_hit"] for r in results)
    print(f"Jev hits: {jev}/{n}")
    if not a.probes:
        print(f"Jev kind-only hits: {sum(r['jev_kind_hit'] for r in results)}/{n}")
        print(f"Recorded pick (Luna or rule) hits: {sum(r['luna_or_rule']['hit'] for r in results)}/{n}")
        print(f"Rule alone hits: {sum(bool(r['rule']['hit']) for r in results)}/{n}")
        luna = [r for r in results if r["luna_or_rule"]["source"] == "model"]
        if luna:
            print(f"On the {len(luna)} opens Luna decided: Luna {sum(r['luna_or_rule']['hit'] for r in luna)}, "
                  f"Jev {sum(r['jev_hit'] for r in luna)}")
    print("Wrote", a.out)


if __name__ == "__main__":
    main()
