#!/usr/bin/env python3
"""
Polymarket BTC UP/DOWN 5m background tracker.
Saves price history to JSON files so you can upload to the backtest website.

Usage:
  pip install requests
  python tracker.py

Files are saved as: pm_session_<slug>.json
"""

import json, math, time, os, sys, threading
from datetime import datetime

try:
    import requests
except ImportError:
    print("Install requests first: pip install requests")
    sys.exit(1)

GAMMA_API = "https://gamma-api.polymarket.com"
CLOB_API  = "https://clob.polymarket.com"
POLL_S    = 2  # poll every 2 seconds

def current_resolution_ts():
    now = int(time.time())
    return math.ceil(now / 300) * 300

def market_slug(ts):
    return f"btc-up-or-down-in-5-minutes-{ts}"

def fetch_market(slug):
    try:
        r = requests.get(f"{GAMMA_API}/markets", params={"slug": slug}, timeout=5)
        data = r.json()
        if isinstance(data, list) and data:
            return data[0]
        if isinstance(data, dict) and data:
            return data
    except Exception as e:
        print(f"  [WARN] fetch_market error: {e}")
    return None

def find_token_ids(market):
    tokens = market.get("tokens", [])
    up_id, down_id = None, None
    for t in tokens:
        outcome = (t.get("outcome") or "").lower()
        tid = t.get("token_id") or t.get("tokenId")
        if outcome == "up": up_id = tid
        elif outcome == "down": down_id = tid
    # fallback
    if not up_id and tokens: up_id = tokens[0].get("token_id") or tokens[0].get("tokenId")
    if not down_id and len(tokens) > 1: down_id = tokens[1].get("token_id") or tokens[1].get("tokenId")
    return str(up_id) if up_id else None, str(down_id) if down_id else None

def fetch_midpoint(token_id):
    if not token_id:
        return None
    try:
        r = requests.get(f"{CLOB_API}/midpoints", params={"token_id": token_id}, timeout=5)
        data = r.json()
        mid = data.get("mid") or data.get(token_id)
        return float(mid) if mid else None
    except:
        return None

def save_session(session, output_dir="."):
    slug = session["slug"]
    filename = os.path.join(output_dir, f"pm_session_{slug}.json")
    # If file exists, load and merge (avoid duplicates by timestamp)
    if os.path.exists(filename):
        try:
            with open(filename) as f:
                existing = json.load(f)
            existing_ts = {p["t"] for p in existing.get("priceHistory", [])}
            for p in session["priceHistory"]:
                if p["t"] not in existing_ts:
                    existing["priceHistory"].append(p)
            session = existing
        except:
            pass
    with open(filename, "w") as f:
        json.dump(session, f, indent=2)
    return filename

def track_market(slug, resolution_ts, output_dir="."):
    print(f"\n{'='*60}")
    print(f"Tracking: {slug}")
    print(f"Resolution: {datetime.fromtimestamp(resolution_ts)}")
    print(f"{'='*60}")

    market = fetch_market(slug)
    if not market:
        print(f"  [ERROR] Market not found: {slug}")
        return None

    up_id, down_id = find_token_ids(market)
    print(f"  UP token:   {up_id}")
    print(f"  DOWN token: {down_id}")

    session = {
        "slug": slug,
        "resolutionTs": resolution_ts,
        "question": market.get("question", ""),
        "outcome": None,
        "priceHistory": [],
    }

    while True:
        now = int(time.time())
        elapsed = max(0, min(300, 300 - (resolution_ts - now)))
        remaining = max(0, resolution_ts - now)

        up_price = fetch_midpoint(up_id)
        down_price = fetch_midpoint(down_id)
        if up_price is None and down_price is not None:
            up_price = 1 - down_price
        if down_price is None and up_price is not None:
            down_price = 1 - up_price

        point = {
            "t": now,
            "elapsed": elapsed,
            "up": up_price,
            "down": down_price,
        }
        session["priceHistory"].append(point)

        up_str = f"{up_price:.4f}" if up_price is not None else "N/A"
        down_str = f"{down_price:.4f}" if down_price is not None else "N/A"
        print(f"  [{elapsed:>3}s elapsed | {remaining:>3}s left] UP={up_str}  DOWN={down_str}  pts={len(session['priceHistory'])}", end="\r")

        # Save every 30 data points
        if len(session["priceHistory"]) % 30 == 0:
            save_session(session, output_dir)

        if remaining <= 0:
            print()
            print(f"  Market resolved! ({len(session['priceHistory'])} points collected)")
            break

        time.sleep(POLL_S)

    # Final save
    filename = save_session(session, output_dir)
    print(f"  Saved: {filename}")

    # Ask for outcome
    print("\n  What was the outcome? (u=UP / d=DOWN / skip=Enter): ", end="", flush=True)
    try:
        answer = input().strip().lower()
        if answer in ("u", "up"):
            session["outcome"] = "UP"
        elif answer in ("d", "down"):
            session["outcome"] = "DOWN"
        if session["outcome"]:
            save_session(session, output_dir)
            print(f"  Outcome '{session['outcome']}' saved.")
    except:
        pass

    return session

def main():
    print("Polymarket BTC 5m Tracker")
    print(f"Saving files to: {os.path.abspath('.')}")
    print("Press Ctrl+C to stop.\n")

    while True:
        ts = current_resolution_ts()
        slug = market_slug(ts)

        # Wait if we're in the gap between markets
        now = int(time.time())
        if ts - now > 300:
            print(f"Waiting for market {slug} (starts in {ts - now - 300}s)...")
            time.sleep(5)
            continue

        track_market(slug, ts)

        # Small gap before next market
        time.sleep(3)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nTracker stopped.")
