"use client";
import { useState } from "react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid,
  ResponsiveContainer, Cell, LineChart, Line,
} from "recharts";

const PRICE_CENTS = Array.from({ length: 99 }, (_, i) => i + 1);  // 1..99
const TIME_SECS   = Array.from({ length: 301 }, (_, i) => i);     // 0..300

function clamp(n, lo, hi) {
  const x = Number(n);
  if (!Number.isFinite(x)) return lo;
  return Math.min(hi, Math.max(lo, x));
}

function colorForWinRate01(wr) {
  // wr: 0..1
  // Neutral around 0.5, more saturated as you move away.
  const t = Math.min(1, Math.abs(wr - 0.5) * 2); // 0..1
  const hue = wr >= 0.5 ? 140 : 0;               // green vs red
  const sat = 70;
  const light = 92 - (t * 45);                   // 92..47
  return `hsl(${hue}, ${sat}%, ${light}%)`;
}

export default function BacktestEngine({ sessions }) {
  const [side, setSide] = useState("UP"); // UP, DOWN, BOTH
  const [priceMin, setPriceMin] = useState(0.10);
  const [priceMax, setPriceMax] = useState(0.90);
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);
  const [groupBy, setGroupBy] = useState("priceRange"); // priceRange | elapsedRange | priceTime
  const [results, setResults] = useState(null);

  const runBacktest = () => {
    const pMin = clamp(Math.min(priceMin, priceMax), 0, 1);
    const pMax = clamp(Math.max(priceMin, priceMax), 0, 1);
    const eMin = clamp(Math.min(elapsedMin, elapsedMax), 0, 300);
    const eMax = clamp(Math.max(elapsedMin, elapsedMax), 0, 300);

    const sides = side === "BOTH" ? ["UP", "DOWN"] : [side];
    const trades = [];

    for (const session of sessions) {
      if (!session?.outcome) continue;

      for (const point of session.priceHistory ?? []) {
        const el = point?.elapsed ?? 0;
        if (el < eMin || el > eMax) continue;

        for (const s of sides) {
          const price = s === "DOWN" ? point?.down : point?.up;
          if (price == null) continue;
          if (price < pMin || price > pMax) continue;

          const win = session.outcome === s;
          trades.push({
            slug: session.slug,
            elapsed: el,
            price,
            side: s,
            outcome: session.outcome,
            win,
          });
        }
      }
    }

    if (!trades.length) {
      setResults({ trades: [], summary: null, chartPrice: [], chartTime: [], heat: new Map() });
      return;
    }

    const wins = trades.reduce((acc, t) => acc + (t.win ? 1 : 0), 0);
    const winRate = wins / trades.length;

    // --- Build 1Â¢ price chart (1..99) ---
    const byCent = new Array(100).fill(null).map(() => ({ wins: 0, total: 0 }));
    // --- Build 1s time chart (0..300) ---
    const bySec = new Array(301).fill(null).map(() => ({ wins: 0, total: 0 }));
    // --- Build heatmap (sec x cent) ---
    const heat = new Map(); // key = sec*100 + cent

    for (const t of trades) {
      const cent = clamp(Math.round(t.price * 100), 0, 100);
      const sec = clamp(Math.round(t.elapsed), 0, 300);

      if (cent >= 1 && cent <= 99) {
        byCent[cent].total++;
        if (t.win) byCent[cent].wins++;
      }

      bySec[sec].total++;
      if (t.win) bySec[sec].wins++;

      if (cent >= 1 && cent <= 99) {
        const key = (sec * 100) + cent;
        const cur = heat.get(key) ?? { wins: 0, total: 0 };
        cur.total++;
        if (t.win) cur.wins++;
        heat.set(key, cur);
      }
    }

    const chartPrice = PRICE_CENTS.map((c) => {
      const { wins, total } = byCent[c];
      return {
        cent: c,
        label: `${c}Â¢`,
        winRate: total ? +((wins / total) * 100).toFixed(1) : null,
        wins,
        total,
      };
    });

    const chartTime = TIME_SECS.map((s) => {
      const { wins, total } = bySec[s];
      return {
        sec: s,
        label: `${s}s`,
        winRate: total ? +((wins / total) * 100).toFixed(1) : null,
        wins,
        total,
      };
    });

    setResults({
      trades,
      summary: { total: trades.length, wins, winRate },
      chartPrice,
      chartTime,
      heat,
      params: { pMin, pMax, eMin, eMax, side },
    });
  };

  return (
    <div className="space-y-6">
      <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-5 shadow-sm space-y-4">
        <h2 className="text-lg font-bold">Backtest Configuration</h2>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Buy Side</label>
            <div className="flex gap-2">
              {["UP", "DOWN", "BOTH"].map(s => (
                <button
                  key={s}
                  onClick={() => setSide(s)}
                  className={`flex-1 py-2 rounded-lg font-bold text-sm transition ${
                    side === s
                      ? "bg-indigo-600 text-white"
                      : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
                  }`}
                >
                  {s}
                </button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Chart View</label>
            <div className="flex gap-2">
              {[
                ["priceRange", "Entry Price (1Â¢)"],
                ["elapsedRange", "Elapsed Time (1s)"],
                ["priceTime", "Price Ã— Time (Heatmap)"],
              ].map(([v, l]) => (
                <button
                  key={v}
                  onClick={() => setGroupBy(v)}
                  className={`flex-1 py-2 rounded-lg text-sm transition ${
                    groupBy === v
                      ? "bg-indigo-600 text-white"
                      : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
                  }`}
                >
                  {l}
                </button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Entry Price Range (0â€“1)</label>
            <div className="flex gap-2 items-center">
              <input type="number" min="0" max="1" step="0.01" value={priceMin}
                onChange={e => setPriceMin(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]" />
              <span className="text-[var(--text3)]">to</span>
              <input type="number" min="0" max="1" step="0.01" value={priceMax}
                onChange={e => setPriceMax(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]" />
            </div>
            <p className="text-xs text-[var(--text3)] mt-1">Tip: set 0.01â€“0.99 to show full domain</p>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Time Elapsed Range (seconds 0â€“300)</label>
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
          â–¶ Run Backtest ({sessions.length} session{sessions.length !== 1 ? "s" : ""} loaded)
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
                  value={`${(results.summary.winRate * 100).toFixed(1)}%`}
                  color={results.summary.winRate >= 0.5 ? "text-green-600 dark:text-green-400" : "text-red-600 dark:text-red-400"}
                />
              </div>

              {/* Charts */}
              {groupBy === "priceRange" && (
                <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm" style={{ height: 340 }}>
                  <p className="text-xs text-[var(--text2)] mb-3">Win Rate by Entry Price (1Â¢ increments)</p>
                  <ResponsiveContainer width="100%" height="90%">
                    <BarChart data={results.chartPrice}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                      <XAxis
                        dataKey="cent"
                        stroke="#94a3b8"
                        tick={{ fontSize: 10 }}
                        tickFormatter={(v) => `${v}Â¢`}
                        interval={0}
                        angle={-60}
                        textAnchor="end"
                        height={80}
                      />
                      <YAxis domain={[0, 100]} tickFormatter={v => `${v}%`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                      <Tooltip
                        formatter={(v, n, ctx) => {
                          const p = ctx?.payload;
                          if (!p) return [v, n];
                          if (n === "winRate") return [p.total ? `${p.winRate}%` : "â€”", "Win Rate"];
                          return [v, n];
                        }}
                        labelFormatter={(cent) => `${cent}Â¢`}
                        contentStyle={{ background: "var(--card)", border: "1px solid var(--border)", borderRadius: 8 }}
                      />
                      <Bar dataKey="winRate" radius={[3, 3, 0, 0]}>
                        {results.chartPrice.map((e, i) => (
                          <Cell key={i} fill={e.winRate == null ? "rgba(148,163,184,0.25)" : (e.winRate >= 50 ? "#16a34a" : "#dc2626")} />
                        ))}
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              )}

              {groupBy === "elapsedRange" && (
                <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm" style={{ height: 340 }}>
                  <p className="text-xs text-[var(--text2)] mb-3">Win Rate by Elapsed Time (1s increments)</p>
                  <ResponsiveContainer width="100%" height="90%">
                    <LineChart data={results.chartTime}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                      <XAxis
                        dataKey="sec"
                        stroke="#94a3b8"
                        tick={{ fontSize: 11 }}
                        tickFormatter={(v) => `${v}s`}
                        interval={29} /* keep chart readable; data is still 1s resolution */
                      />
                      <YAxis domain={[0, 100]} tickFormatter={v => `${v}%`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                      <Tooltip
                        formatter={(v, n, ctx) => {
                          const p = ctx?.payload;
                          if (!p) return [v, n];
                          return [p.total ? `${p.winRate}% (n=${p.total})` : "â€”", "Win Rate"];
                        }}
                        labelFormatter={(sec) => `${sec}s`}
                        contentStyle={{ background: "var(--card)", border: "1px solid var(--border)", borderRadius: 8 }}
                      />
                      <Line type="monotone" dataKey="winRate" stroke="#6366f1" dot={false} connectNulls={false} strokeWidth={2} />
                    </LineChart>
                  </ResponsiveContainer>
                </div>
              )}

              {groupBy === "priceTime" && (
                <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm">
                  <p className="text-xs text-[var(--text2)] mb-3">Win Rate Heatmap (Price Ã— Time)</p>

                  <div className="text-xs text-[var(--text3)] mb-3">
                    X-axis: elapsed seconds (0â€“300). Y-axis: entry price cents (1â€“99). Hover cells for details.
                  </div>

                  <div className="w-full border border-[var(--border)] rounded-lg overflow-hidden" style={{ height: 420 }}>
                    <svg
                      viewBox="0 0 301 99"
                      preserveAspectRatio="none"
                      width="100%"
                      height="100%"
                    >
                      {/* background */}
                      <rect x="0" y="0" width="301" height="99" fill="rgba(148,163,184,0.08)" />

                      {Array.from(results.heat.entries()).map(([key, v]) => {
                        const sec = Math.floor(key / 100);
                        const cent = key % 100;
                        if (cent < 1 || cent > 99) return null;

                        const wr01 = v.total ? (v.wins / v.total) : 0.5;
                        const fill = colorForWinRate01(wr01);

                        // y=0 at top, we want 99Â¢ near top, 1Â¢ near bottom
                        const y = (99 - cent);

                        return (
                          <g key={key}>
                            <rect x={sec} y={y} width="1" height="1" fill={fill} opacity="0.95">
                              <title>{`t=${sec}s, price=${cent}Â¢, winRate=${(wr01*100).toFixed(1)}% (wins=${v.wins}, n=${v.total})`}</title>
                            </rect>
                          </g>
                        );
                      })}
                    </svg>
                  </div>

                  <div className="mt-3 text-xs text-[var(--text3)] flex items-center gap-3">
                    <span>0%</span>
                    <div className="flex-1 h-2 rounded"
                      style={{ background: "linear-gradient(90deg, #dc2626, #eab308, #16a34a)" }}
                    />
                    <span>100%</span>
                  </div>
                </div>
              )}

              {/* Trade log */}
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
                      {results.trades.slice(-50).reverse().map((t, i) => (
                        <tr key={i} className="border-b border-[var(--border)] hover:bg-[var(--bg2)]">
                          <td className="py-1 pr-4 truncate max-w-xs font-mono text-[var(--text3)]">{t.slug}</td>
                          <td className="text-right pr-4">{Math.round(t.elapsed)}s</td>
                          <td className="text-right pr-4">{(t.price * 100).toFixed(2)}Â¢</td>
                          <td className={`text-right pr-4 font-bold ${t.side === "UP" ? "text-green-600" : "text-red-600"}`}>{t.side}</td>
                          <td className={`text-right pr-4 font-bold ${t.outcome === "UP" ? "text-green-600" : "text-red-600"}`}>{t.outcome}</td>
                          <td className={`text-right font-bold ${t.win ? "text-green-600" : "text-red-600"}`}>{t.win ? "âœ“" : "âœ—"}</td>
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