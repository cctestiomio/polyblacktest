# fix2.ps1
# Run from inside your polymarket-btc-backtest folder:
#   .\fix2.ps1
# Fixes:
#   1. Python tracker: correct token ID parsing, 1s polling, working price fetch
#   2. Next.js API routes: robust token ID + midpoint parsing
#   3. LiveTracker: better token ID resolution matching actual Gamma API shape

Write-Host "Applying price-tracking fixes..." -ForegroundColor Cyan

# ── tracker.py — full rewrite ─────────────────────────────────────────────────
@'
#!/usr/bin/env python3
"""
Polymarket BTC UP/DOWN 5m background tracker.
Polls every 1 second. Saves price history per slug to JSON.

Usage:
  pip install requests
  python tracker.py

Output files: pm_session_btc-updown-5m-{ts}.json
"""

import json, math, time, os, sys

try:
    import requests
    from requests.adapters import HTTPAdapter
    from urllib3.util.retry import Retry
except ImportError:
    print("Install requests: pip install requests")
    sys.exit(1)

# ── HTTP session with retries ──────────────────────────────────────────────────
session = requests.Session()
retry = Retry(total=3, backoff_factor=0.3, status_forcelist=[500, 502, 503, 504])
session.mount("https://", HTTPAdapter(max_retries=retry))

GAMMA = "https://gamma-api.polymarket.com"
CLOB  = "https://clob.polymarket.com"
POLL  = 1  # seconds between price polls

# ── helpers ────────────────────────────────────────────────────────────────────
def current_resolution_ts():
    return math.ceil(time.time() / 300) * 300

def market_slug(ts):
    return f"btc-updown-5m-{ts}"

def fetch_market(slug):
    """Fetch market from Gamma API and return normalised token dict."""
    try:
        r = session.get(f"{GAMMA}/markets", params={"slug": slug}, timeout=8)
        r.raise_for_status()
        data = r.json()
        market = data[0] if isinstance(data, list) and data else data
        if not market:
            return None

        # clobTokenIds is sometimes a JSON-encoded string like '["id1","id2"]'
        raw = market.get("clobTokenIds", "[]")
        if isinstance(raw, str):
            try:
                token_ids = json.loads(raw)
            except Exception:
                token_ids = []
        else:
            token_ids = raw  # already a list

        outcomes = market.get("outcomes", [])
        if isinstance(outcomes, str):
            try:
                outcomes = json.loads(outcomes)
            except Exception:
                outcomes = []

        # Build up_id / down_id from outcomes list
        up_id, down_id = None, None
        for i, outcome in enumerate(outcomes):
            if outcome.lower() in ("up", "yes") and i < len(token_ids):
                up_id = str(token_ids[i])
            elif outcome.lower() in ("down", "no") and i < len(token_ids):
                down_id = str(token_ids[i])

        # Fallback: first = UP, second = DOWN
        if not up_id and len(token_ids) > 0:
            up_id = str(token_ids[0])
        if not down_id and len(token_ids) > 1:
            down_id = str(token_ids[1])

        return {
            "slug": market.get("slug", slug),
            "question": market.get("question", ""),
            "up_id": up_id,
            "down_id": down_id,
        }
    except Exception as e:
        print(f"\n  [ERROR] fetch_market: {e}")
        return None

def fetch_price(token_id):
    """
    Try multiple CLOB endpoints to get the midpoint price.
    Returns float 0-1 or None.
    """
    if not token_id:
        return None

    # 1. Midpoints endpoint
    try:
        r = session.get(f"{CLOB}/midpoints", params={"token_id": token_id}, timeout=4)
        if r.ok:
            data = r.json()
            # Response shape varies: {"mid":"0.52"} or {token_id: "0.52"} or {"midpoint":"0.52"}
            mid = data.get("mid") or data.get(token_id) or data.get("midpoint")
            if mid is not None:
                return round(float(mid), 6)
    except Exception:
        pass

    # 2. Price endpoint (last trade price)
    try:
        r = session.get(f"{CLOB}/price", params={"token_id": token_id, "side": "buy"}, timeout=4)
        if r.ok:
            data = r.json()
            price = data.get("price")
            if price is not None:
                return round(float(price), 6)
    except Exception:
        pass

    # 3. Order book best bid/ask midpoint
    try:
        r = session.get(f"{CLOB}/book", params={"token_id": token_id}, timeout=4)
        if r.ok:
            data = r.json()
            bids = data.get("bids", [])
            asks = data.get("asks", [])
            best_bid = float(bids[0]["price"]) if bids else None
            best_ask = float(asks[0]["price"]) if asks else None
            if best_bid and best_ask:
                return round((best_bid + best_ask) / 2, 6)
            elif best_bid:
                return round(best_bid, 6)
            elif best_ask:
                return round(best_ask, 6)
    except Exception:
        pass

    return None

def save_session(session_data, output_dir="."):
    slug = session_data["slug"]
    filename = os.path.join(output_dir, f"pm_session_{slug}.json")
    # Merge with existing file to avoid losing data if script restarts
    if os.path.exists(filename):
        try:
            with open(filename) as f:
                existing = json.load(f)
            existing_ts = {p["t"] for p in existing.get("priceHistory", [])}
            for p in session_data["priceHistory"]:
                if p["t"] not in existing_ts:
                    existing["priceHistory"].append(p)
            # Carry over outcome if it was already set
            if existing.get("outcome") and not session_data.get("outcome"):
                session_data["outcome"] = existing["outcome"]
            session_data["priceHistory"] = sorted(
                existing["priceHistory"], key=lambda x: x["t"]
            )
        except Exception:
            pass

    with open(filename, "w") as f:
        json.dump(session_data, f, indent=2)
    return filename

def detect_outcome(up, down):
    if up is not None and up >= 0.95:
        return "UP"
    if down is not None and down >= 0.95:
        return "DOWN"
    if up is not None and down is not None:
        return "UP" if up > down else "DOWN"
    return None

def track_market(slug, resolution_ts):
    print(f"\n{'='*60}")
    print(f"  Market : {slug}")
    print(f"  Resolves at epoch {resolution_ts}")
    print(f"  Polling every {POLL}s")
    print(f"{'='*60}")

    market = fetch_market(slug)
    if not market:
        print(f"  [SKIP] Market not found or not yet listed.")
        return None

    up_id   = market["up_id"]
    down_id = market["down_id"]
    print(f"  UP token  : {up_id}")
    print(f"  DOWN token: {down_id}")
    print()

    if not up_id:
        print("  [ERROR] Could not determine UP token ID.")
        return None

    session_data = {
        "slug": slug,
        "resolutionTs": resolution_ts,
        "question": market["question"],
        "outcome": None,
        "priceHistory": [],
    }

    last_save = time.time()

    while True:
        now     = int(time.time())
        elapsed = max(0, min(300, 300 - (resolution_ts - now)))
        remaining = max(0, resolution_ts - now)

        up_price   = fetch_price(up_id)
        down_price = fetch_price(down_id)

        # If one is missing, infer from the other
        if up_price is not None and down_price is None:
            down_price = round(1 - up_price, 6)
        if down_price is not None and up_price is None:
            up_price = round(1 - down_price, 6)

        point = {
            "t": now,
            "elapsed": elapsed,
            "up": up_price,
            "down": down_price,
        }
        session_data["priceHistory"].append(point)

        up_str   = f"{up_price:.4f}"   if up_price   is not None else "NULL"
        down_str = f"{down_price:.4f}" if down_price is not None else "NULL"

        bar = "█" * int((elapsed / 300) * 20)
        print(
            f"\r  [{bar:<20}] {elapsed:>3}s  "
            f"UP={up_str}  DOWN={down_str}  "
            f"pts={len(session_data['priceHistory'])}  rem={remaining}s   ",
            end="", flush=True,
        )

        # Save every 30s
        if time.time() - last_save >= 30:
            save_session(session_data)
            last_save = time.time()

        if remaining <= 0:
            print()
            # Auto-detect outcome from final price
            outcome = detect_outcome(up_price, down_price)
            if outcome:
                session_data["outcome"] = outcome
                print(f"\n  ✅ Auto-detected outcome: {outcome}")
            else:
                print("\n  ⚠  Could not auto-detect outcome (prices still null at resolution)")
                ans = input("  Manual: enter u=UP / d=DOWN / skip Enter: ").strip().lower()
                if ans in ("u","up"):
                    session_data["outcome"] = "UP"
                elif ans in ("d","down"):
                    session_data["outcome"] = "DOWN"
            break

        time.sleep(POLL)

    filename = save_session(session_data)
    pts_with_price = sum(1 for p in session_data["priceHistory"] if p["up"] is not None)
    print(f"  Saved: {filename}")
    print(f"  Points total: {len(session_data['priceHistory'])}  |  Points with price: {pts_with_price}")
    return session_data

def debug_market(slug):
    """Print raw API response for a slug — useful for debugging token IDs."""
    print(f"\nDEBUG: {GAMMA}/markets?slug={slug}")
    r = session.get(f"{GAMMA}/markets", params={"slug": slug}, timeout=8)
    print(f"Status: {r.status_code}")
    print(json.dumps(r.json(), indent=2)[:3000])

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Polymarket BTC 5m tracker")
    parser.add_argument("--debug-slug", help="Print raw API response for a slug and exit")
    parser.add_argument("--slug", help="Track a specific slug once and exit")
    args = parser.parse_args()

    if args.debug_slug:
        debug_market(args.debug_slug)
        return

    if args.slug:
        ts_str = args.slug.replace("btc-updown-5m-", "")
        try:
            ts = int(ts_str)
        except ValueError:
            print("Could not parse timestamp from slug")
            return
        track_market(args.slug, ts)
        return

    print("Polymarket BTC 5m Tracker — Ctrl+C to stop")
    print(f"Output directory: {os.path.abspath('.')}\n")

    while True:
        ts   = current_resolution_ts()
        slug = market_slug(ts)
        now  = int(time.time())

        # If we're more than 300s before resolution, the market hasn't opened yet
        if ts - now > 305:
            wait = ts - now - 300
            print(f"Waiting {wait}s for market to open: {slug}", end="\r")
            time.sleep(5)
            continue

        track_market(slug, ts)
        print("\nWaiting 3s before next market...")
        time.sleep(3)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nTracker stopped.")
'@ | Set-Content "tracker.py"

# ── src/app/api/market/route.js — robust token parsing ───────────────────────
@'
export const runtime = "edge";

export async function GET(request) {
  const { searchParams } = new URL(request.url);
  const slug = searchParams.get("slug");
  if (!slug) return Response.json({ error: "no slug" }, { status: 400 });

  try {
    const res = await fetch(
      `https://gamma-api.polymarket.com/markets?slug=${encodeURIComponent(slug)}`,
      { headers: { Accept: "application/json" }, cf: { cacheTtl: 10 } }
    );
    const data = await res.json();
    const market = Array.isArray(data) ? data[0] : data;
    if (!market) return Response.json({ error: "not found" }, { status: 404 });

    // clobTokenIds is sometimes a JSON-encoded string
    let tokenIds = market.clobTokenIds ?? [];
    if (typeof tokenIds === "string") {
      try { tokenIds = JSON.parse(tokenIds); } catch { tokenIds = []; }
    }

    let outcomes = market.outcomes ?? [];
    if (typeof outcomes === "string") {
      try { outcomes = JSON.parse(outcomes); } catch { outcomes = []; }
    }

    // Build tokens array: [{outcome, token_id}]
    const tokens = tokenIds.map((id, i) => ({
      token_id: String(id),
      outcome: outcomes[i] ?? (i === 0 ? "Up" : "Down"),
    }));

    return Response.json({
      slug: market.slug,
      question: market.question,
      endDate: market.endDate,
      closed: market.closed,
      tokens,
      outcomes,
    });
  } catch (e) {
    return Response.json({ error: String(e) }, { status: 500 });
  }
}
'@ | Set-Content "src/app/api/market/route.js"

# ── src/app/api/midpoint/route.js — try 3 endpoints ─────────────────────────
@'
export const runtime = "edge";

async function tryMidpoints(tokenId) {
  const res = await fetch(
    `https://clob.polymarket.com/midpoints?token_id=${tokenId}`,
    { headers: { Accept: "application/json" } }
  );
  if (!res.ok) return null;
  const data = await res.json();
  const mid = data?.mid ?? data?.[tokenId] ?? data?.midpoint;
  return mid != null ? parseFloat(mid) : null;
}

async function tryPrice(tokenId) {
  const res = await fetch(
    `https://clob.polymarket.com/price?token_id=${tokenId}&side=buy`,
    { headers: { Accept: "application/json" } }
  );
  if (!res.ok) return null;
  const data = await res.json();
  return data?.price != null ? parseFloat(data.price) : null;
}

async function tryBook(tokenId) {
  const res = await fetch(
    `https://clob.polymarket.com/book?token_id=${tokenId}`,
    { headers: { Accept: "application/json" } }
  );
  if (!res.ok) return null;
  const data = await res.json();
  const bids = data?.bids ?? [];
  const asks = data?.asks ?? [];
  const bestBid = bids[0]?.price != null ? parseFloat(bids[0].price) : null;
  const bestAsk = asks[0]?.price != null ? parseFloat(asks[0].price) : null;
  if (bestBid != null && bestAsk != null) return (bestBid + bestAsk) / 2;
  return bestBid ?? bestAsk ?? null;
}

export async function GET(request) {
  const { searchParams } = new URL(request.url);
  const tokenId = searchParams.get("token_id");
  if (!tokenId) return Response.json({ error: "no token_id" }, { status: 400 });

  try {
    // Try endpoints in order until one returns a price
    const mid = await tryMidpoints(tokenId)
              ?? await tryPrice(tokenId)
              ?? await tryBook(tokenId);

    if (mid == null) {
      return Response.json({ mid: null, error: "no price found" }, { status: 404 });
    }
    return Response.json({ mid: mid.toFixed(6) });
  } catch (e) {
    return Response.json({ error: String(e) }, { status: 500 });
  }
}
'@ | Set-Content "src/app/api/midpoint/route.js"

# ── src/app/api/debug/route.js — debug endpoint to inspect raw market data ───
New-Item -ItemType Directory -Force -Path "src/app/api/debug" | Out-Null
@'
export const runtime = "edge";

export async function GET(request) {
  const { searchParams } = new URL(request.url);
  const slug = searchParams.get("slug");
  if (!slug) return Response.json({ error: "provide ?slug=btc-updown-5m-..." }, { status: 400 });

  const res = await fetch(
    `https://gamma-api.polymarket.com/markets?slug=${encodeURIComponent(slug)}`,
    { headers: { Accept: "application/json" } }
  );
  const raw = await res.json();
  return Response.json(raw);
}
'@ | Set-Content "src/app/api/debug/route.js"

# ── src/lib/polymarket.js — robust token resolution ──────────────────────────
@'
export function getCurrentMarketTimestamp() {
  return Math.ceil(Date.now() / 1000 / 300) * 300;
}

export function getMarketSlug(ts) {
  return `btc-updown-5m-${ts}`;
}

export function getSecondsRemaining(ts) {
  return Math.max(0, ts - Math.floor(Date.now() / 1000));
}

export function getSecondsElapsed(ts) {
  return Math.min(300, 300 - getSecondsRemaining(ts));
}

export async function fetchMarketBySlug(slug) {
  const res = await fetch(`/api/market?slug=${encodeURIComponent(slug)}`);
  if (!res.ok) return null;
  return res.json();
}

export async function fetchMidpoint(tokenId) {
  if (!tokenId) return null;
  const res = await fetch(`/api/midpoint?token_id=${encodeURIComponent(tokenId)}`);
  if (!res.ok) return null;
  const data = await res.json();
  return data.mid != null ? parseFloat(data.mid) : null;
}

/**
 * Extract UP and DOWN token IDs from the normalised market object.
 * Handles both {tokens:[{token_id, outcome}]} and {clobTokenIds, outcomes}.
 */
export function resolveTokenIds(market) {
  let upId = null, downId = null;

  const tokens = market.tokens ?? [];
  for (const t of tokens) {
    const o = (t.outcome ?? "").toLowerCase();
    const id = t.token_id ?? t.tokenId;
    if (!id) continue;
    if (o === "up")   upId   = String(id);
    if (o === "down") downId = String(id);
  }

  // Fallback: index 0 = UP, index 1 = DOWN
  if (!upId   && tokens[0]) upId   = String(tokens[0].token_id ?? tokens[0].tokenId ?? tokens[0]);
  if (!downId && tokens[1]) downId = String(tokens[1].token_id ?? tokens[1].tokenId ?? tokens[1]);

  return { upId, downId };
}

export function detectOutcome(up, down) {
  if (up  != null && up  >= 0.95) return "UP";
  if (down != null && down >= 0.95) return "DOWN";
  if (up != null && down != null) return up > down ? "UP" : "DOWN";
  return null;
}
'@ | Set-Content "src/lib/polymarket.js"

# ── src/components/LiveTracker.js — uses resolveTokenIds, logs token IDs ──────
@'
"use client";
import { useEffect, useRef, useState, useCallback } from "react";
import {
  LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid,
  ResponsiveContainer, ReferenceLine,
} from "recharts";
import {
  getCurrentMarketTimestamp, getMarketSlug, fetchMarketBySlug,
  fetchMidpoint, getSecondsElapsed, getSecondsRemaining,
  detectOutcome, resolveTokenIds,
} from "../lib/polymarket";

const POLL_MS = 1000; // 1 second
function pad(n) { return String(n).padStart(2, "0"); }
function fmtS(s) { return `${pad(Math.floor(s/60))}:${pad(s%60)}`; }

export default function LiveTracker({ onSaveSession }) {
  const [status, setStatus]             = useState("idle");
  const [market, setMarket]             = useState(null);
  const [tokenInfo, setTokenInfo]       = useState(null); // {upId, downId}
  const [priceHistory, setPriceHistory] = useState([]);
  const [elapsed, setElapsed]           = useState(0);
  const [remaining, setRemaining]       = useState(300);
  const [currentUp, setCurrentUp]       = useState(null);
  const [currentDown, setCurrentDown]   = useState(null);
  const [outcome, setOutcome]           = useState(null);
  const [errorMsg, setErrorMsg]         = useState("");
  const [manualSlug, setManualSlug]     = useState("");
  const [nextIn, setNextIn]             = useState(null);
  const [debugMsg, setDebugMsg]         = useState("");

  const intervalRef     = useRef(null);
  const marketRef       = useRef(null);
  const tokenRef        = useRef({ upId: null, downId: null });
  const historyRef      = useRef([]);
  const resolutionRef   = useRef(null);
  const savedRef        = useRef(false);

  const stopTracking = useCallback(() => {
    clearInterval(intervalRef.current);
    intervalRef.current = null;
  }, []);

  const doSave = useCallback((history, det) => {
    if (savedRef.current || !history.length || !marketRef.current) return;
    savedRef.current = true;
    onSaveSession({
      slug: marketRef.current.slug,
      resolutionTs: resolutionRef.current,
      question: marketRef.current.question,
      outcome: det,
      priceHistory: history,
      savedAt: Date.now(),
    });
  }, [onSaveSession]);

  const tick = useCallback(async () => {
    const rts = resolutionRef.current;
    if (!rts) return;
    const el  = getSecondsElapsed(rts);
    const rem = getSecondsRemaining(rts);
    setElapsed(el);
    setRemaining(rem);

    const { upId, downId } = tokenRef.current;
    if (!upId) {
      setDebugMsg("⚠ No UP token ID — check /api/debug?slug=... in browser");
      return;
    }

    try {
      const [up, down] = await Promise.all([
        fetchMidpoint(upId),
        downId ? fetchMidpoint(downId) : Promise.resolve(null),
      ]);

      const upP   = up;
      const downP = down ?? (up != null ? parseFloat((1 - up).toFixed(6)) : null);

      const point = { t: Math.floor(Date.now() / 1000), elapsed: el, up: upP, down: downP };
      const next  = [...historyRef.current, point];
      historyRef.current = next;
      setPriceHistory(next);
      setCurrentUp(upP);
      setCurrentDown(downP);

      if (upP != null) setDebugMsg("");

      if (rem <= 0) {
        const det = detectOutcome(upP, downP);
        setOutcome(det);
        setStatus("resolved");
        stopTracking();
        doSave(next, det);

        const nextTs = rts + 300;
        const cd = setInterval(() => {
          const sec = nextTs - Math.floor(Date.now() / 1000);
          setNextIn(Math.max(0, sec));
          if (sec <= 0) { clearInterval(cd); setNextIn(null); startTracking(); }
        }, 1000);
      }
    } catch (e) {
      console.error("tick", e);
    }
  }, [stopTracking, doSave]); // eslint-disable-line

  // eslint-disable-next-line
  const startTracking = useCallback(async (slugOverride) => {
    stopTracking();
    setStatus("loading");
    setErrorMsg("");
    setDebugMsg("");
    setPriceHistory([]);
    historyRef.current = [];
    setOutcome(null);
    setNextIn(null);
    savedRef.current = false;
    setCurrentUp(null);
    setCurrentDown(null);

    const rts  = getCurrentMarketTimestamp();
    resolutionRef.current = rts;
    const slug = slugOverride || getMarketSlug(rts);

    const m = await fetchMarketBySlug(slug);
    if (!m || m.error) {
      setErrorMsg(`Market not found: ${slug}`);
      setStatus("error");
      return;
    }

    const ids = resolveTokenIds(m);
    marketRef.current = m;
    tokenRef.current  = ids;
    setMarket(m);
    setTokenInfo(ids);
    setStatus("tracking");

    await tick();
    intervalRef.current = setInterval(tick, POLL_MS);
  }, [stopTracking, tick]);

  useEffect(() => { startTracking(); return stopTracking; }, []); // eslint-disable-line

  const chartData = priceHistory.map(p => ({
    elapsed: p.elapsed,
    UP:   p.up   != null ? +(p.up   * 100).toFixed(2) : null,
    DOWN: p.down != null ? +(p.down * 100).toFixed(2) : null,
  }));

  const statusCls = {
    tracking: "bg-green-100 text-green-700 dark:bg-green-900/60 dark:text-green-300",
    resolved: "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/60 dark:text-yellow-300",
    loading:  "bg-blue-100 text-blue-700 dark:bg-blue-900/60 dark:text-blue-300",
    error:    "bg-red-100 text-red-700 dark:bg-red-900/60 dark:text-red-300",
    idle:     "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400",
  }[status] ?? "";

  const ptsWithPrice = priceHistory.filter(p => p.up != null).length;

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex flex-wrap items-center gap-3">
        <div className="flex-1 min-w-0">
          <p className="text-xs text-slate-400 dark:text-slate-500 truncate font-mono">{market?.slug ?? "Searching…"}</p>
          <p className="text-sm text-slate-600 dark:text-slate-300 truncate">{market?.question ?? ""}</p>
        </div>
        <span className={`px-2 py-0.5 rounded text-xs font-bold ${statusCls}`}>{status.toUpperCase()}</span>
        <button onClick={() => startTracking()}
          className="px-3 py-1 bg-indigo-600 hover:bg-indigo-500 text-white rounded text-xs font-semibold">
          Refresh
        </button>
      </div>

      {/* Token IDs debug info */}
      {tokenInfo && (
        <div className="bg-slate-50 dark:bg-slate-900 border border-slate-200 dark:border-slate-800 rounded-lg px-3 py-2 text-xs font-mono text-slate-500 dark:text-slate-500 space-y-0.5">
          <div>UP token:   <span className="text-green-600 dark:text-green-400">{tokenInfo.upId ?? "NOT FOUND"}</span></div>
          <div>DOWN token: <span className="text-red-600 dark:text-red-400">{tokenInfo.downId ?? "NOT FOUND"}</span></div>
          <div>Priced pts: <span className="text-blue-600 dark:text-blue-400">{ptsWithPrice} / {priceHistory.length}</span></div>
        </div>
      )}

      {/* Manual slug */}
      <div className="flex gap-2">
        <input value={manualSlug} onChange={e => setManualSlug(e.target.value)}
          placeholder="btc-updown-5m-1771465500"
          className="flex-1 bg-white dark:bg-slate-800 border border-slate-300 dark:border-slate-600 rounded px-3 py-1.5 text-sm text-slate-800 dark:text-slate-200 placeholder-slate-400" />
        <button onClick={() => startTracking(manualSlug || undefined)}
          className="px-4 py-1.5 bg-slate-100 hover:bg-slate-200 dark:bg-slate-700 dark:hover:bg-slate-600 rounded text-sm font-semibold text-slate-700 dark:text-slate-200">
          Load
        </button>
      </div>

      {errorMsg && <p className="text-red-500 text-sm">{errorMsg}</p>}
      {debugMsg  && <p className="text-yellow-600 dark:text-yellow-400 text-xs">{debugMsg}</p>}

      {/* Stats */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <StatCard label="UP Price"   value={currentUp   != null ? `${(currentUp*100).toFixed(1)}¢`   : "—"} color="text-green-600 dark:text-green-400" />
        <StatCard label="DOWN Price" value={currentDown != null ? `${(currentDown*100).toFixed(1)}¢` : "—"} color="text-red-600 dark:text-red-400" />
        <StatCard label="Elapsed"    value={fmtS(elapsed)}   color="text-blue-600 dark:text-blue-400" />
        <StatCard label="Remaining"  value={fmtS(remaining)} color="text-orange-600 dark:text-orange-400" />
      </div>

      {/* Resolved banner */}
      {status === "resolved" && (
        <div className={`rounded-xl p-4 text-center font-bold text-lg border ${
          outcome === "UP"
            ? "bg-green-50 dark:bg-green-900/30 text-green-700 dark:text-green-300 border-green-200 dark:border-green-800"
            : "bg-red-50 dark:bg-red-900/30 text-red-700 dark:text-red-300 border-red-200 dark:border-red-800"
        }`}>
          {outcome === "UP" ? "▲ RESOLVED UP" : "▼ RESOLVED DOWN"}
          {nextIn != null && <span className="ml-4 text-sm font-normal text-slate-500"> Next in {fmtS(nextIn)}</span>}
        </div>
      )}

      {/* Chart */}
      <div className="bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 rounded-xl p-4" style={{ height: 280 }}>
        {chartData.filter(d => d.UP != null).length === 0 ? (
          <div className="h-full flex flex-col items-center justify-center gap-2 text-slate-400">
            <p className="text-sm">{status === "tracking" ? "Waiting for price data…" : "No data"}</p>
            {status === "tracking" && ptsWithPrice === 0 && priceHistory.length > 5 && (
              <p className="text-xs text-red-500">Prices returning null — token IDs may be wrong.<br/>
                Open <code className="bg-slate-100 dark:bg-slate-800 px-1 rounded">/api/debug?slug={market?.slug}</code> to inspect raw market data.
              </p>
            )}
          </div>
        ) : (
          <ResponsiveContainer width="100%" height="100%">
            <LineChart data={chartData}>
              <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" />
              <XAxis dataKey="elapsed" tickFormatter={v => `${v}s`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
              <YAxis domain={[0, 100]} tickFormatter={v => `${v}¢`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
              <Tooltip
                formatter={(v, n) => [`${v}¢`, n]}
                labelFormatter={v => `${v}s elapsed`}
                contentStyle={{ background: "#fff", border: "1px solid #e2e8f0", borderRadius: 8, color: "#0f172a" }}
              />
              <ReferenceLine y={50} stroke="#94a3b8" strokeDasharray="4 2" />
              <Line type="monotone" dataKey="UP"   stroke="#16a34a" dot={false} strokeWidth={2} connectNulls={false} />
              <Line type="monotone" dataKey="DOWN" stroke="#dc2626" dot={false} strokeWidth={2} connectNulls={false} />
            </LineChart>
          </ResponsiveContainer>
        )}
      </div>

      {/* Save */}
      <div className="flex justify-end">
        <button onClick={() => doSave(historyRef.current, outcome ?? detectOutcome(currentUp, currentDown))}
          disabled={priceHistory.length === 0}
          className="px-5 py-2 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 text-white rounded-lg font-semibold text-sm">
          💾 Save Session
        </button>
      </div>
    </div>
  );
}

function StatCard({ label, value, color }) {
  return (
    <div className="bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 rounded-xl p-3 text-center">
      <p className="text-xs text-slate-400 mb-1">{label}</p>
      <p className={`text-xl font-bold font-mono ${color}`}>{value}</p>
    </div>
  );
}
'@ | Set-Content "src/components/LiveTracker.js"

Write-Host ""
Write-Host "✅ Price-tracking fixes applied!" -ForegroundColor Green
Write-Host ""
Write-Host "What changed:" -ForegroundColor Yellow
Write-Host "  ✓ Python tracker polls every 1s (was 2s)"
Write-Host "  ✓ Correctly parses clobTokenIds (JSON string -> array)"
Write-Host "  ✓ Tries 3 price endpoints: midpoints -> price -> book"
Write-Host "  ✓ Infers missing side from 1 - other side"
Write-Host "  ✓ --debug-slug flag to inspect raw Gamma API response"
Write-Host "  ✓ Next.js API routes use same robust token parsing"
Write-Host "  ✓ API tries midpoints -> price -> book endpoints"
Write-Host "  ✓ /api/debug?slug=... shows raw market data in browser"
Write-Host "  ✓ UI shows token IDs + priced pts count so you can verify"
Write-Host ""
Write-Host "To debug null prices, visit in your browser:" -ForegroundColor Cyan
Write-Host "  http://localhost:3000/api/debug?slug=btc-updown-5m-1771465500"
Write-Host ""
Write-Host "To debug python token IDs:" -ForegroundColor Cyan
Write-Host "  python tracker.py --debug-slug btc-updown-5m-1771465500"
Write-Host ""
Write-Host "Restart dev server:" -ForegroundColor Cyan
Write-Host "  npm run dev"