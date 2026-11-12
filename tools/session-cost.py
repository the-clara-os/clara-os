#!/usr/bin/env python3
"""What have the day's Claude Code sessions in this repository cost?

Adds up the token usage Claude Code logs for every model call
(~/.claude/projects/*/*.jsonl), keeps the sessions that worked in this
repository, prices them at list prices and compares the day with the cap.
Exits with status 1 when the day is over the cap.

usage: tools/session-cost.py [YYYY-MM-DD]      (default: today, local time)
"""
import glob
import json
import os
import sys
import time
from datetime import date, datetime

DAILY_CAP = 50.00  # dollars; CLAUDE.md states the same figure

# List prices in dollars per million tokens, as of 2026-11: input, output,
# cache read. A cache write costs 1.25x input for the 5-minute cache and 2x
# for the 1-hour one. Add a line when a session uses another model.
PRICES = {
    "claude-fable-5-2": (8.00, 40.00, 0.20),
    "claude-fable-5-1": (10.00, 50.00, 1.00),
    "claude-opus-5-5": (4.00, 20.00, 0.20),
    "claude-sonnet-5-5": (2.00, 10.00, 0.10),
}

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser("~")
NAMES = (REPO, "~" + REPO[len(HOME):]) if REPO.startswith(HOME) else (REPO,)


def in_repo(entry):
    """Does this transcript line show work in this repository?"""
    cwd = entry.get("cwd") or ""
    if cwd == REPO or cwd.startswith(REPO + os.sep):
        return True
    content = (entry.get("message") or {}).get("content")
    for block in content if isinstance(content, list) else []:
        if isinstance(block, dict) and block.get("type") == "tool_use":
            if any(name in json.dumps(block.get("input")) for name in NAMES):
                return True
    return False


def dollars(price, usage):
    """The list price of one model call."""
    inp, out, read = price
    hour = (usage.get("cache_creation") or {}).get("ephemeral_1h_input_tokens") or 0
    five = (usage.get("cache_creation_input_tokens") or 0) - hour
    return ((usage.get("input_tokens") or 0) * inp + five * inp * 1.25 + hour * inp * 2
            + (usage.get("cache_read_input_tokens") or 0) * read
            + (usage.get("output_tokens") or 0) * out) / 1e6


def main():
    day = date.fromisoformat(sys.argv[1]) if len(sys.argv) > 1 else date.today()
    calls, touched = {}, {}  # message id -> (session, model, usage); session -> lines in the repo
    for path in glob.glob(os.path.join(HOME, ".claude", "projects", "*", "*.jsonl")):
        if os.path.getmtime(path) < time.mktime(day.timetuple()):
            continue
        with open(path, errors="replace") as f:
            for line in f:
                if '"assistant"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                    when = datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00"))
                except (ValueError, KeyError, TypeError, AttributeError):
                    continue
                if entry.get("type") != "assistant" or when.astimezone().date() != day:
                    continue
                session = entry.get("sessionId")
                touched[session] = touched.get(session, 0) + in_repo(entry)
                message = entry.get("message") or {}
                usage = message.get("usage")
                if not usage:
                    continue
                # One response is logged once per content block: keep the fullest copy.
                seen = calls.get(message.get("id"))
                if seen is None or (usage.get("output_tokens") or 0) > (seen[2].get("output_tokens") or 0):
                    calls[message.get("id")] = (session, message.get("model") or "unknown", usage)

    per_model = {}  # model -> (calls, dollars, or None when the model has no price)
    for session, model, usage in calls.values():
        # A session counts once three of its lines touched the repository; a stray `ls` does not.
        if touched.get(session, 0) < 3 or model.startswith("<"):
            continue
        count, cost = per_model.get(model, (0, 0.0))
        price = next((p for name, p in PRICES.items() if model.startswith(name)), None)
        per_model[model] = (count + 1, None if price is None or cost is None else cost + dollars(price, usage))

    total = sum(cost for _, cost in per_model.values() if cost is not None)
    print(f"{os.path.basename(REPO)}, {day}: {sum(count for count, _ in per_model.values())} model calls")
    for model, (count, cost) in sorted(per_model.items()):
        shown = "no price in PRICES, not counted" if cost is None else f"${cost:.2f}"
        print(f"  {model:<20}{count:>4} calls  {shown}")
    print(f"  total ${total:.2f} of the ${DAILY_CAP:.2f} daily cap")
    sys.exit(total > DAILY_CAP)


if __name__ == "__main__":
    main()
