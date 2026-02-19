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
