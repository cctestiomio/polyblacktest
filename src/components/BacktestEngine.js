"use client";
import { useState, useRef } from "react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid, ResponsiveContainer,
  LineChart, Line, Legend, Cell,
} from "recharts";

export default function BacktestEngine({ sessions }) {
  const [side, setSide] = useState("UP"); // UP | DOWN | BOTH
  const [priceMin, setPriceMin] = useState(0.1);
  const [priceMax, setPriceMax] = useState(0.9);
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);
  const [groupBy, setGroupBy] = useState("priceRange"); // priceRange | elapsedRange
  const [results, setResults] = useState(null);

  const runBacktest = () => {
    const trades = [];

    for (const session of sessions) {
      if (!session.outcome) continue; // skip sessions without outcome marked
      const history = session.priceHistory ?? [];

      for (const point of history) {
        const el = point.elapsed ?? 0;
        if (el < elapsedMin || el > elapsedMax) continue;

        const price = side === "DOWN" ? point.down : point.up;
        if (price == null) continue;
        if (price < priceMin || price > priceMax) continue;

        // "Buy" this side at this moment
        const win = session.outcome === (side === "DOWN" ? "DOWN" : "UP");
        trades.push({
          slug: session.slug,
          elapsed: el,
          price,
          side,
          outcome: session.outcome,
          win,
        });
      }
    }

    if (trades.length === 0) {
      setResults({ trades: [], summary: null, chart: [] });
      return;
    }

    const wins = trades.filter(t => t.win).length;
    const winRate = wins / trades.length;

    // Build chart data by group
    let chartData = [];
    if (groupBy === "priceRange") {
      const buckets = {};
      for (const t of trades) {
        const bucket = `${Math.floor(t.price * 10) * 10}¢`;
        if (!buckets[bucket]) buckets[bucket] = { wins: 0, total: 0 };
        buckets[bucket].total++;
        if (t.win) buckets[bucket].wins++;
      }
      chartData = Object.entries(buckets)
        .sort((a, b) => parseFloat(a[0]) - parseFloat(b[0]))
        .map(([price, { wins, total }]) => ({
          label: price,
          winRate: +((wins / total) * 100).toFixed(1),
          total,
          wins,
        }));
    } else {
      // Group by 30s elapsed buckets
      const buckets = {};
      for (const t of trades) {
        const bucket = `${Math.floor(t.elapsed / 30) * 30}s`;
        if (!buckets[bucket]) buckets[bucket] = { wins: 0, total: 0 };
        buckets[bucket].total++;
        if (t.win) buckets[bucket].wins++;
      }
      chartData = Object.entries(buckets)
        .sort((a, b) => parseInt(a[0]) - parseInt(b[0]))
        .map(([label, { wins, total }]) => ({
          label,
          winRate: +((wins / total) * 100).toFixed(1),
          total,
          wins,
        }));
    }

    setResults({ trades, summary: { total: trades.length, wins, winRate }, chart: chartData });
  };

  return (
    <div className="space-y-6">
      {/* Config */}
      <div className="bg-slate-900 rounded-xl p-5 space-y-4">
        <h2 className="text-lg font-bold text-slate-100">Backtest Configuration</h2>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className="text-xs text-slate-400 block mb-1">Buy Side</label>
            <div className="flex gap-2">
              {["UP","DOWN","BOTH"].map(s => (
                <button
                  key={s}
                  onClick={() => setSide(s)}
                  className={`flex-1 py-2 rounded font-bold text-sm ${side===s ? "bg-indigo-600 text-white" : "bg-slate-800 hover:bg-slate-700 text-slate-300"}`}
                >{s}</button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs text-slate-400 block mb-1">Group Results By</label>
            <div className="flex gap-2">
              {[["priceRange","Price Range"],["elapsedRange","Time Elapsed"]].map(([v,l]) => (
                <button
                  key={v}
                  onClick={() => setGroupBy(v)}
                  className={`flex-1 py-2 rounded text-sm ${groupBy===v ? "bg-indigo-600 text-white" : "bg-slate-800 hover:bg-slate-700 text-slate-300"}`}
                >{l}</button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs text-slate-400 block mb-1">Entry Price Range (0–1)</label>
            <div className="flex gap-2 items-center">
              <input type="number" min="0" max="1" step="0.01" value={priceMin}
                onChange={e => setPriceMin(+e.target.value)}
                className="w-24 bg-slate-800 border border-slate-600 rounded px-2 py-1.5 text-sm text-slate-200" />
              <span className="text-slate-500">to</span>
              <input type="number" min="0" max="1" step="0.01" value={priceMax}
                onChange={e => setPriceMax(+e.target.value)}
                className="w-24 bg-slate-800 border border-slate-600 rounded px-2 py-1.5 text-sm text-slate-200" />
            </div>
            <p className="text-xs text-slate-500 mt-1">e.g. 0.55 to 0.65 = buy near 60¢</p>
          </div>

          <div>
            <label className="text-xs text-slate-400 block mb-1">Time Elapsed Range (seconds)</label>
            <div className="flex gap-2 items-center">
              <input type="number" min="0" max="300" step="1" value={elapsedMin}
                onChange={e => setElapsedMin(+e.target.value)}
                className="w-24 bg-slate-800 border border-slate-600 rounded px-2 py-1.5 text-sm text-slate-200" />
              <span className="text-slate-500">to</span>
              <input type="number" min="0" max="300" step="1" value={elapsedMax}
                onChange={e => setElapsedMax(+e.target.value)}
                className="w-24 bg-slate-800 border border-slate-600 rounded px-2 py-1.5 text-sm text-slate-200" />
            </div>
            <p className="text-xs text-slate-500 mt-1">300s = end of market. 0s = market open</p>
          </div>
        </div>

        <button
          onClick={runBacktest}
          disabled={sessions.length === 0}
          className="w-full py-3 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 rounded-xl font-bold text-base"
        >
          ▶ Run Backtest ({sessions.length} session{sessions.length !== 1 ? "s" : ""} loaded)
        </button>
      </div>

      {/* Results */}
      {results && (
        <div className="space-y-4">
          {results.summary ? (
            <>
              <div className="grid grid-cols-3 gap-3">
                <SummaryCard label="Total Trades" value={results.summary.total} color="text-blue-400" />
                <SummaryCard label="Wins" value={results.summary.wins} color="text-green-400" />
                <SummaryCard
                  label="Win Rate"
                  value={`${(results.summary.winRate * 100).toFixed(1)}%`}
                  color={results.summary.winRate >= 0.5 ? "text-green-400" : "text-red-400"}
                />
              </div>

              {results.chart.length > 0 && (
                <div className="bg-slate-900 rounded-xl p-4" style={{ height: 300 }}>
                  <p className="text-xs text-slate-400 mb-3">Win Rate by {groupBy === "priceRange" ? "Entry Price" : "Elapsed Time"}</p>
                  <ResponsiveContainer width="100%" height="100%">
                    <BarChart data={results.chart}>
                      <CartesianGrid strokeDasharray="3 3" stroke="#1e293b" />
                      <XAxis dataKey="label" stroke="#475569" tick={{ fontSize: 11 }} />
                      <YAxis domain={[0, 100]} tickFormatter={v => `${v}%`} stroke="#475569" tick={{ fontSize: 11 }} />
                      <Tooltip
                        formatter={(v, name) => [name === "winRate" ? `${v}%` : v, name === "winRate" ? "Win Rate" : "Trades"]}
                        contentStyle={{ background: "#1e293b", border: "none", borderRadius: 8 }}
                      />
                      <Bar dataKey="winRate" radius={[4,4,0,0]}>
                        {results.chart.map((entry, i) => (
                          <Cell key={i} fill={entry.winRate >= 50 ? "#4ade80" : "#f87171"} />
                        ))}
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              )}

              {/* Trade log */}
              <div className="bg-slate-900 rounded-xl p-4">
                <p className="text-xs text-slate-400 mb-3">Trade Log (last 50)</p>
                <div className="overflow-x-auto">
                  <table className="w-full text-xs text-slate-300">
                    <thead>
                      <tr className="text-slate-500 border-b border-slate-800">
                        <th className="text-left py-1 pr-4">Slug</th>
                        <th className="text-right pr-4">Elapsed</th>
                        <th className="text-right pr-4">Price</th>
                        <th className="text-right pr-4">Outcome</th>
                        <th className="text-right">Result</th>
                      </tr>
                    </thead>
                    <tbody>
                      {results.trades.slice(-50).reverse().map((t, i) => (
                        <tr key={i} className="border-b border-slate-800/50 hover:bg-slate-800/30">
                          <td className="py-1 pr-4 truncate max-w-xs font-mono text-slate-500">{t.slug}</td>
                          <td className="text-right pr-4">{t.elapsed}s</td>
                          <td className="text-right pr-4">{(t.price*100).toFixed(1)}¢</td>
                          <td className={`text-right pr-4 font-bold ${t.outcome==="UP"?"text-green-400":"text-red-400"}`}>{t.outcome}</td>
                          <td className={`text-right font-bold ${t.win?"text-green-400":"text-red-400"}`}>{t.win?"✓ WIN":"✗ LOSS"}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            </>
          ) : (
            <div className="bg-slate-900 rounded-xl p-6 text-center text-slate-400">
              No matching trades found. Try widening your price/time range, or make sure sessions have outcomes marked.
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function SummaryCard({ label, value, color }) {
  return (
    <div className="bg-slate-900 rounded-xl p-4 text-center">
      <p className="text-xs text-slate-500 mb-1">{label}</p>
      <p className={`text-2xl font-bold font-mono ${color}`}>{value}</p>
    </div>
  );
}
