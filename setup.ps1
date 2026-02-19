# fix4.ps1 - Fix incorrect outcome detection
# Run from inside polymarket-btc-backtest:  .\fix4.ps1

Write-Host "Applying fix4 - outcome detection fixes..." -ForegroundColor Cyan

# ── src/lib/polymarket.js ─────────────────────────────────────────────────────
$lib = @'
export function getCurrentMarketTimestamp() {
  const now = Math.floor(Date.now() / 1000);
  const adjusted = (now % 300 === 0) ? now + 1 : now;
  return Math.ceil(adjusted / 300) * 300;
}
export function getMarketSlug(ts) { return `btc-updown-5m-${ts}`; }
export function getSecondsRemaining(ts) { return Math.max(0, ts - Math.floor(Date.now() / 1000)); }
export function getSecondsElapsed(ts)   { return Math.min(300, 300 - getSecondsRemaining(ts)); }

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
    const f = parseFloat(data.mid);
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

/**
 * Detect outcome with confidence level.
 * Returns { outcome: "UP"|"DOWN"|null, confident: boolean }
 * 
 * "Confident" = one side is >= 0.90 (approaching resolution price).
 * If neither side is confident, outcome is a guess and should be flagged.
 */
export function detectOutcome(up, down) {
  const CONFIDENT_THRESHOLD = 0.90;
  if (up   != null && up   >= CONFIDENT_THRESHOLD) return { outcome: "UP",   confident: true };
  if (down != null && down >= CONFIDENT_THRESHOLD) return { outcome: "DOWN", confident: true };
  // Low confidence — prices haven't settled yet (market resolved on-chain but CLOB not updated)
  if (up != null && down != null) {
    return { outcome: up > down ? "UP" : "DOWN", confident: false };
  }
  return { outcome: null, confident: false };
}

/**
 * Poll for resolved outcome — after resolution, retry until one side hits 0.90+
 * or until maxAttempts is reached. Returns "UP", "DOWN", or null.
 */
export async function pollForOutcome(upId, downId, maxAttempts = 20, intervalMs = 3000) {
  for (let i = 0; i < maxAttempts; i++) {
    if (i > 0) await new Promise(r => setTimeout(r, intervalMs));
    const [up, down] = await Promise.all([
      fetchMidpoint(upId),
      downId ? fetchMidpoint(downId) : Promise.resolve(null),
    ]);
    const upP   = up;
    const downP = down ?? (up != null ? parseFloat((1 - up).toFixed(6)) : null);
    const { outcome, confident } = detectOutcome(upP, downP);
    if (confident) return outcome;
  }
  return null; // could not determine
}
'@
Set-Content "src/lib/polymarket.js" -Value $lib

# ── src/components/LiveTracker.js ─────────────────────────────────────────────
$tracker = @'
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
'@
Set-Content "src/components/LiveTracker.js" -Value $tracker

# ── src/app/page.js — add manual outcome override on saved sessions ───────────
$page = @'
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

  const showToast = (msg) => { setToastMsg(msg); setTimeout(() => setToastMsg(null), 3000); };

  const onSaveSession = useCallback((session) => {
    setSessions(prev => {
      const next = [...prev.filter(s => s.slug !== session.slug), session];
      saveSessions(next);
      return next;
    });
    showToast(`Saved: ${session.slug} - Outcome: ${session.outcome ?? "unknown"}`);
  }, []);

  // Manual outcome override for any saved session
  const overrideOutcome = useCallback((slug, outcome) => {
    setSessions(prev => {
      const next = prev.map(s => s.slug === slug ? { ...s, outcome } : s);
      saveSessions(next);
      return next;
    });
    showToast(`Updated ${slug.replace("btc-updown-5m-","")} -> ${outcome}`);
  }, []);

  const downloadSessions = () => {
    if (!sessions.length) return;
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
      {toastMsg && (
        <div className="fixed top-4 right-4 z-50 bg-indigo-600 text-white text-sm font-medium px-4 py-3 rounded-xl shadow-lg max-w-sm">
          {toastMsg}
        </div>
      )}

      <nav className="border-b border-[var(--border)] bg-[var(--nav)] backdrop-blur sticky top-0 z-10">
        <div className="max-w-5xl mx-auto px-4 py-3 flex items-center gap-4">
          <span className="font-bold text-lg">PM BTC 5m</span>
          <span className="text-[var(--text2)] text-sm hidden sm:block">Polymarket Tracker & Backtest</span>
          <div className="ml-auto flex gap-3 items-center">
            <Link href="/"         className="text-sm font-semibold text-indigo-600 dark:text-indigo-400">Live</Link>
            <Link href="/backtest" className="text-sm text-[var(--text2)] hover:text-[var(--text1)]">Backtest</Link>
            <ThemeToggle />
          </div>
        </div>
      </nav>

      <main className="max-w-5xl mx-auto px-4 py-6 space-y-6">
        <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-5 shadow-sm">
          <h1 className="text-lg font-bold mb-4">Live Tracker</h1>
          <LiveTracker onSaveSession={onSaveSession} />
        </div>

        <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-5 shadow-sm">
          <div className="flex items-center gap-3 mb-4">
            <h2 className="text-lg font-bold">Saved Sessions ({sessions.length})</h2>
            <div className="ml-auto flex gap-2">
              <button onClick={downloadSessions} disabled={!sessions.length}
                className="px-4 py-1.5 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 text-white rounded-lg text-sm font-semibold">
                Download JSON
              </button>
              <button onClick={clearSessions} disabled={!sessions.length}
                className="px-4 py-1.5 bg-red-100 hover:bg-red-200 dark:bg-red-900/50 dark:hover:bg-red-900 disabled:opacity-40 text-red-700 dark:text-red-400 rounded-lg text-sm font-semibold">
                Clear
              </button>
            </div>
          </div>

          {!sessions.length ? (
            <p className="text-[var(--text3)] text-sm">No sessions yet. Markets auto-save on resolution.</p>
          ) : (
            <div className="space-y-2 max-h-96 overflow-y-auto">
              {[...sessions].reverse().map((s, i) => (
                <div key={i} className="flex items-center gap-3 bg-[var(--bg2)] rounded-lg px-3 py-2">
                  <span className="font-mono text-xs text-[var(--text3)] truncate flex-1">{s.slug}</span>
                  <span className="text-xs text-[var(--text3)] shrink-0">{s.priceHistory?.length ?? 0} pts</span>

                  {/* Manual outcome override buttons */}
                  <div className="flex gap-1 shrink-0">
                    <button
                      onClick={() => overrideOutcome(s.slug, "UP")}
                      className={`px-2 py-0.5 rounded text-xs font-bold border transition ${
                        s.outcome === "UP"
                          ? "bg-green-500 text-white border-green-500"
                          : "bg-transparent border-green-400 text-green-600 dark:text-green-400 hover:bg-green-50 dark:hover:bg-green-900/30"
                      }`}
                    >UP</button>
                    <button
                      onClick={() => overrideOutcome(s.slug, "DOWN")}
                      className={`px-2 py-0.5 rounded text-xs font-bold border transition ${
                        s.outcome === "DOWN"
                          ? "bg-red-500 text-white border-red-500"
                          : "bg-transparent border-red-400 text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/30"
                      }`}
                    >DOWN</button>
                  </div>
                </div>
              ))}
            </div>
          )}
          {sessions.length > 0 && (
            <p className="text-xs text-[var(--text3)] mt-3">
              Click UP / DOWN on any row to correct its outcome before running a backtest.
            </p>
          )}
        </div>
      </main>
    </div>
  );
}
'@
Set-Content "src/app/page.js" -Value $page

# ── tracker.py — poll for settlement after resolution ────────────────────────
$trackerPy = @'
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
        token_ids = json.loads(raw) if isinstance(raw, str) else raw
        outcomes = market.get("outcomes", [])
        if isinstance(outcomes, str):
            outcomes = json.loads(outcomes)
        up_id, down_id = None, None
        for i, o in enumerate(outcomes):
            if o.lower() in ("up","yes") and i < len(token_ids):
                up_id = str(token_ids[i])
            elif o.lower() in ("down","no") and i < len(token_ids):
                down_id = str(token_ids[i])
        if not up_id   and len(token_ids) > 0: up_id   = str(token_ids[0])
        if not down_id and len(token_ids) > 1: down_id = str(token_ids[1])
        return {"slug": market.get("slug", slug), "question": market.get("question",""), "up_id": up_id, "down_id": down_id}
    except Exception as e:
        print(f"\n  [ERROR] fetch_market: {e}")
        return None

def fetch_price(token_id):
    if not token_id: return None
    try:
        r = session.get(f"{CLOB}/midpoints", params={"token_id": token_id}, timeout=4)
        if r.ok:
            d = r.json()
            p = valid_price(d.get("mid") or d.get(token_id) or d.get("midpoint"))
            if p: return p
    except Exception: pass
    try:
        r = session.get(f"{CLOB}/price", params={"token_id": token_id, "side": "buy"}, timeout=4)
        if r.ok:
            p = valid_price(r.json().get("price"))
            if p: return p
    except Exception: pass
    try:
        r = session.get(f"{CLOB}/book", params={"token_id": token_id}, timeout=4)
        if r.ok:
            d = r.json()
            bid = valid_price(d["bids"][0]["price"]) if d.get("bids") else None
            ask = valid_price(d["asks"][0]["price"]) if d.get("asks") else None
            if bid and ask: return round((bid+ask)/2, 6)
            return bid or ask
    except Exception: pass
    return None

def poll_for_outcome(up_id, down_id, max_attempts=20, interval=3):
    """After resolution, poll until one side settles >= 0.90. Returns 'UP', 'DOWN', or None."""
    print(f"\n  Polling for settlement outcome (up to {max_attempts*interval}s)...", end="", flush=True)
    for i in range(max_attempts):
        if i > 0: time.sleep(interval)
        up_price   = fetch_price(up_id)
        down_price = fetch_price(down_id)
        if up_price is None and down_price is not None:
            up_price = round(1 - down_price, 6)
        if down_price is None and up_price is not None:
            down_price = round(1 - up_price, 6)
        if up_price and up_price >= 0.90:
            print(f" -> UP ({up_price:.4f}) after {(i+1)*interval}s")
            return "UP"
        if down_price and down_price >= 0.90:
            print(f" -> DOWN ({down_price:.4f}) after {(i+1)*interval}s")
            return "DOWN"
        print(".", end="", flush=True)
    print(" timed out")
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
        except Exception: pass
    with open(filename, "w") as f:
        json.dump(session_data, f, indent=2)
    return filename

def track_market(slug, resolution_ts):
    print(f"\n{'='*60}")
    print(f"  Market : {slug}")
    print(f"  Resolves: epoch {resolution_ts}")
    print(f"{'='*60}")
    market = fetch_market(slug)
    if not market:
        print("  [SKIP] Market not found.")
        return None
    up_id   = market["up_id"]
    down_id = market["down_id"]
    print(f"  UP   token: {up_id}")
    print(f"  DOWN token: {down_id}\n")
    if not up_id:
        print("  [ERROR] No UP token ID found.")
        return None

    session_data = {
        "slug": slug, "resolutionTs": resolution_ts,
        "question": market["question"], "outcome": None, "priceHistory": [],
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
        bar = chr(9608) * int((elapsed/300)*20)
        print(f"\r  [{bar:<20}] {elapsed:>3}s  UP={up_str}  DOWN={down_str}  pts={len(session_data['priceHistory'])}  rem={remaining}s   ", end="", flush=True)

        if time.time() - last_save >= 30:
            save_session(session_data)
            last_save = time.time()

        if remaining <= 0:
            print()
            # Poll for real settlement — do NOT guess from pre-resolution prices
            outcome = poll_for_outcome(up_id, down_id)
            if not outcome:
                print("  Could not auto-detect. Market may use different resolution mechanism.")
                ans = input("  Manual: u=UP / d=DOWN / Enter to skip: ").strip().lower()
                if ans in ("u","up"):     outcome = "UP"
                elif ans in ("d","down"): outcome = "DOWN"
            if outcome:
                session_data["outcome"] = outcome
                print(f"  Final outcome: {outcome}")
            break
        time.sleep(POLL)

    filename = save_session(session_data)
    pts_with_price = sum(1 for p in session_data["priceHistory"] if p["up"] is not None)
    print(f"  Saved: {filename}")
    print(f"  Total: {len(session_data['priceHistory'])} pts | With price: {pts_with_price}")
    return session_data

def debug_market(slug):
    print(f"\nDEBUG: {GAMMA}/markets?slug={slug}")
    r = session.get(f"{GAMMA}/markets", params={"slug": slug}, timeout=8)
    print(f"Status: {r.status_code}")
    print(json.dumps(r.json(), indent=2)[:3000])

def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--debug-slug")
    parser.add_argument("--slug")
    args = parser.parse_args()
    if args.debug_slug:
        debug_market(args.debug_slug); return
    if args.slug:
        ts_str = args.slug.replace("btc-updown-5m-","")
        try: ts = int(ts_str)
        except: print("Cannot parse timestamp"); return
        track_market(args.slug, ts); return

    print("Polymarket BTC 5m Tracker -- Ctrl+C to stop")
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
        print("\nWaiting 3s...\n")
        time.sleep(3)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nTracker stopped.")
'@
Set-Content "tracker.py" -Value $trackerPy

Write-Host ""
Write-Host "fix4 applied!" -ForegroundColor Green
Write-Host ""
Write-Host "Root cause fixed:" -ForegroundColor Yellow
Write-Host "  The CLOB API does NOT instantly jump to 99c at resolution."
Write-Host "  Prices at the final tick are still ~50c, so detectOutcome"
Write-Host "  was guessing and consistently picking wrong."
Write-Host ""
Write-Host "Solution:" -ForegroundColor Cyan
Write-Host "  After resolution, poll every 3s for up to 60s waiting for"
Write-Host "  one side to hit 90c+ (the real settled price)."
Write-Host "  UI shows 'Waiting for settlement...' during this window."
Write-Host "  If poll times out, shows low-confidence warning."
Write-Host "  Manual UP/DOWN override buttons on every saved session row."
Write-Host ""
Write-Host "Restart: npm run dev" -ForegroundColor Cyan