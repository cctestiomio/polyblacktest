"use client";
import { useEffect, useRef, useState, useCallback } from "react";
import { LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, ResponsiveContainer, ReferenceLine } from "recharts";
import {
  getCurrentMarketTimestamp,
  getMarketSlug,
  fetchMarketBySlug,
  fetchMidpoint,
  getSecondsElapsed,
  getSecondsRemaining,
} from "../lib/polymarket";

const POLL_MS = 1500; // poll every 1.5 s

function pad(n) { return String(n).padStart(2, "0"); }
function fmtSeconds(s) { return `${pad(Math.floor(s / 60))}:${pad(s % 60)}`; }

export default function LiveTracker({ onSaveSession }) {
  const [status, setStatus] = useState("idle"); // idle | loading | tracking | resolved | error
  const [market, setMarket] = useState(null);
  const [priceHistory, setPriceHistory] = useState([]);
  const [elapsed, setElapsed] = useState(0);
  const [remaining, setRemaining] = useState(300);
  const [currentUp, setCurrentUp] = useState(null);
  const [errorMsg, setErrorMsg] = useState("");
  const [manualSlug, setManualSlug] = useState("");
  const [outcome, setOutcome] = useState(null); // "UP"|"DOWN"|null
  const intervalRef = useRef(null);
  const marketRef = useRef(null);
  const historyRef = useRef([]);
  const resolutionTsRef = useRef(null);

  const stopTracking = useCallback(() => {
    if (intervalRef.current) clearInterval(intervalRef.current);
    intervalRef.current = null;
  }, []);

  const tick = useCallback(async () => {
    const m = marketRef.current;
    if (!m) return;
    const rts = resolutionTsRef.current;
    const el = getSecondsElapsed(rts);
    const rem = getSecondsRemaining(rts);
    setElapsed(el);
    setRemaining(rem);

    // Find UP token id
    let upTokenId = null;
    let downTokenId = null;
    if (m.tokens && m.tokens.length > 0) {
      for (const t of m.tokens) {
        const outcome = (t.outcome ?? "").toLowerCase();
        if (outcome === "up") upTokenId = t.token_id ?? t.tokenId ?? t;
        if (outcome === "down") downTokenId = t.token_id ?? t.tokenId ?? t;
      }
      // fallback: first=UP, second=DOWN
      if (!upTokenId && m.tokens[0]) upTokenId = m.tokens[0].token_id ?? m.tokens[0].tokenId ?? m.tokens[0];
      if (!downTokenId && m.tokens[1]) downTokenId = m.tokens[1].token_id ?? m.tokens[1].tokenId ?? m.tokens[1];
    }

    if (!upTokenId) return;

    try {
      const [upPrice, downPrice] = await Promise.all([
        fetchMidpoint(String(upTokenId)),
        downTokenId ? fetchMidpoint(String(downTokenId)) : Promise.resolve(null),
      ]);

      const point = {
        t: Math.floor(Date.now() / 1000),
        elapsed: el,
        up: upPrice,
        down: downPrice ?? (upPrice != null ? 1 - upPrice : null),
      };
      historyRef.current = [...historyRef.current, point];
      setPriceHistory([...historyRef.current]);
      setCurrentUp(upPrice);

      if (rem <= 0) {
        setStatus("resolved");
        stopTracking();
      }
    } catch (e) {
      console.error("tick error", e);
    }
  }, [stopTracking]);

  const startTracking = useCallback(async (slugOverride) => {
    stopTracking();
    setStatus("loading");
    setErrorMsg("");
    setPriceHistory([]);
    historyRef.current = [];
    setOutcome(null);

    const rts = getCurrentMarketTimestamp();
    resolutionTsRef.current = rts;
    const slug = slugOverride || getMarketSlug(rts);

    const m = await fetchMarketBySlug(slug);
    if (!m || m.error) {
      setErrorMsg(`Market not found: ${slug}. Try a different timestamp or check Polymarket.`);
      setStatus("error");
      return;
    }
    marketRef.current = m;
    setMarket(m);
    setStatus("tracking");

    await tick();
    intervalRef.current = setInterval(tick, POLL_MS);
  }, [stopTracking, tick]);

  // Auto-start on mount
  useEffect(() => {
    startTracking();
    return stopTracking;
  }, []); // eslint-disable-line

  // Auto-rotate to next market when resolved
  useEffect(() => {
    if (status !== "resolved") return;
    const timer = setTimeout(() => startTracking(), 5000);
    return () => clearTimeout(timer);
  }, [status, startTracking]);

  const handleSave = () => {
    if (!market || historyRef.current.length === 0) return;
    const session = {
      slug: market.slug,
      resolutionTs: resolutionTsRef.current,
      question: market.question,
      outcome,
      priceHistory: historyRef.current,
      savedAt: Date.now(),
    };
    onSaveSession(session);
  };

  const chartData = priceHistory.map((p) => ({
    elapsed: p.elapsed,
    UP: p.up != null ? +(p.up * 100).toFixed(2) : null,
    DOWN: p.down != null ? +(p.down * 100).toFixed(2) : null,
  }));

  return (
    <div className="space-y-4">
      {/* Header bar */}
      <div className="flex flex-wrap items-center gap-3">
        <div className="flex-1 min-w-0">
          <p className="text-xs text-slate-400 truncate">{market?.slug ?? "Searching for market…"}</p>
          <p className="text-sm text-slate-300 truncate">{market?.question ?? ""}</p>
        </div>
        <div className="flex gap-2 items-center">
          <span className={`px-2 py-0.5 rounded text-xs font-bold ${
            status === "tracking" ? "bg-green-900 text-green-300" :
            status === "resolved" ? "bg-yellow-900 text-yellow-300" :
            status === "loading" ? "bg-blue-900 text-blue-300" :
            "bg-red-900 text-red-300"
          }`}>{status.toUpperCase()}</span>
          <button onClick={() => startTracking()} className="px-3 py-1 bg-indigo-700 hover:bg-indigo-600 rounded text-xs font-semibold">
            Refresh
          </button>
        </div>
      </div>

      {/* Manual slug input */}
      <div className="flex gap-2">
        <input
          value={manualSlug}
          onChange={e => setManualSlug(e.target.value)}
          placeholder="Custom slug: btc-up-or-down-in-5-minutes-1771464600"
          className="flex-1 bg-slate-800 border border-slate-600 rounded px-3 py-1.5 text-sm text-slate-200 placeholder-slate-500"
        />
        <button
          onClick={() => startTracking(manualSlug || undefined)}
          className="px-4 py-1.5 bg-slate-700 hover:bg-slate-600 rounded text-sm font-semibold"
        >
          Load
        </button>
      </div>

      {errorMsg && <p className="text-red-400 text-sm">{errorMsg}</p>}

      {/* Stats */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <StatCard label="UP Price" value={currentUp != null ? `$${currentUp.toFixed(3)}` : "—"} color="text-green-400" />
        <StatCard label="DOWN Price" value={currentUp != null ? `$${(1-currentUp).toFixed(3)}` : "—"} color="text-red-400" />
        <StatCard label="Elapsed" value={fmtSeconds(elapsed)} color="text-blue-400" />
        <StatCard label="Remaining" value={fmtSeconds(remaining)} color="text-orange-400" />
      </div>

      {/* Price chart */}
      <div className="bg-slate-900 rounded-xl p-4" style={{ height: 280 }}>
        {chartData.length === 0 ? (
          <div className="h-full flex items-center justify-center text-slate-500 text-sm">Waiting for price data…</div>
        ) : (
          <ResponsiveContainer width="100%" height="100%">
            <LineChart data={chartData}>
              <CartesianGrid strokeDasharray="3 3" stroke="#1e293b" />
              <XAxis dataKey="elapsed" tickFormatter={v => `${v}s`} stroke="#475569" tick={{ fontSize: 11 }} />
              <YAxis domain={[0, 100]} tickFormatter={v => `${v}¢`} stroke="#475569" tick={{ fontSize: 11 }} />
              <Tooltip
                formatter={(v, name) => [`${v}¢`, name]}
                labelFormatter={v => `${v}s elapsed`}
                contentStyle={{ background: "#1e293b", border: "none", borderRadius: 8 }}
              />
              <ReferenceLine y={50} stroke="#475569" strokeDasharray="4 2" />
              <Line type="monotone" dataKey="UP" stroke="#4ade80" dot={false} strokeWidth={2} />
              <Line type="monotone" dataKey="DOWN" stroke="#f87171" dot={false} strokeWidth={2} />
            </LineChart>
          </ResponsiveContainer>
        )}
      </div>

      {/* Save controls */}
      <div className="flex flex-wrap gap-3 items-center">
        <span className="text-sm text-slate-400">Mark outcome:</span>
        <button
          onClick={() => setOutcome("UP")}
          className={`px-4 py-1.5 rounded font-bold text-sm transition ${outcome === "UP" ? "bg-green-500 text-white" : "bg-slate-800 hover:bg-green-900 text-green-400"}`}
        >▲ UP</button>
        <button
          onClick={() => setOutcome("DOWN")}
          className={`px-4 py-1.5 rounded font-bold text-sm transition ${outcome === "DOWN" ? "bg-red-500 text-white" : "bg-slate-800 hover:bg-red-900 text-red-400"}`}
        >▼ DOWN</button>
        <button
          onClick={handleSave}
          disabled={priceHistory.length === 0}
          className="ml-auto px-5 py-1.5 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 rounded font-semibold text-sm"
        >
          💾 Save Session
        </button>
      </div>
    </div>
  );
}

function StatCard({ label, value, color }) {
  return (
    <div className="bg-slate-900 rounded-xl p-3 text-center">
      <p className="text-xs text-slate-500 mb-1">{label}</p>
      <p className={`text-xl font-bold font-mono ${color}`}>{value}</p>
    </div>
  );
}
