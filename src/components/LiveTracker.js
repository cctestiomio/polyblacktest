"use client";
import { useEffect, useRef, useState, useCallback } from "react";
import { LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, ResponsiveContainer, ReferenceLine } from "recharts";
import {
  getCurrentSlugTimestamp, getResolutionTs, getMarketSlug,
  fetchMarketBySlug, getSecondsElapsed, getSecondsRemaining,
  resolveTokenIds
} from "../lib/polymarket";

const WS_URL = "wss://ws-subscriptions-clob.polymarket.com/ws/market";

function pad(n) { return String(n).padStart(2, "0"); }
function fmtS(s) { const m = Math.floor(s / 60); const sec = Math.floor(s % 60); return `${pad(m)}:${pad(sec)}`; }

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
  const [wsState,      setWsState]      = useState("disconnected"); 

  const wsRef        = useRef(null);
  const tickRef      = useRef(null);   
  const cdRef        = useRef(null);   
  const marketRef    = useRef(null);
  const tokenRef     = useRef({ upId: null, downId: null });
  const pricesRef    = useRef({ up: null, down: null }); 
  const historyRef   = useRef([]);
  const slugTsRef    = useRef(null);
  const savedRef     = useRef(false);
  const startFnRef   = useRef(null);

  // â”€â”€ stop everything â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  const stopAll = useCallback(() => {
    clearInterval(tickRef.current);
    clearInterval(cdRef.current);
    tickRef.current = null;
    cdRef.current   = null;
    if (wsRef.current) {
      wsRef.current.onclose = null; 
      wsRef.current.close();
      wsRef.current = null;
    }
    setWsState("disconnected");
  }, []);

  // â”€â”€ save session â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

  // â”€â”€ open WebSocket to Polymarket â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  const openWs = useCallback((upId, downId) => {
    if (wsRef.current) { wsRef.current.onclose = null; wsRef.current.close(); }

    const ws = new WebSocket(WS_URL);
    wsRef.current = ws;

    ws.onopen = () => {
      setWsState("connected");
      const ids = [upId, downId].filter(Boolean);
      ws.send(JSON.stringify({ assets_ids: ids, type: "Market" }));
    };

    ws.onmessage = (e) => {
      try {
        const msgs = JSON.parse(e.data);
        const arr  = Array.isArray(msgs) ? msgs : [msgs];
        for (const msg of arr) {
          const assetId = msg.asset_id ?? msg.assetId ?? msg.token_id;
          const rawPrice = msg.price ?? msg.outcome_price ?? msg.mid ?? null;

          if (rawPrice == null || !assetId) continue;
          const p = parseFloat(rawPrice);
          if (!isFinite(p)) continue; 

          // Filter out crazy noise, but allow reasonable movement
          if (p <= 0.0001 || p >= 0.9999) continue;

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
      } catch { /* ignore */ }
    };

    ws.onerror = () => setWsState("error");
    ws.onclose = () => {
      setWsState("disconnected");
      if (slugTsRef.current && tokenRef.current.upId && !savedRef.current) {
        setTimeout(() => openWs(tokenRef.current.upId, tokenRef.current.downId), 2000);
      }
    };
  }, []);

  // â”€â”€ 1-second clock tick â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  const clockTick = useCallback(() => {
    const slugTs = slugTsRef.current;
    if (slugTs == null) return;

    const el  = getSecondsElapsed(slugTs);
    const rem = getSecondsRemaining(slugTs);
    setElapsed(el);
    setRemaining(rem);

    const { up, down } = pricesRef.current;
    // Only record if we have data or preserve previous
    const lastP = historyRef.current[historyRef.current.length - 1];
    const point = { 
      t: Math.floor(Date.now() / 1000), 
      elapsed: el, 
      up: up ?? lastP?.up, 
      down: down ?? lastP?.down 
    };
    
    const next  = [...historyRef.current, point];
    historyRef.current = next;
    setPriceHistory(next);

    // â”€â”€ MARKET FINISHED â”€â”€
    if (rem <= 0) {
      clearInterval(tickRef.current);
      tickRef.current = null;
      
      // Close WS immediately
      if (wsRef.current) { wsRef.current.onclose = null; wsRef.current.close(); wsRef.current = null; }
      setWsState("disconnected");

      // 1. Determine Winner Locally by Final Price
      // If UP > DOWN (or UP > 0.5), UP wins.
      const finalUp = point.up || 0;
      const finalDown = point.down || 0;
      
      let localOutcome = "UNKNOWN";
      if (finalUp > finalDown) localOutcome = "UP";
      else if (finalDown > finalUp) localOutcome = "DOWN";
      else localOutcome = "UP"; // Tie-breaker fallback (rare)

      setStatus("resolved");
      setOutcome(localOutcome);
      setOutcomeConf(true); // We trust our local data
      setResolving(false);

      // 2. Save Session
      doSave(next, localOutcome);

      // 3. Auto-Advance to Next Slug 
      const nextSlugTs = slugTs + 300;
      setNextIn(1);

      let count = 1;
      cdRef.current = setInterval(() => {
        count--;
        setNextIn(count);
        if (count <= 0) {
          clearInterval(cdRef.current);
          if (startFnRef.current) startFnRef.current(undefined, nextSlugTs);
        }
      }, 1000);
    }
  }, [doSave, openWs]);

  // â”€â”€ main entry â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
    setManualSlug(slug);
    setQuestion("Loading Market...");

    const m = await fetchMarketBySlug(slug);
    
    // Handle market missing (likely next one hasn't been created by API yet)
    if (!m || m.error) {
       // If we are trying to load the FUTURE market and it fails, 
       // retry automatically in 2 seconds
       if (slugTs > (Date.now()/1000)) {
          setErrorMsg("Waiting for market creation...");
          setTimeout(() => startTracking(slugOverride, slugTsOverride), 2000);
          return;
       }
       setErrorMsg("Market not found");
       setStatus("error");
       setQuestion("");
       return;
    }

    // If market already resolved (loading old one)
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

    openWs(ids.upId, ids.downId);

    tickRef.current = setInterval(clockTick, 1000);
    clockTick(); 
  }, [stopAll, openWs, clockTick]);

  useEffect(() => { startFnRef.current = startTracking; }, [startTracking]);
  useEffect(() => { startTracking(); return stopAll; }, []); 

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
            <span className="text-xs font-semibold">
              {wsState === "connected" ? "â— WS" : wsState === "error" ? "â— WS ERR" : "â—‹ WS"}
            </span>
          </div>
          <p className="text-sm text-slate-700 dark:text-slate-300 truncate">{question}</p>
        </div>
        <div className="flex gap-2 items-center shrink-0">
          <span className="px-2 py-0.5 rounded text-xs font-bold">{status.toUpperCase()}</span>
          <button onClick={() => startTracking()}
            className="px-3 py-1 bg-indigo-600 hover:bg-indigo-500 text-white rounded text-xs font-semibold">
            Refresh
          </button>
        </div>
      </div>

      {/* Slug input */}
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
            const ts = parseInt(s.replace(/^.*-(\d+)$/, ""), 10);
            startTracking(s, isNaN(ts) ? undefined : ts);
          }}
          className="px-4 py-1.5 bg-slate-100 hover:bg-slate-200 dark:bg-slate-700 dark:hover:bg-slate-600 rounded text-sm font-semibold text-slate-700 dark:text-slate-200">
          Load
        </button>
      </div>

      {errorMsg && <p className="text-red-500 dark:text-red-400 text-sm">{errorMsg}</p>}

      {/* Stats */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <StatCard label="UP Price"   value={curUp != null ? (curUp*100).toFixed(1) + "c" : "---"} color="text-green-600 dark:text-green-400" />
        <StatCard label="DOWN Price" value={curDown != null ? (curDown*100).toFixed(1) + "c" : "---"} color="text-red-600 dark:text-red-400" />
        <StatCard label="Elapsed"    value={fmtS(elapsed)}   color="text-blue-600 dark:text-blue-400" />
        <StatCard label="Remaining"  value={fmtS(remaining)} color="text-orange-500 dark:text-orange-400" />
      </div>

      {/* Resolved banner */}
      {status === "resolved" && (
        <div className="ounded-xl p-4 text-center border">
            <div>
              <p className="ont-bold text-xl">
                {outcome === "UP"   && "â–² RESOLVED UP"}
                {outcome === "DOWN" && "â–¼ RESOLVED DOWN"}
                {!outcome           && "UNKNOWN RESULT"}
              </p>
              
              {nextIn != null && (
                <p className="text-sm font-bold animate-pulse text-indigo-600 dark:text-indigo-400 mt-2">
                  Next market loading in {nextIn}s...
                </p>
              )}
            </div>
        </div>
      )}

      {/* Chart */}
      <div className="bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 rounded-xl p-4" style={{ height: 300 }}>
        {chartData.length === 0 ? (
          <div className="h-full flex flex-col items-center justify-center gap-2 text-slate-400 text-sm">
            {status === "tracking" ? (
              <>
                <p>Waiting for prices... ({priceHistory.length} pts)</p>
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
        <p className="text-xs text-slate-400">{priceHistory.length} pts Â· {pricedPts} priced Â· WS <span className={wsColor}>{wsState}</span></p>
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
      <p className="text-xl font-bold font-mono">{value}</p>
    </div>
  );
}
