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
