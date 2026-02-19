# fix3.ps1
# Run from inside your polymarket-btc-backtest folder:
#   .\fix3.ps1

Write-Host "Applying fix3..." -ForegroundColor Cyan

# ── src/lib/polymarket.js ─────────────────────────────────────────────────────
$polymarketLib = @'
export function getCurrentMarketTimestamp() {
  const now = Math.floor(Date.now() / 1000);
  // Guard: if exactly on boundary, step 1s forward so ceil stays in this window
  const adjusted = (now % 300 === 0) ? now + 1 : now;
  return Math.ceil(adjusted / 300) * 300;
}

export function getMarketSlug(ts) {
  return `btc-updown-5m-${ts}`;
}

export function getSecondsRemaining(resolutionTs) {
  return Math.max(0, resolutionTs - Math.floor(Date.now() / 1000));
}

export function getSecondsElapsed(resolutionTs) {
  return Math.min(300, 300 - getSecondsRemaining(resolutionTs));
}

export async function fetchMarketBySlug(slug) {
  try {
    const res = await fetch(`/api/market?slug=${encodeURIComponent(slug)}`);
    if (!res.ok) return null;
    return res.json();
  } catch { return null; }
}

export async function fetchMidpoint(tokenId) {
  if (!tokenId) return null;
  try {
    const res = await fetch(`/api/midpoint?token_id=${encodeURIComponent(tokenId)}`);
    if (!res.ok) return null;
    const data = await res.json();
    const raw = data.mid;
    if (raw == null) return null;
    const f = parseFloat(raw);
    return (isFinite(f) && f > 0.001) ? f : null;
  } catch { return null; }
}

export function resolveTokenIds(market) {
  let upId = null, downId = null;
  const tokens = market.tokens ?? [];
  for (const t of tokens) {
    const o  = (t.outcome ?? "").toLowerCase();
    const id = t.token_id ?? t.tokenId;
    if (!id) continue;
    if (o === "up")   upId   = String(id);
    if (o === "down") downId = String(id);
  }
  if (!upId   && tokens[0]) upId   = String(tokens[0].token_id ?? tokens[0].tokenId ?? tokens[0]);
  if (!downId && tokens[1]) downId = String(tokens[1].token_id ?? tokens[1].tokenId ?? tokens[1]);
  return { upId, downId };
}

export function detectOutcome(up, down) {
  if (up   != null && up   >= 0.95) return "UP";
  if (down != null && down >= 0.95) return "DOWN";
  if (up   != null && down != null) return up > down ? "UP" : "DOWN";
  return null;
}
'@
Set-Content "src/lib/polymarket.js" -Value $polymarketLib

# ── src/app/api/midpoint/route.js ─────────────────────────────────────────────
$midpointRoute = @'
export const runtime = "edge";

function validPrice(v) {
  const f = parseFloat(v);
  return (isFinite(f) && f > 0.001) ? f : null;
}

async function tryMidpoints(tokenId) {
  try {
    const res = await fetch(`https://clob.polymarket.com/midpoints?token_id=${tokenId}`, { headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    const d = await res.json();
    return validPrice(d?.mid ?? d?.[tokenId] ?? d?.midpoint);
  } catch { return null; }
}

async function tryPrice(tokenId) {
  try {
    const res = await fetch(`https://clob.polymarket.com/price?token_id=${tokenId}&side=buy`, { headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    const d = await res.json();
    return validPrice(d?.price);
  } catch { return null; }
}

async function tryBook(tokenId) {
  try {
    const res = await fetch(`https://clob.polymarket.com/book?token_id=${tokenId}`, { headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    const d = await res.json();
    const bid = d?.bids?.[0]?.price != null ? parseFloat(d.bids[0].price) : null;
    const ask = d?.asks?.[0]?.price != null ? parseFloat(d.asks[0].price) : null;
    if (bid && ask) return validPrice((bid + ask) / 2);
    return validPrice(bid ?? ask);
  } catch { return null; }
}

export async function GET(request) {
  const { searchParams } = new URL(request.url);
  const tokenId = searchParams.get("token_id");
  if (!tokenId) return Response.json({ mid: null, error: "no token_id" }, { status: 400 });
  try {
    const mid = await tryMidpoints(tokenId) ?? await tryPrice(tokenId) ?? await tryBook(tokenId);
    return Response.json({ mid: mid != null ? mid.toFixed(6) : null });
  } catch (e) {
    return Response.json({ mid: null, error: String(e) });
  }
}
'@
Set-Content "src/app/api/midpoint/route.js" -Value $midpointRoute

# ── src/components/LiveTracker.js ─────────────────────────────────────────────
$liveTracker = @'
"use client";
import { useEffect, useRef, useState, useCallback } from "react";
import { LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, ResponsiveContainer, ReferenceLine } from "recharts";
import {
  getCurrentMarketTimestamp, getMarketSlug, fetchMarketBySlug,
  fetchMidpoint, getSecondsElapsed, getSecondsRemaining,
  detectOutcome, resolveTokenIds,
} from "../lib/polymarket";

const POLL_MS = 1000;
function pad(n) { return String(n).padStart(2, "0"); }
function fmtS(s) { return `${pad(Math.floor(s / 60))}:${pad(s % 60)}`; }
function pct(v)  { return v != null ? `${(v * 100).toFixed(1)}c` : "---"; }

export default function LiveTracker({ onSaveSession }) {
  const [status,       setStatus]       = useState("idle");
  const [slugLabel,    setSlugLabel]    = useState("");
  const [question,     setQuestion]     = useState("");
  const [tokenInfo,    setTokenInfo]    = useState(null);
  const [priceHistory, setPriceHistory] = useState([]);
  const [elapsed,      setElapsed]      = useState(0);
  const [remaining,    setRemaining]    = useState(300);
  const [curUp,        setCurUp]        = useState(null);
  const [curDown,      setCurDown]      = useState(null);
  const [outcome,      setOutcome]      = useState(null);
  const [errorMsg,     setErrorMsg]     = useState("");
  const [nextIn,       setNextIn]       = useState(null);
  const [manualSlug,   setManualSlug]   = useState("");
  const [pricedPts,    setPricedPts]    = useState(0);

  const intervalRef   = useRef(null);
  const cdRef         = useRef(null);
  const marketRef     = useRef(null);
  const tokenRef      = useRef({ upId: null, downId: null });
  const historyRef    = useRef([]);
  const resolutionRef = useRef(null);
  const savedRef      = useRef(false);
  const startFnRef    = useRef(null);

  const stopAll = useCallback(() => {
    clearInterval(intervalRef.current);
    clearInterval(cdRef.current);
    intervalRef.current = null;
    cdRef.current = null;
  }, []);

  const doSave = useCallback((history, det) => {
    if (savedRef.current || !history.length || !marketRef.current) return;
    savedRef.current = true;
    onSaveSession({
      slug:         marketRef.current.slug,
      resolutionTs: resolutionRef.current,
      question:     marketRef.current.question,
      outcome:      det,
      priceHistory: history,
      savedAt:      Date.now(),
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
    if (!upId) return;

    const [upRaw, downRaw] = await Promise.all([
      fetchMidpoint(upId),
      downId ? fetchMidpoint(downId) : Promise.resolve(null),
    ]);

    let up   = upRaw;
    let down = downRaw;
    if (up != null && down == null) down = parseFloat((1 - up).toFixed(6));
    if (down != null && up == null) up   = parseFloat((1 - down).toFixed(6));
    // Drop both if they don't sum to ~1 (stale data)
    if (up != null && down != null && Math.abs(up + down - 1) > 0.15) { up = null; down = null; }

    const point = { t: Math.floor(Date.now() / 1000), elapsed: el, up, down };
    const next  = [...historyRef.current, point];
    historyRef.current = next;
    setPriceHistory(next);
    setCurUp(up);
    setCurDown(down);
    setPricedPts(next.filter(p => p.up != null).length);

    if (rem <= 0) {
      const det = detectOutcome(up, down);
      setOutcome(det);
      setStatus("resolved");
      clearInterval(intervalRef.current);
      intervalRef.current = null;
      doSave(next, det);

      // Count down then auto-load next market
      const nextTs = rts + 300;
      cdRef.current = setInterval(() => {
        const sec = nextTs - Math.floor(Date.now() / 1000);
        if (sec <= 0) {
          clearInterval(cdRef.current);
          cdRef.current = null;
          setNextIn(null);
          if (startFnRef.current) startFnRef.current(getMarketSlug(nextTs), nextTs);
        } else {
          setNextIn(sec);
        }
      }, 500);
    }
  }, [doSave]);

  const startTracking = useCallback(async (slugOverride, rtsOverride) => {
    stopAll();
    setStatus("loading");
    setErrorMsg("");
    setPriceHistory([]);
    historyRef.current = [];
    setOutcome(null);
    setNextIn(null);
    setCurUp(null);
    setCurDown(null);
    setPricedPts(0);
    savedRef.current = false;

    const rts  = rtsOverride ?? getCurrentMarketTimestamp();
    const slug = slugOverride ?? getMarketSlug(rts);
    resolutionRef.current = rts;
    setSlugLabel(slug);
    setQuestion("Loading...");

    const m = await fetchMarketBySlug(slug);
    if (!m || m.error) {
      setErrorMsg(`Market not found: ${slug}`);
      setStatus("error");
      setQuestion("");
      return;
    }

    const ids = resolveTokenIds(m);
    marketRef.current = m;
    tokenRef.current  = ids;
    setSlugLabel(m.slug ?? slug);
    setQuestion(m.question ?? "");
    setTokenInfo(ids);
    setStatus("tracking");

    await tick();
    intervalRef.current = setInterval(tick, POLL_MS);
  }, [stopAll, tick]);

  // Keep a stable ref so the countdown setInterval can call it
  useEffect(() => { startFnRef.current = startTracking; }, [startTracking]);

  useEffect(() => { startTracking(); return stopAll; }, []); // eslint-disable-line

  const chartData = priceHistory
    .filter(p => p.up != null || p.down != null)
    .map(p => ({
      elapsed: p.elapsed,
      UP:   p.up   != null ? +(p.up   * 100).toFixed(2) : null,
      DOWN: p.down != null ? +(p.down * 100).toFixed(2) : null,
    }));

  const statusCls = {
    tracking: "bg-green-100 text-green-700 dark:bg-green-900/60 dark:text-green-300",
    resolved: "bg-amber-100 text-amber-700 dark:bg-amber-900/60 dark:text-amber-300",
    loading:  "bg-blue-100 text-blue-700 dark:bg-blue-900/60 dark:text-blue-300",
    error:    "bg-red-100 text-red-700 dark:bg-red-900/60 dark:text-red-300",
    idle:     "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400",
  }[status] ?? "";

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-start gap-3">
        <div className="flex-1 min-w-0">
          <p className="text-xs font-mono text-slate-400 dark:text-slate-500 truncate">{slugLabel || "Searching..."}</p>
          <p className="text-sm text-slate-700 dark:text-slate-300 truncate">{question}</p>
        </div>
        <div className="flex gap-2 items-center shrink-0">
          <span className={`px-2 py-0.5 rounded text-xs font-bold ${statusCls}`}>{status.toUpperCase()}</span>
          <button onClick={() => startTracking()} className="px-3 py-1 bg-indigo-600 hover:bg-indigo-500 text-white rounded text-xs font-semibold">Refresh</button>
        </div>
      </div>

      <div className="flex gap-2">
        <input value={manualSlug} onChange={e => setManualSlug(e.target.value)}
          placeholder="btc-updown-5m-1771467600"
          className="flex-1 bg-white dark:bg-slate-800 border border-slate-300 dark:border-slate-600 rounded px-3 py-1.5 text-sm text-slate-800 dark:text-slate-200 placeholder-slate-400" />
        <button
          onClick={() => {
            const s = manualSlug.trim();
            if (!s) return;
            const ts = parseInt(s.replace(/^.*-(\d+)$/, "$1"), 10);
            startTracking(s, isNaN(ts) ? undefined : ts);
          }}
          className="px-4 py-1.5 bg-slate-100 hover:bg-slate-200 dark:bg-slate-700 dark:hover:bg-slate-600 rounded text-sm font-semibold text-slate-700 dark:text-slate-200">
          Load
        </button>
      </div>

      {errorMsg && <p className="text-red-500 dark:text-red-400 text-sm">{errorMsg}</p>}

      {tokenInfo && (
        <div className="bg-slate-50 dark:bg-slate-900 border border-slate-200 dark:border-slate-800 rounded-lg px-3 py-2 font-mono text-xs space-y-0.5">
          <div><span className="text-slate-400">UP&nbsp;&nbsp; </span><span className="text-green-600 dark:text-green-400">{tokenInfo.upId ?? "NOT FOUND"}</span></div>
          <div><span className="text-slate-400">DOWN </span><span className="text-red-600 dark:text-red-400">{tokenInfo.downId ?? "NOT FOUND"}</span></div>
          <div><span className="text-slate-400">Priced: </span><span className="text-blue-600 dark:text-blue-400">{pricedPts} / {priceHistory.length} pts</span></div>
        </div>
      )}

      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <StatCard label="UP Price"   value={pct(curUp)}   color="text-green-600 dark:text-green-400" />
        <StatCard label="DOWN Price" value={pct(curDown)} color="text-red-600 dark:text-red-400" />
        <StatCard label="Elapsed"    value={fmtS(elapsed)}   color="text-blue-600 dark:text-blue-400" />
        <StatCard label="Remaining"  value={fmtS(remaining)} color="text-orange-500 dark:text-orange-400" />
      </div>

      {status === "resolved" && (
        <div className={`rounded-xl p-4 text-center font-bold text-lg border ${
          outcome === "UP"
            ? "bg-green-50 dark:bg-green-900/30 text-green-700 dark:text-green-300 border-green-200 dark:border-green-800"
            : outcome === "DOWN"
            ? "bg-red-50 dark:bg-red-900/30 text-red-700 dark:text-red-300 border-red-200 dark:border-red-800"
            : "bg-slate-50 dark:bg-slate-800 text-slate-600 border-slate-200"
        }`}>
          {outcome === "UP" && "UP RESOLVED UP"}
          {outcome === "DOWN" && "DOWN RESOLVED DOWN"}
          {!outcome && "RESOLVED - detecting outcome..."}
          {nextIn != null && <span className="ml-4 text-sm font-normal text-slate-500 dark:text-slate-400"> Next market in {fmtS(nextIn)}</span>}
        </div>
      )}

      <div className="bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 rounded-xl p-4" style={{ height: 300 }}>
        {chartData.length === 0 ? (
          <div className="h-full flex flex-col items-center justify-center gap-2 text-slate-400 text-sm">
            {status === "tracking"
              ? <p>Waiting for prices... ({priceHistory.length} pts polled)</p>
              : <p>No price data</p>}
            {status === "tracking" && priceHistory.length > 10 && pricedPts === 0 && (
              <p className="text-xs text-red-500 text-center max-w-sm">
                All prices null - token IDs may be wrong. Check /api/debug?slug={slugLabel}
              </p>
            )}
          </div>
        ) : (
          <ResponsiveContainer width="100%" height="100%">
            <LineChart data={chartData}>
              <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" />
              <XAxis dataKey="elapsed" tickFormatter={v => `${v}s`} stroke="#94a3b8" tick={{ fontSize: 11 }} interval="preserveStartEnd" />
              <YAxis domain={[0, 100]} tickFormatter={v => `${v}c`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
              <Tooltip
                formatter={(v, n) => [v != null ? `${v}c` : "---", n]}
                labelFormatter={v => `${v}s elapsed`}
                contentStyle={{ background: "#fff", border: "1px solid #e2e8f0", borderRadius: 8, color: "#0f172a", fontSize: 12 }}
              />
              <ReferenceLine y={50} stroke="#94a3b8" strokeDasharray="4 2" />
              <Line type="monotone" dataKey="UP"   stroke="#16a34a" dot={false} strokeWidth={2} connectNulls={false} />
              <Line type="monotone" dataKey="DOWN" stroke="#dc2626" dot={false} strokeWidth={2} connectNulls={false} />
            </LineChart>
          </ResponsiveContainer>
        )}
      </div>

      <div className="flex items-center justify-between">
        <p className="text-xs text-slate-400">{priceHistory.length} pts recorded - {pricedPts} with price data</p>
        <button
          onClick={() => doSave(historyRef.current, outcome ?? detectOutcome(curUp, curDown))}
          disabled={priceHistory.length === 0}
          className="px-5 py-2 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 text-white rounded-lg font-semibold text-sm">
          Save Session
        </button>
      </div>
    </div>
  );
}

function StatCard({ label, value, color }) {
  return (
    <div className="bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 rounded-xl p-3 text-center shadow-sm">
      <p className="text-xs text-slate-400 mb-1">{label}</p>
      <p className={`text-xl font-bold font-mono ${color}`}>{value}</p>
    </div>
  );
}
'@
Set-Content "src/components/LiveTracker.js" -Value $liveTracker

# ── tracker.py — patch valid_price + fetch_price ──────────────────────────────
$trackerPatch = @'
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

def current_resolution_ts():
    now = int(time.time())
    adjusted = now + 1 if now % 300 == 0 else now
    return math.ceil(adjusted / 300) * 300

def market_slug(ts):
    return f"btc-updown-5m-{ts}"

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
        if isinstance(raw, str):
            try:
                token_ids = json.loads(raw)
            except Exception:
                token_ids = []
        else:
            token_ids = raw
        outcomes = market.get("outcomes", [])
        if isinstance(outcomes, str):
            try:
                outcomes = json.loads(outcomes)
            except Exception:
                outcomes = []
        up_id, down_id = None, None
        for i, outcome in enumerate(outcomes):
            if outcome.lower() in ("up", "yes") and i < len(token_ids):
                up_id = str(token_ids[i])
            elif outcome.lower() in ("down", "no") and i < len(token_ids):
                down_id = str(token_ids[i])
        if not up_id and len(token_ids) > 0:
            up_id = str(token_ids[0])
        if not down_id and len(token_ids) > 1:
            down_id = str(token_ids[1])
        return {"slug": market.get("slug", slug), "question": market.get("question", ""), "up_id": up_id, "down_id": down_id}
    except Exception as e:
        print(f"\n  [ERROR] fetch_market: {e}")
        return None

def fetch_price(token_id):
    if not token_id:
        return None
    try:
        r = session.get(f"{CLOB}/midpoints", params={"token_id": token_id}, timeout=4)
        if r.ok:
            data = r.json()
            p = valid_price(data.get("mid") or data.get(token_id) or data.get("midpoint"))
            if p is not None:
                return p
    except Exception:
        pass
    try:
        r = session.get(f"{CLOB}/price", params={"token_id": token_id, "side": "buy"}, timeout=4)
        if r.ok:
            p = valid_price(r.json().get("price"))
            if p is not None:
                return p
    except Exception:
        pass
    try:
        r = session.get(f"{CLOB}/book", params={"token_id": token_id}, timeout=4)
        if r.ok:
            data = r.json()
            bids = data.get("bids", [])
            asks = data.get("asks", [])
            bid = valid_price(bids[0]["price"]) if bids else None
            ask = valid_price(asks[0]["price"]) if asks else None
            if bid and ask:
                return round((bid + ask) / 2, 6)
            return bid or ask
    except Exception:
        pass
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
    print(f"  Resolves: epoch {resolution_ts}")
    print(f"{'='*60}")

    market = fetch_market(slug)
    if not market:
        print(f"  [SKIP] Market not found.")
        return None

    up_id   = market["up_id"]
    down_id = market["down_id"]
    print(f"  UP   token: {up_id}")
    print(f"  DOWN token: {down_id}\n")

    if not up_id:
        print("  [ERROR] No UP token ID found.")
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
        now       = int(time.time())
        elapsed   = max(0, min(300, 300 - (resolution_ts - now)))
        remaining = max(0, resolution_ts - now)

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
        bar = chr(9608) * int((elapsed / 300) * 20)
        print(f"\r  [{bar:<20}] {elapsed:>3}s  UP={up_str}  DOWN={down_str}  pts={len(session_data['priceHistory'])}  rem={remaining}s   ", end="", flush=True)

        if time.time() - last_save >= 30:
            save_session(session_data)
            last_save = time.time()

        if remaining <= 0:
            print()
            outcome = detect_outcome(up_price, down_price)
            if outcome:
                session_data["outcome"] = outcome
                print(f"\n  Auto-detected outcome: {outcome}")
            else:
                print("\n  Could not auto-detect outcome (prices null at resolution)")
                ans = input("  Manual: u=UP / d=DOWN / Enter to skip: ").strip().lower()
                if ans in ("u","up"):   session_data["outcome"] = "UP"
                elif ans in ("d","down"): session_data["outcome"] = "DOWN"
            break

        time.sleep(POLL)

    filename = save_session(session_data)
    pts_with_price = sum(1 for p in session_data["priceHistory"] if p["up"] is not None)
    print(f"  Saved: {filename}")
    print(f"  Total pts: {len(session_data['priceHistory'])}  |  With price: {pts_with_price}")
    return session_data

def debug_market(slug):
    print(f"\nDEBUG: {GAMMA}/markets?slug={slug}")
    r = session.get(f"{GAMMA}/markets", params={"slug": slug}, timeout=8)
    print(f"Status: {r.status_code}")
    print(json.dumps(r.json(), indent=2)[:3000])

def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--debug-slug", help="Print raw API response for slug and exit")
    parser.add_argument("--slug", help="Track a specific slug once")
    args = parser.parse_args()

    if args.debug_slug:
        debug_market(args.debug_slug)
        return

    if args.slug:
        ts_str = args.slug.replace("btc-updown-5m-", "")
        try:    ts = int(ts_str)
        except: print("Cannot parse timestamp"); return
        track_market(args.slug, ts)
        return

    print("Polymarket BTC 5m Tracker -- Ctrl+C to stop")
    print(f"Output: {os.path.abspath('.')}\n")

    while True:
        ts   = current_resolution_ts()
        slug = market_slug(ts)
        now  = int(time.time())

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
'@
Set-Content "tracker.py" -Value $trackerPatch

Write-Host ""
Write-Host "fix3 applied!" -ForegroundColor Green
Write-Host ""
Write-Host "Root causes fixed:" -ForegroundColor Yellow
Write-Host "  1. 0.0c prices: API returns 0 when no quote exists -- now treated as null"
Write-Host "  2. Wrong slug: ceil() on exact boundary jumped 1 window ahead -- guarded"
Write-Host "  3. Auto-advance: startFnRef pattern prevents stale closure, fires cleanly"
Write-Host "  4. Sanity: UP+DOWN must sum to ~1 or both dropped as stale"
Write-Host "  5. Chart: filters null-price points so no flat 0c line"
Write-Host "  6. Python: same valid_price() guard (0.001 < p < 1.0)"
Write-Host ""
Write-Host "Restart: npm run dev" -ForegroundColor Cyan