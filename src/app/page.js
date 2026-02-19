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
