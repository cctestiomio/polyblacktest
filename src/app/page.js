"use client";
import { useState, useCallback, useRef } from "react";
import Link from "next/link";
import LiveTracker from "../components/LiveTracker";

const STORAGE_KEY = "pm_sessions";

function loadSessions() {
  if (typeof window === "undefined") return [];
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "[]"); } catch { return []; }
}

function saveSessions(sessions) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(sessions));
}

export default function Home() {
  const [sessions, setSessions] = useState(() => loadSessions());

  const onSaveSession = useCallback((session) => {
    setSessions(prev => {
      const next = [...prev.filter(s => s.slug !== session.slug), session];
      saveSessions(next);
      return next;
    });
    alert(`✅ Session saved: ${session.slug}\n${session.priceHistory.length} data points`);
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
    <div className="min-h-screen bg-slate-950 text-slate-100">
      {/* Nav */}
      <nav className="border-b border-slate-800 bg-slate-900/80 backdrop-blur sticky top-0 z-10">
        <div className="max-w-5xl mx-auto px-4 py-3 flex items-center gap-4">
          <span className="font-bold text-lg">⚡ PM BTC 5m</span>
          <span className="text-slate-500 text-sm hidden sm:block">Polymarket Tracker & Backtest</span>
          <div className="ml-auto flex gap-3">
            <Link href="/" className="text-sm font-semibold text-indigo-400">Live</Link>
            <Link href="/backtest" className="text-sm text-slate-400 hover:text-slate-200">Backtest</Link>
          </div>
        </div>
      </nav>

      <main className="max-w-5xl mx-auto px-4 py-6 space-y-6">
        {/* Live tracker */}
        <div className="bg-slate-900/60 border border-slate-800 rounded-2xl p-5">
          <h1 className="text-lg font-bold text-slate-100 mb-4">🔴 Live Tracker</h1>
          <LiveTracker onSaveSession={onSaveSession} />
        </div>

        {/* Saved sessions */}
        <div className="bg-slate-900/60 border border-slate-800 rounded-2xl p-5">
          <div className="flex items-center gap-3 mb-4">
            <h2 className="text-lg font-bold text-slate-100">Saved Sessions ({sessions.length})</h2>
            <div className="ml-auto flex gap-2">
              <button onClick={downloadSessions} disabled={sessions.length === 0}
                className="px-4 py-1.5 bg-indigo-700 hover:bg-indigo-600 disabled:opacity-40 rounded-lg text-sm font-semibold">
                ⬇ Download JSON
              </button>
              <button onClick={clearSessions} disabled={sessions.length === 0}
                className="px-4 py-1.5 bg-red-900 hover:bg-red-800 disabled:opacity-40 rounded-lg text-sm font-semibold">
                Clear
              </button>
            </div>
          </div>
          {sessions.length === 0 ? (
            <p className="text-slate-500 text-sm">No sessions saved yet. Track a market and click "Save Session".</p>
          ) : (
            <div className="space-y-2 max-h-64 overflow-y-auto">
              {[...sessions].reverse().map((s, i) => (
                <div key={i} className="flex items-center gap-3 bg-slate-800/60 rounded-lg px-3 py-2 text-sm">
                  <span className="font-mono text-slate-400 truncate flex-1">{s.slug}</span>
                  <span className="text-slate-500">{s.priceHistory?.length ?? 0} pts</span>
                  {s.outcome ? (
                    <span className={`font-bold ${s.outcome==="UP"?"text-green-400":"text-red-400"}`}>{s.outcome}</span>
                  ) : (
                    <span className="text-slate-600">No outcome</span>
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
