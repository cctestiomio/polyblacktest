"use client";
import { useMemo, useState } from "react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid,
  ResponsiveContainer, Cell,
} from "recharts";

const SIDE_LABEL = {
  UP: "YES (UP)",
  DOWN: "NO (DOWN)",
  BOTH: "YES + NO",
};

const TRADE_MODE_LABEL = {
  FIRST_PER_SESSION: "First match per session",
  EVERY_MATCH: "Every matching point",
};

function clampNum(v, min, max) {
  const n = Number(v);
  if (!Number.isFinite(n)) return min;
  return Math.min(max, Math.max(min, n));
}

export default function BacktestEngine({ sessions }) {
  // Strategy inputs
  const [side, setSide] = useState("UP"); // YES=UP, NO=DOWN
  const [priceMin, setPriceMin] = useState(0.1);
  const [priceMax, setPriceMax] = useState(0.9);
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);

  // Output settings
  const [groupBy, setGroupBy] = useState("priceRange"); // priceRange | elapsedRange
  const [priceBinCents, setPriceBinCents] = useState(5); // bucket size in cents
  const [elapsedBinSec, setElapsedBinSec] = useState(30); // bucket size in seconds
  const [tradeMode, setTradeMode] = useState("FIRST_PER_SESSION"); // FIRST_PER_SESSION | EVERY_MATCH

  const [results, setResults] = useState(null);

  const normalized = useMemo(() => {
    const pMin = Math.min(priceMin, priceMax);
    const pMax = Math.max(priceMin, priceMax);
    const eMin = Math.min(elapsedMin, elapsedMax);
    const eMax = Math.max(elapsedMin, elapsedMax);

    return {
      pMin: clampNum(pMin, 0, 1),
      pMax: clampNum(pMax, 0, 1),
      eMin: clampNum(eMin, 0, 300),
      eMax: clampNum(eMax, 0, 300),
      priceBinCents: clampNum(priceBinCents, 1, 50),
      elapsedBinSec: clampNum(elapsedBinSec, 5, 300),
    };
  }, [priceMin, priceMax, elapsedMin, elapsedMax, priceBinCents, elapsedBinSec]);

  const runBacktest = () => {
    const trades = [];
    const selectedSides = side === "BOTH" ? ["UP", "DOWN"] : [side];

    for (const session of sessions) {
      const outcome = session?.outcome;
      if (!outcome) continue;

      const points = Array.isArray(session?.priceHistory) ? session.priceHistory : [];
      if (!points.length) continue;

      // For FIRST_PER_SESSION, we allow at most one trade per (session, side).
      for (const s of selectedSides) {
        let tookTradeForThisSide = false;

        for (const point of points) {
          const el = point?.elapsed ?? 0;
          if (el < normalized.eMin || el > normalized.eMax) continue;

          const price = s === "DOWN" ? point?.down : point?.up;
          if (price == null) continue;
          if (price < normalized.pMin || price > normalized.pMax) continue;

          const win = outcome === s;

          trades.push({
            slug: session?.slug ?? "?",
            elapsed: el,
            price, // 0..1
            side: s,
            outcome,
            win,
          });

          if (tradeMode === "FIRST_PER_SESSION") {
            tookTradeForThisSide = true;
            break; // stop after first match in this session for this side
          }
        }

        if (tradeMode === "FIRST_PER_SESSION" && tookTradeForThisSide) {
          // continue; (explicitly does nothing; clarity)
        }
      }
    }

    if (!trades.length) {
      setResults({
        trades: [],
        summary: null,
        chart: [],
        params: { ...normalized, side, groupBy, priceBinCents: normalized.priceBinCents, elapsedBinSec: normalized.elapsedBinSec, tradeMode },
      });
      return;
    }

    const wins = trades.reduce((acc, t) => acc + (t.win ? 1 : 0), 0);
    const winRate = wins / trades.length;

    const bucket = {};
    if (groupBy === "priceRange") {
      const bin = normalized.priceBinCents;
      for (const t of trades) {
        const cents = Math.floor((t.price * 100) / bin) * bin;
        const label = `${cents}Â¢`;
        bucket[label] = bucket[label] ?? { wins: 0, total: 0, sort: cents };
        bucket[label].total++;
        if (t.win) bucket[label].wins++;
      }
    } else {
      const bin = normalized.elapsedBinSec;
      for (const t of trades) {
        const sec = Math.floor(t.elapsed / bin) * bin;
        const label = `${sec}s`;
        bucket[label] = bucket[label] ?? { wins: 0, total: 0, sort: sec };
        bucket[label].total++;
        if (t.win) bucket[label].wins++;
      }
    }

    const chart = Object.entries(bucket)
      .sort((a, b) => a[1].sort - b[1].sort)
      .map(([label, { wins, total }]) => ({
        label,
        winRate: +((wins / total) * 100).toFixed(1),
        wins,
        total,
      }));

    setResults({
      trades,
      summary: { total: trades.length, wins, winRate },
      chart,
      params: { ...normalized, side, groupBy, priceBinCents: normalized.priceBinCents, elapsedBinSec: normalized.elapsedBinSec, tradeMode },
    });
  };

  return (
    <div className="space-y-6">
      <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-5 shadow-sm space-y-4">
        <h2 className="text-lg font-bold">Backtest Configuration</h2>

        <p className="text-xs text-[var(--text3)]">
          A â€œtradeâ€ is recorded when a session has a price point within your filters.
          Choose whether to count the first match per session (typical) or every matching point (more aggressive).
        </p>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Buy Token</label>
            <div className="flex gap-2">
              {["UP", "DOWN", "BOTH"].map(s => (
                <button
                  key={s}
                  onClick={() => setSide(s)}
                  className={`flex-1 py-2 rounded-lg font-bold text-sm transition ${side === s
                    ? "bg-indigo-600 text-white"
                    : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
                  }`}
                >
                  {SIDE_LABEL[s]}
                </button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Trade Counting</label>
            <div className="flex gap-2">
              {["FIRST_PER_SESSION", "EVERY_MATCH"].map(m => (
                <button
                  key={m}
                  onClick={() => setTradeMode(m)}
                  className={`flex-1 py-2 rounded-lg text-sm transition ${tradeMode === m
                    ? "bg-indigo-600 text-white"
                    : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
                  }`}
                >
                  {TRADE_MODE_LABEL[m]}
                </button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Entry Price Range (0â€“1)</label>
            <div className="flex gap-2 items-center">
              <input
                type="number" min="0" max="1" step="0.01" value={priceMin}
                onChange={e => setPriceMin(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]"
              />
              <span className="text-[var(--text3)]">to</span>
              <input
                type="number" min="0" max="1" step="0.01" value={priceMax}
                onChange={e => setPriceMax(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]"
              />
            </div>
            <p className="text-xs text-[var(--text3)] mt-1">Example: 0.55â€“0.65 â‰ˆ 55Â¢â€“65Â¢</p>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Time Elapsed Range (seconds 0â€“300)</label>
            <div className="flex gap-2 items-center">
              <input
                type="number" min="0" max="300" step="1" value={elapsedMin}
                onChange={e => setElapsedMin(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]"
              />
              <span className="text-[var(--text3)]">to</span>
              <input
                type="number" min="0" max="300" step="1" value={elapsedMax}
                onChange={e => setElapsedMax(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]"
              />
            </div>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Group Results By</label>
            <div className="flex gap-2">
              {[["priceRange", "Entry Price"], ["elapsedRange", "Elapsed Time"]].map(([v, l]) => (
                <button
                  key={v}
                  onClick={() => setGroupBy(v)}
                  className={`flex-1 py-2 rounded-lg text-sm transition ${groupBy === v
                    ? "bg-indigo-600 text-white"
                    : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
                  }`}
                >
                  {l}
                </button>
              ))}
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-xs text-[var(--text2)] block mb-1">Price Bin (Â¢)</label>
              <select
                value={priceBinCents}
                onChange={e => setPriceBinCents(+e.target.value)}
                className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]"
              >
                {[1, 5, 10, 20].map(v => <option key={v} value={v}>{v}Â¢ bins</option>)}
              </select>
            </div>
            <div>
              <label className="text-xs text-[var(--text2)] block mb-1">Time Bin (s)</label>
              <select
                value={elapsedBinSec}
                onChange={e => setElapsedBinSec(+e.target.value)}
                className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]"
              >
                {[10, 15, 30, 60].map(v => <option key={v} value={v}>{v}s bins</option>)}
              </select>
            </div>
          </div>
        </div>

        <button
          onClick={runBacktest}
          disabled={sessions.length === 0}
          className="w-full py-3 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 text-white rounded-xl font-bold text-base"
        >
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

              <div className="text-xs text-[var(--text3)]">
                Filters: {SIDE_LABEL[results.params.side]} Â· price {results.params.pMin.toFixed(2)}â€“{results.params.pMax.toFixed(2)} Â· time {results.params.eMin}â€“{results.params.eMax}s Â· mode {TRADE_MODE_LABEL[results.params.tradeMode]}
              </div>

              {results.chart.length > 0 && (
                <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm" style={{ height: 300 }}>
                  <p className="text-xs text-[var(--text2)] mb-3">
                    Win Rate by {groupBy === "priceRange" ? `Entry Price (${results.params.priceBinCents}Â¢ bins)` : `Elapsed Time (${results.params.elapsedBinSec}s bins)`}
                  </p>
                  <ResponsiveContainer width="100%" height="90%">
                    <BarChart data={results.chart}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                      <XAxis dataKey="label" stroke="#94a3b8" tick={{ fontSize: 11 }} />
                      <YAxis domain={[0, 100]} tickFormatter={v => `${v}%`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                      <Tooltip
                        formatter={(v, n, ctx) => {
                          if (n === "winRate") return [`${v}%`, "Win Rate"];
                          if (n === "total") return [v, "Trades"];
                          if (n === "wins") return [v, "Wins"];
                          return [v, n];
                        }}
                        contentStyle={{ background: "var(--card)", border: "1px solid var(--border)", borderRadius: 8 }}
                      />
                      <Bar dataKey="winRate" radius={[4, 4, 0, 0]}>
                        {results.chart.map((e, i) => (
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
                        <th className="text-right pr-4">Entry</th>
                        <th className="text-right pr-4">Token</th>
                        <th className="text-right pr-4">Outcome</th>
                        <th className="text-right">Result</th>
                      </tr>
                    </thead>
                    <tbody>
                      {results.trades.slice(-50).reverse().map((t, i) => (
                        <tr key={i} className="border-b border-[var(--border)] hover:bg-[var(--bg2)]">
                          <td className="py-1 pr-4 truncate max-w-xs font-mono text-[var(--text3)]">{t.slug}</td>
                          <td className="text-right pr-4">{t.elapsed}s</td>
                          <td className="text-right pr-4">{(t.price * 100).toFixed(1)}Â¢</td>
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