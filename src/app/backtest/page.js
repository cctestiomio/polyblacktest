"use client";
import { useState, useCallback } from "react";
import Link from "next/link";
import BacktestEngine from "../../components/BacktestEngine";

export default function BacktestPage() {
  const [sessions, setSessions] = useState([]);
  const [dragOver, setDragOver] = useState(false);

  const processFiles = useCallback(async (files) => {
    const loaded = [];
    for (const file of Array.from(files)) {
      try {
        const text = await file.text();
        const data = JSON.parse(text);
        // data can be array of sessions or a single session
        const arr = Array.isArray(data) ? data : [data];
        loaded.push(...arr);
      } catch (e) {
        alert(`Failed to parse ${file.name}: ${e.message}`);
      }
    }
    setSessions(prev => {
      const all = [...prev, ...loaded];
      // dedupe by slug+elapsed (keep last)
      const map = new Map(all.map(s => [s.slug, s]));
      return [...map.values()];
    });
  }, []);

  const onFileInput = (e) => processFiles(e.target.files);

  const onDrop = (e) => {
    e.preventDefault();
    setDragOver(false);
    processFiles(e.dataTransfer.files);
  };

  // Also load from localStorage
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
    <div className="min-h-screen bg-slate-950 text-slate-100">
      <nav className="border-b border-slate-800 bg-slate-900/80 backdrop-blur sticky top-0 z-10">
        <div className="max-w-5xl mx-auto px-4 py-3 flex items-center gap-4">
          <span className="font-bold text-lg">⚡ PM BTC 5m</span>
          <div className="ml-auto flex gap-3">
            <Link href="/" className="text-sm text-slate-400 hover:text-slate-200">Live</Link>
            <Link href="/backtest" className="text-sm font-semibold text-indigo-400">Backtest</Link>
          </div>
        </div>
      </nav>

      <main className="max-w-5xl mx-auto px-4 py-6 space-y-6">
        {/* Upload */}
        <div className="bg-slate-900/60 border border-slate-800 rounded-2xl p-5">
          <h1 className="text-lg font-bold mb-4">📂 Load Session Data</h1>
          <div
            onDragOver={e => { e.preventDefault(); setDragOver(true); }}
            onDragLeave={() => setDragOver(false)}
            onDrop={onDrop}
            className={`border-2 border-dashed rounded-xl p-8 text-center transition ${dragOver ? "border-indigo-400 bg-indigo-900/20" : "border-slate-700 hover:border-slate-500"}`}
          >
            <p className="text-slate-400 mb-3">Drop JSON session files here, or</p>
            <label className="cursor-pointer px-5 py-2 bg-indigo-700 hover:bg-indigo-600 rounded-lg text-sm font-semibold">
              Browse Files
              <input type="file" accept=".json" multiple className="hidden" onChange={onFileInput} />
            </label>
            <p className="text-xs text-slate-600 mt-3">One file can contain multiple sessions (exported as array)</p>
          </div>

          <div className="mt-3 flex gap-3 items-center">
            <button onClick={loadFromBrowser} className="px-4 py-2 bg-slate-800 hover:bg-slate-700 rounded-lg text-sm">
              📥 Load from This Browser
            </button>
            {sessions.length > 0 && (
              <>
                <span className="text-slate-400 text-sm">{sessions.length} sessions loaded</span>
                <button onClick={() => setSessions([])} className="ml-auto text-xs text-red-400 hover:text-red-300">Clear All</button>
              </>
            )}
          </div>

          {sessions.length > 0 && (
            <div className="mt-3 grid grid-cols-1 sm:grid-cols-3 gap-2 max-h-40 overflow-y-auto">
              {sessions.map((s, i) => (
                <div key={i} className="bg-slate-800/60 rounded-lg px-3 py-1.5 flex items-center gap-2 text-xs">
                  <span className="truncate flex-1 font-mono text-slate-400">{s.slug?.replace("btc-up-or-down-in-5-minutes-","") ?? "?"}</span>
                  <span className="text-slate-500">{s.priceHistory?.length ?? 0}pts</span>
                  {s.outcome && <span className={`font-bold ${s.outcome==="UP"?"text-green-400":"text-red-400"}`}>{s.outcome[0]}</span>}
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Backtest engine */}
        <BacktestEngine sessions={sessions} />
      </main>
    </div>
  );
}
