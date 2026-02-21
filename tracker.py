import json, math, time, os, sys, threading, argparse
from datetime import datetime

try:
    import requests
    from requests.adapters import HTTPAdapter
    from urllib3.util.retry import Retry
except ImportError:
    print("pip install requests"); sys.exit(1)

try:
    import websocket
except ImportError:
    print("pip install websocket-client"); sys.exit(1)

http = requests.Session()
retry = Retry(total=3, backoff_factor=0.3, status_forcelist=[500,502,503,504])
http.mount("https://", HTTPAdapter(max_retries=retry))

GAMMA  = "https://gamma-api.polymarket.com"
WS_URL = "wss://ws-subscriptions-clob.polymarket.com/ws/market"

def fetch_market(slug):
    try:
        r = http.get(f"{GAMMA}/markets", params={"slug": slug}, timeout=8)
        r.raise_for_status()
        data = r.json()
        m = data[0] if isinstance(data, list) and data else data
        if not m: return None
        
        raw = m.get("clobTokenIds", "[]")
        token_ids = json.loads(raw) if isinstance(raw, str) else raw
        outcomes  = m.get("outcomes", [])
        if isinstance(outcomes, str): outcomes = json.loads(outcomes)
        
        tokens_info = []
        for i, tid in enumerate(token_ids):
            name = outcomes[i] if i < len(outcomes) else f"Token_{i}"
            tokens_info.append({"id": str(tid), "name": name})

        winner = None
        for t in m.get("tokens", []):
            if t.get("winner"):
                winner = t.get("outcome", "").upper()
                break

        # Parse endDate to get resolution timestamp
        end_date_str = m.get("endDate")
        res_ts = 0
        if end_date_str:
            try:
                clean_date = end_date_str.split(".")[0].replace("Z", "")
                res_ts = int(datetime.strptime(clean_date, "%Y-%m-%dT%H:%M:%S").timestamp())
            except Exception:
                pass
        
        if not res_ts:
            res_ts = int(time.time()) + 3600 # Fallback 1 hour if no end date

        return {
            "slug": m.get("slug", slug),
            "question": m.get("question",""),
            "tokens": tokens_info,
            "closed": m.get("closed", False),
            "winner": winner,
            "res_ts": res_ts
        }
    except Exception as e:
        print(f"\n  [ERROR] fetch_market: {e}")
        return None

def poll_gamma_outcome(slug, max_attempts=20, interval=3):
    print(f"\n  Polling Gamma API for winner ({max_attempts*interval}s max)...", end="", flush=True)
    for i in range(max_attempts):
        if i > 0: time.sleep(interval)
        try:
            m = fetch_market(slug)
            if m and m.get("closed") and m.get("winner"):
                w = m["winner"].upper()
                print(f" -> {w}")
                return w
        except Exception: pass
        print(".", end="", flush=True)
    print(" timed out")
    return None

def save_session(sd, output_dir="."):
    slug = sd["slug"]
    fn   = os.path.join(output_dir, f"pm_session_{slug}.json")
    if os.path.exists(fn):
        try:
            with open(fn) as f: existing = json.load(f)
            seen = {p["t"] for p in existing.get("priceHistory",[])}
            for p in sd["priceHistory"]:
                if p["t"] not in seen: existing["priceHistory"].append(p)
            if existing.get("outcome") and not sd.get("outcome"):
                sd["outcome"] = existing["outcome"]
            sd["priceHistory"] = sorted(existing["priceHistory"], key=lambda x: x["t"])
        except Exception: pass
    with open(fn, "w") as f: json.dump(sd, f, indent=2)
    return fn

def track_market(slug):
    print(f"\n{'='*70}")
    print(f"  Fetching : {slug}")
    m = fetch_market(slug)
    if not m:
        print("  [SKIP] Market not found"); return None
        
    print(f"  Question : {m['question']}")
    print(f"  Tokens   : {', '.join([t['name'] for t in m['tokens']])}")
    print(f"{'='*70}")

    if m.get("closed") and m.get("winner"):
        print(f"  Already resolved: {m['winner']}")
        return None

    tokens = m["tokens"]
    if not tokens:
        print("  [ERROR] No tokens found"); return None

    res_ts = m["res_ts"]
    sd = {"slug": slug, "resolutionTs": res_ts,
          "question": m["question"], "outcome": None, "priceHistory": []}

    # Setup price tracking for all token IDs dynamically
    prices = {t["id"]: None for t in tokens}
    ws_lock = threading.Lock()
    done_event = threading.Event()

    def on_ws_message(ws, raw):
        try:
            msgs = json.loads(raw)
            if not isinstance(msgs, list): msgs = [msgs]
            for msg in msgs:
                asset = msg.get("asset_id") or msg.get("assetId") or msg.get("token_id")
                price = msg.get("price") or msg.get("outcome_price") or msg.get("mid")
                if not asset or price is None: continue
                p = float(price)
                if not (0.001 < p < 0.999): continue
                
                with ws_lock:
                    if asset in prices:
                        prices[asset] = round(p, 6)
        except Exception: pass

    def on_ws_open(ws):
        sub = json.dumps({"assets_ids": [t["id"] for t in tokens], "type": "Market"})
        ws.send(sub)

    def on_ws_error(ws, err):
        pass # Suppress noisy WS errors in console

    def run_ws():
        while not done_event.is_set():
            try:
                ws = websocket.WebSocketApp(WS_URL,
                    on_open=on_ws_open, on_message=on_ws_message, on_error=on_ws_error)
                ws.run_forever(ping_interval=20, ping_timeout=10)
            except Exception as e:
                pass
            if not done_event.is_set(): time.sleep(2)

    ws_thread = threading.Thread(target=run_ws, daemon=True)
    ws_thread.start()

    last_save = time.time()
    start_time = int(time.time())

    while True:
        now       = int(time.time())
        remaining = max(0, res_ts - now)
        elapsed   = now - start_time

        with ws_lock:
            current_prices = dict(prices)

        point = {"t": now, "elapsed": elapsed}
        # Add all token prices to the history point
        for t in tokens:
            point[t["name"]] = current_prices[t["id"]]
            
        sd["priceHistory"].append(point)

        # Format price strings for console
        price_strs = []
        for t in tokens:
            p = current_prices[t["id"]]
            p_str = f"{p:.3f}" if p is not None else "---"
            price_strs.append(f"{t['name'][:8]}={p_str}")
        
        p_line = "  ".join(price_strs)
        print(f"\r  [{elapsed:>4}s] {p_line} | pts={len(sd['priceHistory'])} rem={remaining}s   ", end="", flush=True)

        if time.time() - last_save >= 30:
            save_session(sd); last_save = time.time()

        if remaining <= 0:
            print()
            done_event.set()
            outcome = poll_gamma_outcome(slug)
            if not outcome:
                ans = input(f"  Manual Outcome (Enter to skip): ").strip()
                if ans: outcome = ans.upper()
            if outcome: sd["outcome"] = outcome
            break

        time.sleep(1)

    fn = save_session(sd)
    print(f"  Saved: {fn}")
    return sd

def main():
    p = argparse.ArgumentParser(description="Universal Polymarket Tracker")
    p.add_argument("market", nargs="?", help="Market slug or full URL")
    args = p.parse_args()

    if not args.market:
        market_input = input("Enter Polymarket slug or full URL: ").strip()
    else:
        market_input = args.market

    if not market_input:
        print("No market provided. Exiting.")
        return

    # Extract the slug if a full URL was pasted
    slug = market_input.split("/")[-1] if "/" in market_input else market_input
    
    try:
        track_market(slug)
    except KeyboardInterrupt:
        print("\n\nStopped.")

if __name__ == "__main__":
    main()
