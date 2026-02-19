import json, math, time, os, sys

try:
    import requests
    from requests.adapters import HTTPAdapter
    from urllib3.util.retry import Retry
except ImportError:
    print("Install requests: pip install requests")
    sys.exit(1)

session = requests.Session()
retry = Retry(total=3, backoff_factor=0.3, status_forcelist=[500, 502, 503, 504])
session.mount("https://", HTTPAdapter(max_retries=retry))

GAMMA = "https://gamma-api.polymarket.com"
CLOB  = "https://clob.polymarket.com"
POLL  = 1

def current_slug_ts():
    """Return the START timestamp of the current 5-minute window (what Polymarket uses in slug)."""
    now = int(time.time())
    return math.floor(now / 300) * 300  # floor = start of window

def resolution_ts(slug_ts):
    """Market resolves 5 minutes after slug start."""
    return slug_ts + 300

def market_slug(slug_ts):
    return f"btc-updown-5m-{slug_ts}"

def valid_price(v):
    try:
        f = float(v)
        return round(f, 6) if 0.001 < f < 1.0 else None
    except (TypeError, ValueError):
        return None

def fetch_market(slug):
    try:
        r = session.get(f"{GAMMA}/markets", params={"slug": slug}, timeout=8)
        r.raise_for_status()
        data = r.json()
        market = data[0] if isinstance(data, list) and data else data
        if not market:
            return None
        raw = market.get("clobTokenIds", "[]")
        token_ids = json.loads(raw) if isinstance(raw, str) else raw
        outcomes = market.get("outcomes", [])
        if isinstance(outcomes, str):
            outcomes = json.loads(outcomes)
        up_id, down_id = None, None
        for i, o in enumerate(outcomes):
            if o.lower() in ("up","yes") and i < len(token_ids):
                up_id = str(token_ids[i])
            elif o.lower() in ("down","no") and i < len(token_ids):
                down_id = str(token_ids[i])
        if not up_id   and len(token_ids) > 0: up_id   = str(token_ids[0])
        if not down_id and len(token_ids) > 1: down_id = str(token_ids[1])
        return {"slug": market.get("slug", slug), "question": market.get("question",""), "up_id": up_id, "down_id": down_id}
    except Exception as e:
        print(f"\n  [ERROR] fetch_market: {e}")
        return None

def fetch_price(token_id):
    if not token_id: return None
    try:
        r = session.get(f"{CLOB}/midpoints", params={"token_id": token_id}, timeout=4)
        if r.ok:
            d = r.json()
            p = valid_price(d.get("mid") or d.get(token_id) or d.get("midpoint"))
            if p: return p
    except Exception: pass
    try:
        r = session.get(f"{CLOB}/price", params={"token_id": token_id, "side": "buy"}, timeout=4)
        if r.ok:
            p = valid_price(r.json().get("price"))
            if p: return p
    except Exception: pass
    try:
        r = session.get(f"{CLOB}/book", params={"token_id": token_id}, timeout=4)
        if r.ok:
            d = r.json()
            bid = valid_price(d["bids"][0]["price"]) if d.get("bids") else None
            ask = valid_price(d["asks"][0]["price"]) if d.get("asks") else None
            if bid and ask: return round((bid+ask)/2, 6)
            return bid or ask
    except Exception: pass
    return None

def poll_for_outcome(up_id, down_id, max_attempts=20, interval=3):
    print(f"\n  Polling for settlement (up to {max_attempts*interval}s)...", end="", flush=True)
    for i in range(max_attempts):
        if i > 0: time.sleep(interval)
        up_price   = fetch_price(up_id)
        down_price = fetch_price(down_id)
        if up_price is None and down_price is not None:
            up_price = round(1 - down_price, 6)
        if down_price is None and up_price is not None:
            down_price = round(1 - up_price, 6)
        if up_price and up_price >= 0.90:
            print(f" -> UP ({up_price:.4f})")
            return "UP"
        if down_price and down_price >= 0.90:
            print(f" -> DOWN ({down_price:.4f})")
            return "DOWN"
        print(".", end="", flush=True)
    print(" timed out")
    return None

def save_session(session_data, output_dir="."):
    slug = session_data["slug"]
    filename = os.path.join(output_dir, f"pm_session_{slug}.json")
    if os.path.exists(filename):
        try:
            with open(filename) as f:
                existing = json.load(f)
            existing_ts = {p["t"] for p in existing.get("priceHistory", [])}
            for p in session_data["priceHistory"]:
                if p["t"] not in existing_ts:
                    existing["priceHistory"].append(p)
            if existing.get("outcome") and not session_data.get("outcome"):
                session_data["outcome"] = existing["outcome"]
            session_data["priceHistory"] = sorted(existing["priceHistory"], key=lambda x: x["t"])
        except Exception: pass
    with open(filename, "w") as f:
        json.dump(session_data, f, indent=2)
    return filename

def track_market(slug_ts):
    slug   = market_slug(slug_ts)
    res_ts = resolution_ts(slug_ts)

    print(f"\n{'='*60}")
    print(f"  Slug      : {slug}")
    print(f"  Slug ts   : {slug_ts} (window start)")
    print(f"  Resolves  : {res_ts} (window end / +300s)")
    print(f"{'='*60}")

    market = fetch_market(slug)
    if not market:
        print("  [SKIP] Market not found.")
        return None

    up_id   = market["up_id"]
    down_id = market["down_id"]
    print(f"  UP   token: {up_id}")
    print(f"  DOWN token: {down_id}\n")
    if not up_id:
        print("  [ERROR] No UP token ID.")
        return None

    session_data = {
        "slug": slug, "slugTs": slug_ts, "resolutionTs": res_ts,
        "question": market["question"], "outcome": None, "priceHistory": [],
    }
    last_save = time.time()

    while True:
        now       = int(time.time())
        remaining = max(0, res_ts - now)
        elapsed   = min(300, 300 - remaining)

        up_price   = fetch_price(up_id)
        down_price = fetch_price(down_id)
        if up_price is not None and down_price is None:
            down_price = round(1 - up_price, 6)
        if down_price is not None and up_price is None:
            up_price = round(1 - down_price, 6)

        point = {"t": now, "elapsed": elapsed, "up": up_price, "down": down_price}
        session_data["priceHistory"].append(point)

        up_str   = f"{up_price:.4f}"   if up_price   is not None else "NULL"
        down_str = f"{down_price:.4f}" if down_price is not None else "NULL"
        bar = chr(9608) * int((elapsed/300)*20)
        print(f"\r  [{bar:<20}] {elapsed:>3}s  UP={up_str}  DOWN={down_str}  pts={len(session_data['priceHistory'])}  rem={remaining}s   ", end="", flush=True)

        if time.time() - last_save >= 30:
            save_session(session_data)
            last_save = time.time()

        if remaining <= 0:
            print()
            outcome = poll_for_outcome(up_id, down_id)
            if not outcome:
                ans = input("  Manual: u=UP / d=DOWN / Enter to skip: ").strip().lower()
                if ans in ("u","up"):     outcome = "UP"
                elif ans in ("d","down"): outcome = "DOWN"
            if outcome:
                session_data["outcome"] = outcome
                print(f"  Final outcome: {outcome}")
            break
        time.sleep(POLL)

    filename = save_session(session_data)
    pts_ok = sum(1 for p in session_data["priceHistory"] if p["up"] is not None)
    print(f"  Saved: {filename}  ({len(session_data['priceHistory'])} pts, {pts_ok} priced)")
    return session_data

def debug_market(slug):
    print(f"\nDEBUG: {GAMMA}/markets?slug={slug}")
    r = session.get(f"{GAMMA}/markets", params={"slug": slug}, timeout=8)
    print(json.dumps(r.json(), indent=2)[:3000])

def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--debug-slug")
    parser.add_argument("--slug")
    args = parser.parse_args()

    if args.debug_slug:
        debug_market(args.debug_slug); return
    if args.slug:
        ts_str = args.slug.replace("btc-updown-5m-","")
        try: slug_ts = int(ts_str)
        except: print("Cannot parse timestamp from slug"); return
        track_market(slug_ts); return

    print("Polymarket BTC 5m Tracker -- Ctrl+C to stop")
    print(f"Output: {os.path.abspath('.')}\n")
    print("NOTE: Slugs use window START time (floor). Resolution = slug_ts + 300.\n")

    while True:
        slug_ts = current_slug_ts()
        slug    = market_slug(slug_ts)
        res_ts  = resolution_ts(slug_ts)
        now     = int(time.time())
        remaining = max(0, res_ts - now)

        if remaining <= 0:
            # Window already ended, wait for next
            next_slug_ts = slug_ts + 300
            wait = next_slug_ts - now
            print(f"Waiting {wait}s for next window: {market_slug(next_slug_ts)}", end="\r")
            time.sleep(2)
            continue

        track_market(slug_ts)
        print("\nWaiting 3s...\n")
        time.sleep(3)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nTracker stopped.")
