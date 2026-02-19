"use client";
import { useEffect, useRef, useState, useCallback } from "react";
import { LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, ResponsiveContainer, ReferenceLine } from "recharts";
import {
  getCurrentMarketTimestamp, getMarketSlug, fetchMarketBySlug,
  fetchMidpoint, getSecondsElapsed, getSecondsRemaining,
  detectOutcome, resolveTokenIds, pollForOutcome,
} from "../lib/polymarket";

const POLL_MS = 1000;
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
  const [outcome,      setOutcome]      = useState(null);         // final confirmed outcome
  const [outcomeConf,  setOutcomeConf]  = useState(false);        // high confidence?
  const [resolving,    setResolving]    = useState(false);        // polling for outcome
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
    if (up != null && down != null && Math.abs(up + down - 1) > 0.15) { up = null; down = null; }

    const point = { t: Math.floor(Date.now() / 1000), elapsed: el, up, down };
    const next  = [...historyRef.current, point];
    historyRef.current = next;
    setPriceHistory(next);
    setCurUp(up);
    setCurDown(down);
    setPricedPts(next.filter(p => p.up != null).length);

    if (rem <= 0) {
      setStatus("resolved");
      setResolving(true);
      clearInterval(intervalRef.current);
      intervalRef.current = null;

      // ── Poll for real settled outcome (up to 60s, every 3s) ──────────────
      const { upId: uid, downId: did } = tokenRef.current;
      const snapshot = [...historyRef.current];

      pollForOutcome(uid, did, 20, 3000).then(polledOutcome => {
        setResolving(false);
        let finalOutcome = polledOutcome;

        if (!finalOutcome) {
          // Fallback: look at the last 10 priced points and pick the dominant side
          const priced = snapshot.filter(p => p.up != null && p.down != null).slice(-10);
          if (priced.length > 0) {
            const avgUp = priced.reduce((s, p) => s + p.up, 0) / priced.length;
            const { outcome: guessed } = detectOutcome(avgUp, 1 - avgUp);
            finalOutcome = guessed;
          }
        }

        setOutcome(finalOutcome);
        setOutcomeConf(!!polledOutcome); // confident only if poll succeeded
        doSave(snapshot, finalOutcome);

        // Countdown to next market
        const nextTs = (resolutionRef.current ?? 0) + 300;
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
      });
    }
  }, [doSave]);

  const startTracking = useCallback(async (slugOverride, rtsOverride) => {
    stopAll();
    setStatus("loading");
    setErrorMsg("");
    setPriceHistory([]);
    historyRef.current = [];
    setOutcome(null);
    setOutcomeConf(false);
    setResolving(false);
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

      {/* Header */}
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

      {/* Manual slug */}
      <div className="flex gap-2">
        <input value={manualSlug} onChange={e => setManualSlug(e.target.value)}
          placeholder="btc-updown-5m-1771467600"
          className="flex-1 bg-white dark:bg-slate-800 border border-slate-300 dark:border-slate-600 rounded px-3 py-1.5 text-sm text-slate-800 dark:text-slate-200 placeholder-slate-400" />
        <button onClick={() => {
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

      {/* Token debug */}
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
              <p className="text-slate-500 dark:text-slate-400 font-semibold animate-pulse">
                Waiting for settlement price...
              </p>
              <p className="text-xs text-slate-400 mt-1">Polling every 3s (up to 60s)</p>
            </div>
          ) : (
            <div>
              <p className={`font-bold text-lg ${outcome === "UP" ? "text-green-700 dark:text-green-300" : outcome === "DOWN" ? "text-red-700 dark:text-red-300" : "text-slate-600"}`}>
                {outcome === "UP" ? "UP RESOLVED UP" : outcome === "DOWN" ? "DOWN RESOLVED DOWN" : "RESOLVED - unknown outcome"}
              </p>
              {!outcomeConf && outcome && (
                <p className="text-xs text-amber-600 dark:text-amber-400 mt-1">
                  Low confidence - CLOB did not settle to 95c+ within 60s. Please verify on Polymarket.
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
            <p>{status === "tracking" ? `Waiting for prices... (${priceHistory.length} pts polled)` : "No price data"}</p>
            {status === "tracking" && priceHistory.length > 10 && pricedPts === 0 && (
              <p className="text-xs text-red-500 text-center max-w-sm">
                All prices null. Check /api/debug?slug={slugLabel}
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

      {/* Save */}
      <div className="flex items-center justify-between">
        <p className="text-xs text-slate-400">{priceHistory.length} pts recorded - {pricedPts} with price data</p>
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
