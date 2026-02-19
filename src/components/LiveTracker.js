"use client";
import { useEffect, useRef, useState, useCallback } from "react";
import {
  LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid,
  ResponsiveContainer, ReferenceLine,
} from "recharts";
import {
  getCurrentMarketTimestamp, getMarketSlug, fetchMarketBySlug,
  fetchMidpoint, getSecondsElapsed, getSecondsRemaining, detectOutcome,
} from "../lib/polymarket";

const POLL_MS = 1500;
function pad(n) { return String(n).padStart(2, "0"); }
function fmtSeconds(s) { return `${pad(Math.floor(s / 60))}:${pad(s % 60)}`; }

export default function LiveTracker({ onSaveSession }) {
  const [status, setStatus]           = useState("idle");
  const [market, setMarket]           = useState(null);
  const [priceHistory, setPriceHistory] = useState([]);
  const [elapsed, setElapsed]         = useState(0);
  const [remaining, setRemaining]     = useState(300);
  const [currentUp, setCurrentUp]     = useState(null);
  const [currentDown, setCurrentDown] = useState(null);
  const [outcome, setOutcome]         = useState(null);
  const [errorMsg, setErrorMsg]       = useState("");
  const [manualSlug, setManualSlug]   = useState("");
  const [nextIn, setNextIn]           = useState(null); // countdown to next market

  const intervalRef    = useRef(null);
  const marketRef      = useRef(null);
  const historyRef     = useRef([]);
  const resolutionTsRef = useRef(null);
  const tokenIdsRef    = useRef({ up: null, down: null });
  const savedRef       = useRef(false);

  const stopTracking = useCallback(() => {
    if (intervalRef.current) clearInterval(intervalRef.current);
    intervalRef.current = null;
  }, []);

  const resolveTokenIds = useCallback((m) => {
    let upId = null, downId = null;
    const tokens = m.tokens ?? [];
    for (const t of tokens) {
      const o = (t.outcome ?? "").toLowerCase();
      const id = String(t.token_id ?? t.tokenId ?? t);
      if (o === "up")   upId   = id;
      if (o === "down") downId = id;
    }
    if (!upId   && tokens[0]) upId   = String(tokens[0].token_id ?? tokens[0].tokenId ?? tokens[0]);
    if (!downId && tokens[1]) downId = String(tokens[1].token_id ?? tokens[1].tokenId ?? tokens[1]);
    return { up: upId, down: downId };
  }, []);

  const doSave = useCallback((history, det) => {
    if (savedRef.current || history.length === 0 || !marketRef.current) return;
    savedRef.current = true;
    const session = {
      slug: marketRef.current.slug,
      resolutionTs: resolutionTsRef.current,
      question: marketRef.current.question,
      outcome: det,
      priceHistory: history,
      savedAt: Date.now(),
    };
    onSaveSession(session);
  }, [onSaveSession]);

  const tick = useCallback(async () => {
    const rts = resolutionTsRef.current;
    if (!rts) return;
    const el  = getSecondsElapsed(rts);
    const rem = getSecondsRemaining(rts);
    setElapsed(el);
    setRemaining(rem);

    const { up: upId, down: downId } = tokenIdsRef.current;
    if (!upId) return;

    try {
      const [upPrice, downPrice] = await Promise.all([
        fetchMidpoint(upId),
        downId ? fetchMidpoint(downId) : Promise.resolve(null),
      ]);

      const up   = upPrice;
      const down = downPrice ?? (up != null ? +(1 - up).toFixed(4) : null);

      const point = { t: Math.floor(Date.now() / 1000), elapsed: el, up, down };
      const newHistory = [...historyRef.current, point];
      historyRef.current = newHistory;
      setPriceHistory(newHistory);
      setCurrentUp(up);
      setCurrentDown(down);

      if (rem <= 0) {
        // Auto-detect outcome from final price
        const det = detectOutcome(up, down);
        setOutcome(det);
        setStatus("resolved");
        stopTracking();
        doSave(newHistory, det);

        // Countdown to next market
        const nextTs = rts + 300;
        const countdownInterval = setInterval(() => {
          const secUntil = nextTs - Math.floor(Date.now() / 1000);
          setNextIn(Math.max(0, secUntil));
          if (secUntil <= 0) {
            clearInterval(countdownInterval);
            setNextIn(null);
            startTracking();
          }
        }, 1000);
      }
    } catch (e) {
      console.error("tick error", e);
    }
  }, [stopTracking, doSave]); // eslint-disable-line

  // eslint-disable-next-line
  const startTracking = useCallback(async (slugOverride) => {
    stopTracking();
    setStatus("loading");
    setErrorMsg("");
    setPriceHistory([]);
    historyRef.current = [];
    setOutcome(null);
    setNextIn(null);
    savedRef.current = false;

    const rts  = getCurrentMarketTimestamp();
    resolutionTsRef.current = rts;
    const slug = slugOverride || getMarketSlug(rts);

    const m = await fetchMarketBySlug(slug);
    if (!m || m.error) {
      setErrorMsg(`Market not found: ${slug}. Try loading a specific slug.`);
      setStatus("error");
      return;
    }
    marketRef.current    = m;
    tokenIdsRef.current  = resolveTokenIds(m);
    setMarket(m);
    setStatus("tracking");

    await tick();
    intervalRef.current = setInterval(tick, POLL_MS);
  }, [stopTracking, tick, resolveTokenIds]);

  useEffect(() => { startTracking(); return stopTracking; }, []); // eslint-disable-line

  const handleManualSave = () => {
    const det = outcome ?? detectOutcome(currentUp, currentDown);
    doSave(historyRef.current, det);
  };

  const chartData = priceHistory.map((p) => ({
    elapsed: p.elapsed,
    UP:   p.up   != null ? +(p.up   * 100).toFixed(2) : null,
    DOWN: p.down != null ? +(p.down * 100).toFixed(2) : null,
  }));

  const statusColor = {
    tracking: "bg-green-100 text-green-700 dark:bg-green-900/60 dark:text-green-300",
    resolved: "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/60 dark:text-yellow-300",
    loading:  "bg-blue-100 text-blue-700 dark:bg-blue-900/60 dark:text-blue-300",
    error:    "bg-red-100 text-red-700 dark:bg-red-900/60 dark:text-red-300",
    idle:     "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400",
  }[status] ?? "";

  return (
    <div className="space-y-4">
      {/* Header bar */}
      <div className="flex flex-wrap items-center gap-3">
        <div className="flex-1 min-w-0">
          <p className="text-xs text-slate-400 dark:text-slate-500 truncate font-mono">
            {market?.slug ?? "Searching for market…"}
          </p>
          <p className="text-sm text-slate-600 dark:text-slate-300 truncate">{market?.question ?? ""}</p>
        </div>
        <div className="flex gap-2 items-center">
          <span className={`px-2 py-0.5 rounded text-xs font-bold ${statusColor}`}>
            {status.toUpperCase()}
          </span>
          <button onClick={() => startTracking()}
            className="px-3 py-1 bg-indigo-600 hover:bg-indigo-500 text-white rounded text-xs font-semibold">
            Refresh
          </button>
        </div>
      </div>

      {/* Manual slug */}
      <div className="flex gap-2">
        <input value={manualSlug} onChange={e => setManualSlug(e.target.value)}
          placeholder="Custom slug: btc-updown-5m-1771464600"
          className="flex-1 bg-white dark:bg-slate-800 border border-slate-300 dark:border-slate-600 rounded px-3 py-1.5 text-sm text-slate-800 dark:text-slate-200 placeholder-slate-400" />
        <button onClick={() => startTracking(manualSlug || undefined)}
          className="px-4 py-1.5 bg-slate-100 hover:bg-slate-200 dark:bg-slate-700 dark:hover:bg-slate-600 rounded text-sm font-semibold text-slate-700 dark:text-slate-200">
          Load
        </button>
      </div>

      {errorMsg && <p className="text-red-500 dark:text-red-400 text-sm">{errorMsg}</p>}

      {/* Stats */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <StatCard label="UP Price"  value={currentUp   != null ? `${(currentUp*100).toFixed(1)}¢`   : "—"} color="text-green-600 dark:text-green-400" />
        <StatCard label="DOWN Price" value={currentDown != null ? `${(currentDown*100).toFixed(1)}¢` : "—"} color="text-red-600 dark:text-red-400" />
        <StatCard label="Elapsed"   value={fmtSeconds(elapsed)}   color="text-blue-600 dark:text-blue-400" />
        <StatCard label="Remaining" value={fmtSeconds(remaining)} color="text-orange-600 dark:text-orange-400" />
      </div>

      {/* Resolved banner */}
      {status === "resolved" && (
        <div className={`rounded-xl p-4 text-center font-bold text-lg ${
          outcome === "UP"
            ? "bg-green-50 dark:bg-green-900/30 text-green-700 dark:text-green-300 border border-green-200 dark:border-green-800"
            : "bg-red-50 dark:bg-red-900/30 text-red-700 dark:text-red-300 border border-red-200 dark:border-red-800"
        }`}>
          {outcome === "UP" ? "▲ RESOLVED UP" : "▼ RESOLVED DOWN"}
          {nextIn != null && (
            <span className="ml-4 text-sm font-normal text-slate-500 dark:text-slate-400">
              Next market in {fmtSeconds(nextIn)}
            </span>
          )}
        </div>
      )}

      {/* Price chart */}
      <div className="bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 rounded-xl p-4"
           style={{ height: 280 }}>
        {chartData.length === 0 ? (
          <div className="h-full flex items-center justify-center text-slate-400 text-sm">
            Waiting for price data…
          </div>
        ) : (
          <ResponsiveContainer width="100%" height="100%">
            <LineChart data={chartData}>
              <CartesianGrid strokeDasharray="3 3" stroke="#e2e8f0" className="dark:[stroke:#1e293b]" />
              <XAxis dataKey="elapsed" tickFormatter={v => `${v}s`}
                stroke="#94a3b8" tick={{ fontSize: 11 }} />
              <YAxis domain={[0, 100]} tickFormatter={v => `${v}¢`}
                stroke="#94a3b8" tick={{ fontSize: 11 }} />
              <Tooltip
                formatter={(v, name) => [`${v}¢`, name]}
                labelFormatter={v => `${v}s elapsed`}
                contentStyle={{ background: "#fff", border: "1px solid #e2e8f0", borderRadius: 8, color: "#0f172a" }}
              />
              <ReferenceLine y={50} stroke="#94a3b8" strokeDasharray="4 2" />
              <Line type="monotone" dataKey="UP"   stroke="#16a34a" dot={false} strokeWidth={2} />
              <Line type="monotone" dataKey="DOWN" stroke="#dc2626" dot={false} strokeWidth={2} />
            </LineChart>
          </ResponsiveContainer>
        )}
      </div>

      {/* Save button */}
      <div className="flex justify-end">
        <button onClick={handleManualSave} disabled={priceHistory.length === 0}
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
