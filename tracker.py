import json, math, time, os, sys, threading

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
CLOB   = "https://clob.polymarket.com"
WS_URL = "wss://ws-subscriptions-clob.polymarket.com/ws/market"

def current_slug_ts():
    return math.floor(time.time() / 300) * 300

def resolution_ts(slug_ts):
    return slug_ts + 300

def market_slug(slug_ts):
    return f"btc-updown-5m-{slug_ts}"

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
        up_id, down_id = None, None
        for i, o in enumerate(outcomes):
            if o.lower() in ("up","yes")   and i < len(token_ids): up_id   = str(token_ids[i])
            if o.lower() in ("down","no")  and i < len(token_ids): down_id = str(token_ids[i])
        if not up_id   and len(token_ids) > 0: up_id   = str(token_ids[0])
        if not down_id and len(token_ids) > 1: down_id = str(token_ids[1])

        # Check if already resolved
        winner = None
        for t in m.get("tokens", []):
            if t.get("winner"):
                winner = t.get("outcome","").upper()
                break

        return {
            "slug": m.get("slug", slug),
            "question": m.get("question",""),
            "up_id":  up_id,
            "down_id": down_id,
            "closed": m.get("closed", False),
            "winner": winner,
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
                if w in ("UP","DOWN"):
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

def track_market(slug_ts):
    slug   = market_slug(slug_ts)
    res_ts = resolution_ts(slug_ts)

    print(f"\n{'='*60}")
    print(f"  Slug     : {slug}")
    print(f"  Resolves : {res_ts}")
    print(f"{'='*60}")

    m = fetch_market(slug)
    if not m:
        print("  [SKIP] Not found"); return None
    if m.get("closed") and m.get("winner"):
        print(f"  Already resolved: {m['winner']}")
        return None

    up_id, down_id = m["up_id"], m["down_id"]
    print(f"  UP   token: {up_id}")
    print(f"  DOWN token: {down_id}\n")
    if not up_id:
        print("  [ERROR] No UP token"); return None

    sd = {"slug": slug, "slugTs": slug_ts, "resolutionTs": res_ts,
          "question": m["question"], "outcome": None, "priceHistory": []}

    # ── WebSocket price feed ───────────────────────────────────────────────
    prices = {"up": None, "down": None}
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
                    if asset == up_id:
                        prices["up"]   = round(p, 6)
                        prices["down"] = round(1-p, 6)
                    elif asset == down_id:
                        prices["down"] = round(p, 6)
                        prices["up"]   = round(1-p, 6)
        except Exception: pass

    def on_ws_open(ws):
        sub = json.dumps({"assets_ids": [x for x in [up_id, down_id] if x], "type": "Market"})
        ws.send(sub)

    def on_ws_error(ws, err):
        print(f"\n  [WS ERROR] {err}")

    def run_ws():
        while not done_event.is_set():
            try:
                ws = websocket.WebSocketApp(WS_URL,
                    on_open=on_ws_open, on_message=on_ws_message, on_error=on_ws_error)
                ws.run_forever(ping_interval=20, ping_timeout=10)
            except Exception as e:
                print(f"\n  [WS] reconnecting ({e})")
            if not done_event.is_set(): time.sleep(2)

    ws_thread = threading.Thread(target=run_ws, daemon=True)
    ws_thread.start()

    last_save = time.time()

    while True:
        now       = int(time.time())
        remaining = max(0, res_ts - now)
        elapsed   = min(300, 300 - remaining)

        with ws_lock:
            up_price   = prices["up"]
            down_price = prices["down"]

        point = {"t": now, "elapsed": elapsed, "up": up_price, "down": down_price}
        sd["priceHistory"].append(point)

        up_str   = f"{up_price:.4f}"   if up_price   is not None else "NULL"
        down_str = f"{down_price:.4f}" if down_price is not None else "NULL"
        bar = chr(9608) * int((elapsed/300)*20)
        print(f"\r  [{bar:<20}] {elapsed:>3}s  UP={up_str}  DOWN={down_str}  pts={len(sd['priceHistory'])}  rem={remaining}s   ",
              end="", flush=True)

        if time.time() - last_save >= 30:
            save_session(sd); last_save = time.time()

        if remaining <= 0:
            print()
            done_event.set()  # stop WS thread
            outcome = poll_gamma_outcome(slug)
            if not outcome:
                ans = input("  Manual u=UP / d=DOWN / Enter skip: ").strip().lower()
                if ans in ("u","up"):     outcome = "UP"
                elif ans in ("d","down"): outcome = "DOWN"
            if outcome: sd["outcome"] = outcome
            break

        time.sleep(1)

    fn = save_session(sd)
    ok = sum(1 for p in sd["priceHistory"] if p["up"] is not None)
    print(f"  Saved: {fn}  ({len(sd['priceHistory'])} pts, {ok} priced)")
    return sd

def main():
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--slug")
    args = p.parse_args()

    if args.slug:
        ts_str = args.slug.replace("btc-updown-5m-","")
        try: slug_ts = int(ts_str)
        except: print("Bad slug"); return
        track_market(slug_ts); return

    print("Polymarket BTC 5m Tracker (WebSocket) -- Ctrl+C to stop\n")
    while True:
        slug_ts = current_slug_ts()
        res_ts  = resolution_ts(slug_ts)
        remaining = max(0, res_ts - int(time.time()))
        if remaining <= 0:
            time.sleep(2); continue
        track_market(slug_ts)
        print("\nWaiting 3s for next market...\n")
        time.sleep(3)

if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: print("\n\nStopped.")
