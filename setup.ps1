# fix6.ps1
# 1. Switch to Polymarket WebSocket for live prices (no more null from REST)
# 2. Slug input field auto-fills with current slug
# 3. Outcome from Gamma API winner field (no guessing, no manual override needed)

Write-Host "Applying fix6..." -ForegroundColor Cyan

# ── src/app/api/market/route.js — return winner token info ───────────────────
$marketRoute = @'
export const runtime = "edge";

export async function GET(request) {
  const { searchParams } = new URL(request.url);
  const slug = searchParams.get("slug");
  if (!slug) return Response.json({ error: "no slug" }, { status: 400 });

  try {
    const res = await fetch(
      `https://gamma-api.polymarket.com/markets?slug=${encodeURIComponent(slug)}`,
      { headers: { Accept: "application/json" } }
    );
    const data = await res.json();
    const market = Array.isArray(data) ? data[0] : data;
    if (!market) return Response.json({ error: "not found" }, { status: 404 });

    // Parse clobTokenIds (may be JSON-encoded string)
    let tokenIds = market.clobTokenIds ?? [];
    if (typeof tokenIds === "string") {
      try { tokenIds = JSON.parse(tokenIds); } catch { tokenIds = []; }
    }

    let outcomes = market.outcomes ?? [];
    if (typeof outcomes === "string") {
      try { outcomes = JSON.parse(outcomes); } catch { outcomes = []; }
    }

    // Build tokens array — also grab winner flag from tokens if present
    const rawTokens = market.tokens ?? [];
    const tokens = tokenIds.map((id, i) => {
      const raw = rawTokens.find(t => (t.token_id ?? t.tokenId) === String(id)) ?? {};
      return {
        token_id: String(id),
        outcome:  outcomes[i] ?? raw.outcome ?? (i === 0 ? "Up" : "Down"),
        winner:   raw.winner ?? false,
      };
    });

    // Determine winner from tokens array
    let winner = null;
    for (const t of tokens) {
      if (t.winner === true) { winner = t.outcome; break; }
    }

    return Response.json({
      slug:     market.slug,
      question: market.question,
      endDate:  market.endDate,
      closed:   market.closed ?? false,
      winner,   // "Up" | "Down" | null
      tokens,
      outcomes,
    });
  } catch (e) {
    return Response.json({ error: String(e) }, { status: 500 });
  }
}
'@
Set-Content "src/app/api/market/route.js" -Value $marketRoute

# ── src/lib/polymarket.js ─────────────────────────────────────────────────────
$lib = @'
export function getCurrentSlugTimestamp() {
  return Math.floor(Date.now() / 1000 / 300) * 300;
}
export function getResolutionTs(slugTs) { return slugTs + 300; }
export function getMarketSlug(slugTs)   { return `btc-updown-5m-${slugTs}`; }
export function getSecondsRemaining(slugTs) {
  return Math.max(0, getResolutionTs(slugTs) - Math.floor(Date.now() / 1000));
}
export function getSecondsElapsed(slugTs) {
  return Math.min(300, 300 - getSecondsRemaining(slugTs));
}

export async function fetchMarketBySlug(slug) {
  try {
    const res = await fetch(`/api/market?slug=${encodeURIComponent(slug)}`);
    if (!res.ok) return null;
    return res.json();
  } catch { return null; }
}

export function resolveTokenIds(market) {
  let upId = null, downId = null;
  for (const t of market.tokens ?? []) {
    const o  = (t.outcome ?? "").toLowerCase();
    const id = t.token_id ?? t.tokenId;
    if (!id) continue;
    if (o === "up")   upId   = String(id);
    if (o === "down") downId = String(id);
  }
  const tokens = market.tokens ?? [];
  if (!upId   && tokens[0]) upId   = String(tokens[0].token_id ?? tokens[0]);
  if (!downId && tokens[1]) downId = String(tokens[1].token_id ?? tokens[1]);
  return { upId, downId };
}

/**
 * Poll Gamma API until market shows closed=true and a winner.
 * Returns "UP" | "DOWN" | null.
 */
export async function pollGammaOutcome(slug, maxAttempts = 20, intervalMs = 3000) {
  for (let i = 0; i < maxAttempts; i++) {
    if (i > 0) await new Promise(r => setTimeout(r, intervalMs));
    try {
      const m = await fetchMarketBySlug(slug);
      if (m?.closed && m?.winner) {
        const w = m.winner.toLowerCase();
        if (w === "up")   return "UP";
        if (w === "down") return "DOWN";
      }
    } catch { /* keep trying */ }
  }
  return null;
}
'@
Set-Content "src/lib/polymarket.js" -Value $lib

# ── src/components/LiveTracker.js — WebSocket prices + auto outcome ───────────
$liveTracker = @'
"use client";
import { useEffect, useRef, useState, useCallback } from "react";
import { LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, ResponsiveContainer, ReferenceLine } from "recharts";
import {
  getCurrentSlugTimestamp, getResolutionTs, getMarketSlug,
  fetchMarketBySlug, getSecondsElapsed, getSecondsRemaining,
  resolveTokenIds, pollGammaOutcome,
} from "../lib/polymarket";

const WS_URL = "wss://ws-subscriptions-clob.polymarket.com/ws/market";

function pad(n) { return String(n).padStart(2, "0"); }
function fmtS(s) { return `${pad(Math.floor(s / 60))}:${pad(s % 60)}`; }

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
  const [outcomeConf,  setOutcomeConf]  = useState(false);
  const [resolving,    setResolving]    = useState(false);
  const [errorMsg,     setErrorMsg]     = useState("");
  const [nextIn,       setNextIn]       = useState(null);
  const [manualSlug,   setManualSlug]   = useState("");
  const [wsState,      setWsState]      = useState("disconnected"); // connected|disconnected|error

  const wsRef        = useRef(null);
  const tickRef      = useRef(null);   // clock interval
  const cdRef        = useRef(null);   // countdown after resolution
  const marketRef    = useRef(null);
  const tokenRef     = useRef({ upId: null, downId: null });
  const pricesRef    = useRef({ up: null, down: null }); // latest WS prices
  const historyRef   = useRef([]);
  const slugTsRef    = useRef(null);
  const savedRef     = useRef(false);
  const startFnRef   = useRef(null);

  // ── stop everything ────────────────────────────────────────────────────────
  const stopAll = useCallback(() => {
    clearInterval(tickRef.current);
    clearInterval(cdRef.current);
    tickRef.current = null;
    cdRef.current   = null;
    if (wsRef.current) {
      wsRef.current.onclose = null; // prevent reconnect on intentional close
      wsRef.current.close();
      wsRef.current = null;
    }
    setWsState("disconnected");
  }, []);

  // ── save session ───────────────────────────────────────────────────────────
  const doSave = useCallback((history, det) => {
    if (savedRef.current || !history.length || !marketRef.current) return;
    savedRef.current = true;
    onSaveSession({
      slug:         marketRef.current.slug,
      slugTs:       slugTsRef.current,
      resolutionTs: getResolutionTs(slugTsRef.current),
      question:     marketRef.current.question,
      outcome:      det,
      priceHistory: history,
      savedAt:      Date.now(),
    });
  }, [onSaveSession]);

  // ── open WebSocket to Polymarket ───────────────────────────────────────────
  const openWs = useCallback((upId, downId) => {
    if (wsRef.current) { wsRef.current.onclose = null; wsRef.current.close(); }

    const ws = new WebSocket(WS_URL);
    wsRef.current = ws;

    ws.onopen = () => {
      setWsState("connected");
      // Subscribe to both token IDs
      const ids = [upId, downId].filter(Boolean);
      ws.send(JSON.stringify({ assets_ids: ids, type: "Market" }));
    };

    ws.onmessage = (e) => {
      try {
        const msgs = JSON.parse(e.data);
        const arr  = Array.isArray(msgs) ? msgs : [msgs];
        for (const msg of arr) {
          const assetId = msg.asset_id ?? msg.assetId ?? msg.token_id;
          // price comes as "price", "best_bid"/"best_ask", or in "outcome_price" fields
          const rawPrice =
            msg.price       ??
            msg.outcome_price ??
            msg.mid         ??
            null;

          if (rawPrice == null || !assetId) continue;
          const p = parseFloat(rawPrice);
          if (!isFinite(p) || p <= 0.0005 || p >= 0.9999) continue;

          const { upId: uid, downId: did } = tokenRef.current;
          if (assetId === uid) {
            pricesRef.current.up = p;
            pricesRef.current.down = parseFloat((1 - p).toFixed(6));
          } else if (assetId === did) {
            pricesRef.current.down = p;
            pricesRef.current.up   = parseFloat((1 - p).toFixed(6));
          }

          setCurUp(pricesRef.current.up);
          setCurDown(pricesRef.current.down);
        }
      } catch { /* ignore bad frames */ }
    };

    ws.onerror = () => setWsState("error");

    ws.onclose = () => {
      setWsState("disconnected");
      // Auto-reconnect if still tracking
      if (slugTsRef.current && tokenRef.current.upId) {
        setTimeout(() => openWs(tokenRef.current.upId, tokenRef.current.downId), 2000);
      }
    };
  }, []);

  // ── 1-second clock tick — records price from WS cache ─────────────────────
  const clockTick = useCallback(() => {
    const slugTs = slugTsRef.current;
    if (slugTs == null) return;

    const el  = getSecondsElapsed(slugTs);
    const rem = getSecondsRemaining(slugTs);
    setElapsed(el);
    setRemaining(rem);

    const { up, down } = pricesRef.current;
    const point = { t: Math.floor(Date.now() / 1000), elapsed: el, up, down };
    const next  = [...historyRef.current, point];
    historyRef.current = next;
    setPriceHistory(next);

    if (rem <= 0) {
      setStatus("resolved");
      setResolving(true);
      clearInterval(tickRef.current);
      tickRef.current = null;
      // Close WS — market is over
      if (wsRef.current) { wsRef.current.onclose = null; wsRef.current.close(); wsRef.current = null; }
      setWsState("disconnected");

      const snapshot      = [...historyRef.current];
      const capturedSlug  = marketRef.current?.slug;
      const capturedSlugTs = slugTs;

      // Poll Gamma API for authoritative winner
      pollGammaOutcome(capturedSlug, 20, 3000).then(polledOutcome => {
        setResolving(false);
        setOutcome(polledOutcome);
        setOutcomeConf(!!polledOutcome);
        doSave(snapshot, polledOutcome);

        const nextSlugTs = capturedSlugTs + 300;
        cdRef.current = setInterval(() => {
          const nowSec    = Math.floor(Date.now() / 1000);
          const secUntil  = nextSlugTs - nowSec;
          if (secUntil <= 0) {
            clearInterval(cdRef.current);
            cdRef.current = null;
            setNextIn(null);
            if (startFnRef.current) startFnRef.current(undefined, nextSlugTs);
          } else {
            setNextIn(secUntil);
          }
        }, 500);
      });
    }
  }, [doSave, openWs]);

  // ── main entry: load market + connect WS + start clock ────────────────────
  const startTracking = useCallback(async (slugOverride, slugTsOverride) => {
    stopAll();
    setStatus("loading");
    setErrorMsg("");
    setPriceHistory([]);
    historyRef.current    = [];
    pricesRef.current     = { up: null, down: null };
    setOutcome(null);
    setOutcomeConf(false);
    setResolving(false);
    setNextIn(null);
    setCurUp(null);
    setCurDown(null);
    savedRef.current = false;

    const slugTs = slugTsOverride ?? getCurrentSlugTimestamp();
    slugTsRef.current = slugTs;
    const slug = slugOverride ?? getMarketSlug(slugTs);

    setSlugLabel(slug);
    setManualSlug(slug);   // ← keep input in sync with active slug
    setQuestion("Loading...");

    const m = await fetchMarketBySlug(slug);
    if (!m || m.error) {
      setErrorMsg(`Market not found: ${slug}`);
      setStatus("error");
      setQuestion("");
      return;
    }

    // If market already resolved, grab winner immediately
    if (m.closed && m.winner) {
      const w = m.winner.toLowerCase();
      const det = w === "up" ? "UP" : w === "down" ? "DOWN" : null;
      setOutcome(det);
      setOutcomeConf(true);
      setStatus("resolved");
      setQuestion(m.question ?? "");
      setSlugLabel(m.slug ?? slug);
      setTokenInfo(resolveTokenIds(m));
      return;
    }

    const ids = resolveTokenIds(m);
    marketRef.current = m;
    tokenRef.current  = ids;
    setSlugLabel(m.slug ?? slug);
    setQuestion(m.question ?? "");
    setTokenInfo(ids);
    setStatus("tracking");

    // Connect WebSocket
    openWs(ids.upId, ids.downId);

    // Start 1s clock
    tickRef.current = setInterval(clockTick, 1000);
    clockTick(); // immediate first tick
  }, [stopAll, openWs, clockTick]);

  useEffect(() => { startFnRef.current = startTracking; }, [startTracking]);
  useEffect(() => { startTracking(); return stopAll; }, []); // eslint-disable-line

  const chartData = priceHistory
    .filter(p => p.up != null || p.down != null)
    .map(p => ({
      elapsed: p.elapsed,
      UP:   p.up   != null ? +(p.up   * 100).toFixed(2) : null,
      DOWN: p.down != null ? +(p.down * 100).toFixed(2) : null,
    }));

  const pricedPts = priceHistory.filter(p => p.up != null).length;

  const statusColor = {
    tracking: "bg-green-100 text-green-700 dark:bg-green-900/60 dark:text-green-300",
    resolved: "bg-amber-100 text-amber-700 dark:bg-amber-900/60 dark:text-amber-300",
    loading:  "bg-blue-100 text-blue-700 dark:bg-blue-900/60 dark:text-blue-300",
    error:    "bg-red-100 text-red-700 dark:bg-red-900/60 dark:text-red-300",
    idle:     "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400",
  }[status] ?? "";

  const wsColor = {
    connected:    "text-green-500",
    disconnected: "text-slate-400",
    error:        "text-red-500",
  }[wsState] ?? "text-slate-400";

  return (
    <div className="space-y-4">

      {/* Header */}
      <div className="flex flex-wrap items-start gap-3">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <p className="text-xs font-mono text-slate-400 dark:text-slate-500 truncate">{slugLabel || "Searching..."}</p>
            <span className={`text-xs font-semibold ${wsColor}`}>
              {wsState === "connected" ? "● WS" : wsState === "error" ? "● WS ERR" : "○ WS"}
            </span>
          </div>
          <p className="text-sm text-slate-700 dark:text-slate-300 truncate">{question}</p>
        </div>
        <div className="flex gap-2 items-center shrink-0">
          <span className={`px-2 py-0.5 rounded text-xs font-bold ${statusColor}`}>{status.toUpperCase()}</span>
          <button onClick={() => startTracking()}
            className="px-3 py-1 bg-indigo-600 hover:bg-indigo-500 text-white rounded text-xs font-semibold">
            Refresh
          </button>
        </div>
      </div>

      {/* Slug input — pre-filled with current slug */}
      <div className="flex gap-2">
        <input
          value={manualSlug}
          onChange={e => setManualSlug(e.target.value)}
          placeholder="btc-updown-5m-..."
          className="flex-1 bg-white dark:bg-slate-800 border border-slate-300 dark:border-slate-600 rounded px-3 py-1.5 text-sm text-slate-800 dark:text-slate-200 placeholder-slate-400"
        />
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

      {/* Token debug strip */}
      {tokenInfo && (
        <div className="bg-slate-50 dark:bg-slate-900 border border-slate-200 dark:border-slate-800 rounded-lg px-3 py-2 font-mono text-xs space-y-0.5">
          <div><span className="text-slate-400">UP&nbsp;&nbsp; </span><span className="text-green-600 dark:text-green-400">{tokenInfo.upId ?? "NOT FOUND"}</span></div>
          <div><span className="text-slate-400">DOWN </span><span className="text-red-600 dark:text-red-400">{tokenInfo.downId ?? "NOT FOUND"}</span></div>
          <div><span className="text-slate-400">Priced: </span><span className="text-blue-600 dark:text-blue-400">{pricedPts} / {priceHistory.length} pts</span></div>
        </div>
      )}

      {/* Stats */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <StatCard label="UP Price"   value={curUp   != null ? `${(curUp*100).toFixed(1)}c`   : "---"} color="text-green-600 dark:text-green-400" />
        <StatCard label="DOWN Price" value={curDown != null ? `${(curDown*100).toFixed(1)}c` : "---"} color="text-red-600 dark:text-red-400" />
        <StatCard label="Elapsed"    value={fmtS(elapsed)}   color="text-blue-600 dark:text-blue-400" />
        <StatCard label="Remaining"  value={fmtS(remaining)} color="text-orange-500 dark:text-orange-400" />
      </div>

      {/* Resolved banner */}
      {status === "resolved" && (
        <div className={`rounded-xl p-4 text-center border ${
          resolving
            ? "bg-slate-50 dark:bg-slate-800 border-slate-200 dark:border-slate-700"
            : outcome === "UP"
            ? "bg-green-50 dark:bg-green-900/30 border-green-200 dark:border-green-800"
            : outcome === "DOWN"
            ? "bg-red-50 dark:bg-red-900/30 border-red-200 dark:border-red-800"
            : "bg-slate-50 dark:bg-slate-800 border-slate-200"
        }`}>
          {resolving ? (
            <div>
              <p className="text-slate-500 dark:text-slate-400 font-semibold animate-pulse">Fetching resolution from Polymarket...</p>
              <p className="text-xs text-slate-400 mt-1">Checking Gamma API every 3s (up to 60s)</p>
            </div>
          ) : (
            <div>
              <p className={`font-bold text-xl ${outcome === "UP" ? "text-green-700 dark:text-green-300" : outcome === "DOWN" ? "text-red-700 dark:text-red-300" : "text-slate-600"}`}>
                {outcome === "UP"   && "▲ RESOLVED UP"}
                {outcome === "DOWN" && "▼ RESOLVED DOWN"}
                {!outcome           && "⏳ RESOLVED — awaiting confirmation"}
              </p>
              {!outcomeConf && outcome && (
                <p className="text-xs text-amber-600 dark:text-amber-400 mt-1">
                  Gamma API did not confirm within 60s — use UP/DOWN buttons below to correct if wrong.
                </p>
              )}
              {nextIn != null && (
                <p className="text-sm text-slate-500 dark:text-slate-400 mt-1">Next market in {fmtS(nextIn)}</p>
              )}
            </div>
          )}
        </div>
      )}

      {/* Chart */}
      <div className="bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 rounded-xl p-4" style={{ height: 300 }}>
        {chartData.length === 0 ? (
          <div className="h-full flex flex-col items-center justify-center gap-2 text-slate-400 text-sm">
            {status === "tracking" ? (
              <>
                <p>Waiting for prices via WebSocket... ({priceHistory.length} pts)</p>
                <p className="text-xs">WS status: <span className={wsColor}>{wsState}</span></p>
              </>
            ) : <p>No price data</p>}
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
        <p className="text-xs text-slate-400">{priceHistory.length} pts · {pricedPts} priced · WS <span className={wsColor}>{wsState}</span></p>
        <button
          onClick={() => doSave(historyRef.current, outcome)}
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

# ── tracker.py — use WS for prices + Gamma API for outcome ───────────────────
$trackerPy = @'
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
'@
Set-Content "tracker.py" -Value $trackerPy

Write-Host ""
Write-Host "fix6 applied!" -ForegroundColor Green
Write-Host ""
Write-Host "Changes:" -ForegroundColor Yellow
Write-Host "  1. WebSocket: connects to wss://ws-subscriptions-clob.polymarket.com/ws/market"
Write-Host "     Price updates are event-driven, not polled every 1s from REST"
Write-Host "     1s clock tick still runs to record a snapshot of latest WS price each second"
Write-Host "     Auto-reconnects if WS drops"
Write-Host "     UI shows 'WS connected / disconnected' status inline"
Write-Host ""
Write-Host "  2. Outcome: polls Gamma API for closed=true + winner token field"
Write-Host "     No guessing. Uses the authoritative on-chain result."
Write-Host "     Only falls back to manual prompt if Gamma doesnt confirm in 60s"
Write-Host ""
Write-Host "  3. Slug input: auto-fills with the currently tracked slug"
Write-Host "     Updates whenever a new market is loaded"
Write-Host ""
Write-Host "Python needs websocket-client:" -ForegroundColor Cyan
Write-Host "  pip install websocket-client"
Write-Host ""
Write-Host "Restart: npm run dev" -ForegroundColor Cyan