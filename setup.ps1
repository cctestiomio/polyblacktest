# fix.ps1
# Run from inside your polymarket-btc-backtest folder:
#   .\fix.ps1
# Fixes:
#   1. Light mode default + dark mode toggle
#   2. Correct slug format: btc-updown-5m-{ts}
#   3. Auto-detect outcome from final price (no manual marking needed)

Write-Host "Applying fixes..." -ForegroundColor Cyan

# ── globals.css — light mode base ────────────────────────────────────────────
@'
@tailwind base;
@tailwind components;
@tailwind utilities;

:root {
  --bg: #f8fafc;
  --bg2: #f1f5f9;
  --bg3: #e2e8f0;
  --border: #cbd5e1;
  --text1: #0f172a;
  --text2: #475569;
  --text3: #94a3b8;
  --card: #ffffff;
  --nav: rgba(255,255,255,0.85);
}

[data-theme="dark"] {
  --bg: #0a0a0f;
  --bg2: #0f172a;
  --bg3: #1e293b;
  --border: #334155;
  --text1: #f1f5f9;
  --text2: #94a3b8;
  --text3: #475569;
  --card: #111827;
  --nav: rgba(15,23,42,0.85);
}

body {
  background: var(--bg);
  color: var(--text1);
  transition: background 0.2s, color 0.2s;
}
'@ | Set-Content "src/app/globals.css"

# ── tailwind.config.js — enable class-based dark ─────────────────────────────
@'
/** @type {import("tailwindcss").Config} */
module.exports = {
  darkMode: "class",
  content: ["./src/**/*.{js,ts,jsx,tsx,mdx}"],
  theme: { extend: {} },
  plugins: [],
};
'@ | Set-Content "tailwind.config.js"

# ── src/lib/polymarket.js — fixed slug + auto outcome ─────────────────────────
@'
// Helpers for Polymarket CLOB API

export function getCurrentMarketTimestamp() {
  const now = Math.floor(Date.now() / 1000);
  // Markets resolve on 300s boundaries; next one is the active one
  return Math.ceil(now / 300) * 300;
}

// Correct slug format: btc-updown-5m-{ts}
export function getMarketSlug(ts) {
  return `btc-updown-5m-${ts}`;
}

export function getSecondsRemaining(resolutionTs) {
  return Math.max(0, resolutionTs - Math.floor(Date.now() / 1000));
}

export function getSecondsElapsed(resolutionTs) {
  const total = 300;
  const remaining = getSecondsRemaining(resolutionTs);
  return Math.min(total, total - remaining);
}

export async function fetchMarketBySlug(slug) {
  const res = await fetch(`/api/market?slug=${encodeURIComponent(slug)}`);
  if (!res.ok) return null;
  return res.json();
}

export async function fetchMidpoint(tokenId) {
  const res = await fetch(`/api/midpoint?token_id=${tokenId}`);
  if (!res.ok) return null;
  const data = await res.json();
  return parseFloat(data.mid ?? 0);
}

/**
 * Determine outcome from final prices.
 * Whichever token resolves at >= 0.95 is the winner.
 */
export function detectOutcome(upPrice, downPrice) {
  if (upPrice != null && upPrice >= 0.95) return "UP";
  if (downPrice != null && downPrice >= 0.95) return "DOWN";
  // fallback: whichever is higher
  if (upPrice != null && downPrice != null) {
    return upPrice > downPrice ? "UP" : "DOWN";
  }
  return null;
}
'@ | Set-Content "src/lib/polymarket.js"

# ── src/components/ThemeToggle.js ─────────────────────────────────────────────
@'
"use client";
import { useEffect, useState } from "react";

export default function ThemeToggle() {
  const [dark, setDark] = useState(false);

  useEffect(() => {
    const saved = localStorage.getItem("theme");
    if (saved === "dark") {
      document.documentElement.setAttribute("data-theme", "dark");
      document.documentElement.classList.add("dark");
      setDark(true);
    }
  }, []);

  const toggle = () => {
    const next = !dark;
    setDark(next);
    if (next) {
      document.documentElement.setAttribute("data-theme", "dark");
      document.documentElement.classList.add("dark");
      localStorage.setItem("theme", "dark");
    } else {
      document.documentElement.removeAttribute("data-theme");
      document.documentElement.classList.remove("dark");
      localStorage.setItem("theme", "light");
    }
  };

  return (
    <button
      onClick={toggle}
      className="w-9 h-9 flex items-center justify-center rounded-lg border border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-800 text-slate-600 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-700 transition text-base"
      title={dark ? "Switch to light mode" : "Switch to dark mode"}
    >
      {dark ? "☀️" : "🌙"}
    </button>
  );
}
'@ | Set-Content "src/components/ThemeToggle.js"

# ── src/components/LiveTracker.js — auto outcome, no manual marking ───────────
@'
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
'@ | Set-Content "src/components/LiveTracker.js"

# ── src/app/page.js — light mode + theme toggle ───────────────────────────────
@'
"use client";
import { useState, useCallback } from "react";
import Link from "next/link";
import LiveTracker from "../components/LiveTracker";
import ThemeToggle from "../components/ThemeToggle";

const STORAGE_KEY = "pm_sessions";

function loadSessions() {
  if (typeof window === "undefined") return [];
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "[]"); } catch { return []; }
}
function saveSessions(sessions) { localStorage.setItem(STORAGE_KEY, JSON.stringify(sessions)); }

export default function Home() {
  const [sessions, setSessions] = useState(() => loadSessions());
  const [toastMsg, setToastMsg] = useState(null);

  const showToast = (msg) => {
    setToastMsg(msg);
    setTimeout(() => setToastMsg(null), 3000);
  };

  const onSaveSession = useCallback((session) => {
    setSessions(prev => {
      const next = [...prev.filter(s => s.slug !== session.slug), session];
      saveSessions(next);
      return next;
    });
    showToast(`✅ Saved: ${session.slug} (${session.priceHistory.length} pts) — Outcome: ${session.outcome ?? "unknown"}`);
  }, []);

  const downloadSessions = () => {
    if (sessions.length === 0) return;
    const blob = new Blob([JSON.stringify(sessions, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `pm_btc5m_${Date.now()}.json`;
    a.click();
  };

  const clearSessions = () => {
    if (!confirm("Clear all saved sessions from this browser?")) return;
    setSessions([]);
    localStorage.removeItem(STORAGE_KEY);
  };

  return (
    <div className="min-h-screen bg-[var(--bg)] text-[var(--text1)]">
      {/* Toast */}
      {toastMsg && (
        <div className="fixed top-4 right-4 z-50 bg-indigo-600 text-white text-sm font-medium px-4 py-3 rounded-xl shadow-lg max-w-sm">
          {toastMsg}
        </div>
      )}

      {/* Nav */}
      <nav className="border-b border-[var(--border)] bg-[var(--nav)] backdrop-blur sticky top-0 z-10">
        <div className="max-w-5xl mx-auto px-4 py-3 flex items-center gap-4">
          <span className="font-bold text-lg">⚡ PM BTC 5m</span>
          <span className="text-[var(--text2)] text-sm hidden sm:block">Polymarket Tracker & Backtest</span>
          <div className="ml-auto flex gap-3 items-center">
            <Link href="/" className="text-sm font-semibold text-indigo-600 dark:text-indigo-400">Live</Link>
            <Link href="/backtest" className="text-sm text-[var(--text2)] hover:text-[var(--text1)]">Backtest</Link>
            <ThemeToggle />
          </div>
        </div>
      </nav>

      <main className="max-w-5xl mx-auto px-4 py-6 space-y-6">
        {/* Live tracker */}
        <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-5 shadow-sm">
          <h1 className="text-lg font-bold mb-4">🔴 Live Tracker</h1>
          <LiveTracker onSaveSession={onSaveSession} />
        </div>

        {/* Saved sessions */}
        <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-5 shadow-sm">
          <div className="flex items-center gap-3 mb-4">
            <h2 className="text-lg font-bold">Saved Sessions ({sessions.length})</h2>
            <div className="ml-auto flex gap-2">
              <button onClick={downloadSessions} disabled={sessions.length === 0}
                className="px-4 py-1.5 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 text-white rounded-lg text-sm font-semibold">
                ⬇ Download JSON
              </button>
              <button onClick={clearSessions} disabled={sessions.length === 0}
                className="px-4 py-1.5 bg-red-100 hover:bg-red-200 dark:bg-red-900/50 dark:hover:bg-red-900 disabled:opacity-40 text-red-700 dark:text-red-400 rounded-lg text-sm font-semibold">
                Clear
              </button>
            </div>
          </div>
          {sessions.length === 0 ? (
            <p className="text-[var(--text3)] text-sm">No sessions saved yet. Track a market — it auto-saves when the market resolves.</p>
          ) : (
            <div className="space-y-2 max-h-64 overflow-y-auto">
              {[...sessions].reverse().map((s, i) => (
                <div key={i} className="flex items-center gap-3 bg-[var(--bg2)] rounded-lg px-3 py-2 text-sm">
                  <span className="font-mono text-[var(--text3)] truncate flex-1">{s.slug}</span>
                  <span className="text-[var(--text3)]">{s.priceHistory?.length ?? 0} pts</span>
                  {s.outcome ? (
                    <span className={`font-bold ${s.outcome==="UP"?"text-green-600 dark:text-green-400":"text-red-600 dark:text-red-400"}`}>
                      {s.outcome === "UP" ? "▲" : "▼"} {s.outcome}
                    </span>
                  ) : (
                    <span className="text-[var(--text3)]">—</span>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>
      </main>
    </div>
  );
}
'@ | Set-Content "src/app/page.js"

# ── src/app/backtest/page.js — light mode ────────────────────────────────────
@'
"use client";
import { useState, useCallback } from "react";
import Link from "next/link";
import BacktestEngine from "../../components/BacktestEngine";
import ThemeToggle from "../../components/ThemeToggle";

export default function BacktestPage() {
  const [sessions, setSessions] = useState([]);
  const [dragOver, setDragOver] = useState(false);

  const processFiles = useCallback(async (files) => {
    const loaded = [];
    for (const file of Array.from(files)) {
      try {
        const text = await file.text();
        const data = JSON.parse(text);
        const arr = Array.isArray(data) ? data : [data];
        loaded.push(...arr);
      } catch (e) { alert(`Failed to parse ${file.name}: ${e.message}`); }
    }
    setSessions(prev => {
      const all = [...prev, ...loaded];
      const map = new Map(all.map(s => [s.slug, s]));
      return [...map.values()];
    });
  }, []);

  const onDrop = (e) => { e.preventDefault(); setDragOver(false); processFiles(e.dataTransfer.files); };

  const loadFromBrowser = () => {
    try {
      const data = JSON.parse(localStorage.getItem("pm_sessions") ?? "[]");
      setSessions(prev => {
        const all = [...prev, ...data];
        const map = new Map(all.map(s => [s.slug, s]));
        return [...map.values()];
      });
    } catch { alert("No sessions in browser storage."); }
  };

  return (
    <div className="min-h-screen bg-[var(--bg)] text-[var(--text1)]">
      <nav className="border-b border-[var(--border)] bg-[var(--nav)] backdrop-blur sticky top-0 z-10">
        <div className="max-w-5xl mx-auto px-4 py-3 flex items-center gap-4">
          <span className="font-bold text-lg">⚡ PM BTC 5m</span>
          <div className="ml-auto flex gap-3 items-center">
            <Link href="/" className="text-sm text-[var(--text2)] hover:text-[var(--text1)]">Live</Link>
            <Link href="/backtest" className="text-sm font-semibold text-indigo-600 dark:text-indigo-400">Backtest</Link>
            <ThemeToggle />
          </div>
        </div>
      </nav>

      <main className="max-w-5xl mx-auto px-4 py-6 space-y-6">
        <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-5 shadow-sm">
          <h1 className="text-lg font-bold mb-4">📂 Load Session Data</h1>
          <div
            onDragOver={e => { e.preventDefault(); setDragOver(true); }}
            onDragLeave={() => setDragOver(false)}
            onDrop={onDrop}
            className={`border-2 border-dashed rounded-xl p-8 text-center transition ${
              dragOver
                ? "border-indigo-400 bg-indigo-50 dark:bg-indigo-900/20"
                : "border-[var(--border)] hover:border-slate-400 dark:hover:border-slate-500"
            }`}
          >
            <p className="text-[var(--text2)] mb-3">Drop JSON session files here, or</p>
            <label className="cursor-pointer px-5 py-2 bg-indigo-600 hover:bg-indigo-500 text-white rounded-lg text-sm font-semibold">
              Browse Files
              <input type="file" accept=".json" multiple className="hidden" onChange={e => processFiles(e.target.files)} />
            </label>
            <p className="text-xs text-[var(--text3)] mt-3">One file can hold multiple sessions (array export)</p>
          </div>

          <div className="mt-3 flex gap-3 items-center flex-wrap">
            <button onClick={loadFromBrowser}
              className="px-4 py-2 bg-[var(--bg2)] hover:bg-[var(--bg3)] border border-[var(--border)] rounded-lg text-sm font-semibold">
              📥 Load from This Browser
            </button>
            {sessions.length > 0 && (
              <>
                <span className="text-[var(--text2)] text-sm">{sessions.length} sessions loaded</span>
                <button onClick={() => setSessions([])} className="ml-auto text-xs text-red-500 hover:text-red-600">Clear All</button>
              </>
            )}
          </div>

          {sessions.length > 0 && (
            <div className="mt-3 grid grid-cols-1 sm:grid-cols-3 gap-2 max-h-40 overflow-y-auto">
              {sessions.map((s, i) => (
                <div key={i} className="bg-[var(--bg2)] rounded-lg px-3 py-1.5 flex items-center gap-2 text-xs">
                  <span className="truncate flex-1 font-mono text-[var(--text3)]">
                    {s.slug?.replace("btc-updown-5m-","") ?? "?"}
                  </span>
                  <span className="text-[var(--text3)]">{s.priceHistory?.length ?? 0}pts</span>
                  {s.outcome && (
                    <span className={`font-bold ${s.outcome==="UP"?"text-green-600 dark:text-green-400":"text-red-600 dark:text-red-400"}`}>
                      {s.outcome[0]}
                    </span>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>

        <BacktestEngine sessions={sessions} />
      </main>
    </div>
  );
}
'@ | Set-Content "src/app/backtest/page.js"

# ── src/components/BacktestEngine.js — light mode ────────────────────────────
@'
"use client";
import { useState } from "react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid,
  ResponsiveContainer, Cell,
} from "recharts";

export default function BacktestEngine({ sessions }) {
  const [side, setSide]           = useState("UP");
  const [priceMin, setPriceMin]   = useState(0.1);
  const [priceMax, setPriceMax]   = useState(0.9);
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);
  const [groupBy, setGroupBy]     = useState("priceRange");
  const [results, setResults]     = useState(null);

  const runBacktest = () => {
    const trades = [];

    for (const session of sessions) {
      if (!session.outcome) continue;
      for (const point of session.priceHistory ?? []) {
        const el    = point.elapsed ?? 0;
        if (el < elapsedMin || el > elapsedMax) continue;

        const sides = side === "BOTH" ? ["UP","DOWN"] : [side];
        for (const s of sides) {
          const price = s === "DOWN" ? point.down : point.up;
          if (price == null || price < priceMin || price > priceMax) continue;
          const win = session.outcome === s;
          trades.push({ slug: session.slug, elapsed: el, price, side: s, outcome: session.outcome, win });
        }
      }
    }

    if (!trades.length) { setResults({ trades: [], summary: null, chart: [] }); return; }

    const wins    = trades.filter(t => t.win).length;
    const winRate = wins / trades.length;

    let chart = [];
    if (groupBy === "priceRange") {
      const b = {};
      for (const t of trades) {
        const k = `${Math.floor(t.price * 10) * 10}¢`;
        b[k] = b[k] ?? { wins: 0, total: 0 };
        b[k].total++; if (t.win) b[k].wins++;
      }
      chart = Object.entries(b)
        .sort((a,b) => parseFloat(a[0])-parseFloat(b[0]))
        .map(([label,{wins,total}]) => ({ label, winRate: +((wins/total)*100).toFixed(1), total, wins }));
    } else {
      const b = {};
      for (const t of trades) {
        const k = `${Math.floor(t.elapsed / 30) * 30}s`;
        b[k] = b[k] ?? { wins: 0, total: 0 };
        b[k].total++; if (t.win) b[k].wins++;
      }
      chart = Object.entries(b)
        .sort((a,b) => parseInt(a[0])-parseInt(b[0]))
        .map(([label,{wins,total}]) => ({ label, winRate: +((wins/total)*100).toFixed(1), total, wins }));
    }
    setResults({ trades, summary: { total: trades.length, wins, winRate }, chart });
  };

  return (
    <div className="space-y-6">
      <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-5 shadow-sm space-y-4">
        <h2 className="text-lg font-bold">Backtest Configuration</h2>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Buy Side</label>
            <div className="flex gap-2">
              {["UP","DOWN","BOTH"].map(s => (
                <button key={s} onClick={() => setSide(s)}
                  className={`flex-1 py-2 rounded-lg font-bold text-sm transition ${
                    side===s
                      ? "bg-indigo-600 text-white"
                      : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
                  }`}>{s}</button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Group Results By</label>
            <div className="flex gap-2">
              {[["priceRange","Price Range"],["elapsedRange","Time Elapsed"]].map(([v,l]) => (
                <button key={v} onClick={() => setGroupBy(v)}
                  className={`flex-1 py-2 rounded-lg text-sm transition ${
                    groupBy===v
                      ? "bg-indigo-600 text-white"
                      : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
                  }`}>{l}</button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Entry Price Range (0–1)</label>
            <div className="flex gap-2 items-center">
              <input type="number" min="0" max="1" step="0.01" value={priceMin}
                onChange={e => setPriceMin(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]" />
              <span className="text-[var(--text3)]">to</span>
              <input type="number" min="0" max="1" step="0.01" value={priceMax}
                onChange={e => setPriceMax(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]" />
            </div>
            <p className="text-xs text-[var(--text3)] mt-1">e.g. 0.55–0.65 = near 60¢</p>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Time Elapsed Range (seconds 0–300)</label>
            <div className="flex gap-2 items-center">
              <input type="number" min="0" max="300" step="1" value={elapsedMin}
                onChange={e => setElapsedMin(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]" />
              <span className="text-[var(--text3)]">to</span>
              <input type="number" min="0" max="300" step="1" value={elapsedMax}
                onChange={e => setElapsedMax(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]" />
            </div>
          </div>
        </div>

        <button onClick={runBacktest} disabled={sessions.length === 0}
          className="w-full py-3 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 text-white rounded-xl font-bold text-base">
          ▶ Run Backtest ({sessions.length} session{sessions.length !== 1 ? "s" : ""} loaded)
        </button>
      </div>

      {results && (
        <div className="space-y-4">
          {results.summary ? (
            <>
              <div className="grid grid-cols-3 gap-3">
                <SCard label="Total Trades" value={results.summary.total} color="text-blue-600 dark:text-blue-400" />
                <SCard label="Wins" value={results.summary.wins} color="text-green-600 dark:text-green-400" />
                <SCard
                  label="Win Rate"
                  value={`${(results.summary.winRate*100).toFixed(1)}%`}
                  color={results.summary.winRate >= 0.5 ? "text-green-600 dark:text-green-400" : "text-red-600 dark:text-red-400"}
                />
              </div>

              {results.chart.length > 0 && (
                <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm" style={{ height: 300 }}>
                  <p className="text-xs text-[var(--text2)] mb-3">Win Rate by {groupBy === "priceRange" ? "Entry Price" : "Elapsed Time"}</p>
                  <ResponsiveContainer width="100%" height="90%">
                    <BarChart data={results.chart}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                      <XAxis dataKey="label" stroke="#94a3b8" tick={{ fontSize: 11 }} />
                      <YAxis domain={[0,100]} tickFormatter={v => `${v}%`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                      <Tooltip
                        formatter={(v,n) => [n==="winRate"?`${v}%`:v, n==="winRate"?"Win Rate":"Trades"]}
                        contentStyle={{ background:"var(--card)", border:"1px solid var(--border)", borderRadius:8 }}
                      />
                      <Bar dataKey="winRate" radius={[4,4,0,0]}>
                        {results.chart.map((e,i) => (
                          <Cell key={i} fill={e.winRate >= 50 ? "#16a34a" : "#dc2626"} />
                        ))}
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              )}

              <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm">
                <p className="text-xs text-[var(--text2)] mb-3">Trade Log (last 50)</p>
                <div className="overflow-x-auto">
                  <table className="w-full text-xs text-[var(--text1)]">
                    <thead>
                      <tr className="text-[var(--text3)] border-b border-[var(--border)]">
                        <th className="text-left py-1 pr-4">Slug</th>
                        <th className="text-right pr-4">Elapsed</th>
                        <th className="text-right pr-4">Price</th>
                        <th className="text-right pr-4">Side</th>
                        <th className="text-right pr-4">Outcome</th>
                        <th className="text-right">Result</th>
                      </tr>
                    </thead>
                    <tbody>
                      {results.trades.slice(-50).reverse().map((t,i) => (
                        <tr key={i} className="border-b border-[var(--border)] hover:bg-[var(--bg2)]">
                          <td className="py-1 pr-4 truncate max-w-xs font-mono text-[var(--text3)]">{t.slug}</td>
                          <td className="text-right pr-4">{t.elapsed}s</td>
                          <td className="text-right pr-4">{(t.price*100).toFixed(1)}¢</td>
                          <td className={`text-right pr-4 font-bold ${t.side==="UP"?"text-green-600":"text-red-600"}`}>{t.side}</td>
                          <td className={`text-right pr-4 font-bold ${t.outcome==="UP"?"text-green-600":"text-red-600"}`}>{t.outcome}</td>
                          <td className={`text-right font-bold ${t.win?"text-green-600":"text-red-600"}`}>{t.win?"✓":"✗"}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            </>
          ) : (
            <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-6 text-center text-[var(--text3)]">
              No matching trades. Widen your price/time range, or ensure sessions have outcomes detected.
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function SCard({ label, value, color }) {
  return (
    <div className="bg-[var(--card)] border border-[var(--border)] rounded-xl p-4 text-center shadow-sm">
      <p className="text-xs text-[var(--text2)] mb-1">{label}</p>
      <p className={`text-2xl font-bold font-mono ${color}`}>{value}</p>
    </div>
  );
}
'@ | Set-Content "src/components/BacktestEngine.js"

# ── Update tracker.py slug ────────────────────────────────────────────────────
(Get-Content tracker.py) -replace 'btc-up-or-down-in-5-minutes-', 'btc-updown-5m-' | Set-Content tracker.py
(Get-Content tracker.py) -replace 'f"btc-up-or-down-in-5-minutes-\{ts\}"', 'f"btc-updown-5m-{ts}"' | Set-Content tracker.py

Write-Host ""
Write-Host "✅ All fixes applied!" -ForegroundColor Green
Write-Host ""
Write-Host "Changes:" -ForegroundColor Yellow
Write-Host "  ✓ Light mode default, moon/sun toggle persists to localStorage"
Write-Host "  ✓ Slug format: btc-updown-5m-{timestamp}"
Write-Host "  ✓ Outcome auto-detected from final price (>=95c side wins)"
Write-Host "  ✓ Auto-saves session on market resolution"
Write-Host "  ✓ Countdown to next market after resolution"
Write-Host "  ✓ tracker.py slug also updated"
Write-Host ""
Write-Host "Restart dev server:" -ForegroundColor Cyan
Write-Host "  npm run dev"