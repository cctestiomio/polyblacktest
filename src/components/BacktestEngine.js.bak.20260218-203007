"use client";
import { useMemo, useState } from "react";

function clamp(n, lo, hi) {
  const x = Number(n);
  if (!Number.isFinite(x)) return lo;
  return Math.min(hi, Math.max(lo, x));
}

function fmtPrice01(p01) {
  const p = clamp(p01, 0, 1);
  return `$${p.toFixed(2)}`;
}

function fmtTime(sec) {
  const s = clamp(Math.round(sec), 0, 300);
  const m = Math.floor(s / 60);
  const r = String(s % 60).padStart(2, "0");
  return `${m}m${r}s`;
}

function opposite(side) {
  return side === "UP" ? "DOWN" : "UP";
}

export default function BacktestEngine({ sessions }) {
  // Defaults requested
  const [buySide, setBuySide] = useState("BOTH"); // UP, DOWN, BOTH
  const [priceMin, setPriceMin] = useState(0.01);
  const [priceMax, setPriceMax] = useState(0.99);
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);

  // Make it easy to actually see rows
  const [topN, setTopN] = useState(50);
  const [minSamples, setMinSamples] = useState(1); // important: default low so table is not empty

  const [results, setResults] = useState(null);

  const normalized = useMemo(() => {
    const pMin = clamp(Math.min(priceMin, priceMax), 0, 1);
    const pMax = clamp(Math.max(priceMin, priceMax), 0, 1);
    const eMin = clamp(Math.min(elapsedMin, elapsedMax), 0, 300);
    const eMax = clamp(Math.max(elapsedMin, elapsedMax), 0, 300);
    return {
      pMin, pMax, eMin, eMax,
      topN: clamp(topN, 1, 500),
      minSamples: clamp(minSamples, 1, 1000000)
    };
  }, [priceMin, priceMax, elapsedMin, elapsedMax, topN, minSamples]);

  const runBacktest = () => {
    const sides = buySide === "BOTH" ? ["UP", "DOWN"] : [buySide];

    const trades = [];
    const comboBySide = { UP: new Map(), DOWN: new Map() }; // key = sec*100 + cent

    for (const session of sessions) {
      const outcome = session?.outcome;
      if (!outcome) continue;

      const points = Array.isArray(session?.priceHistory) ? session.priceHistory : [];
      for (const point of points) {
        const el = point?.elapsed ?? 0;
        if (el < normalized.eMin || el > normalized.eMax) continue;

        for (const s of sides) {
          const price = (s === "DOWN") ? point?.down : point?.up;
          if (price == null) continue;
          if (price < normalized.pMin || price > normalized.pMax) continue;

          const sec = clamp(Math.round(el), 0, 300);
          const cent = clamp(Math.round(price * 100), 0, 100);
          if (cent < 1 || cent > 99) continue;

          const win = outcome === s;
          trades.push({ sec, cent, side: s, win });

          const key = (sec * 100) + cent;
          const m = comboBySide[s];
          const cur = m.get(key) ?? { wins: 0, total: 0, sec, cent, side: s };
          cur.total++;
          if (win) cur.wins++;
          m.set(key, cur);
        }
      }
    }

    if (!trades.length) {
      setResults({ summary: null, bestCombos: [], debug: { combos: 0, trades: 0 } });
      return;
    }

    const totalWins = trades.reduce((acc, t) => acc + (t.win ? 1 : 0), 0);
    const overallWr = totalWins / trades.length;

    const pool = [...comboBySide.UP.values(), ...comboBySide.DOWN.values()];

    const bestCombos = pool
      .filter(x => x.total >= normalized.minSamples)
      .map(x => {
        const winRate01 = x.wins / x.total;
        const winRate = winRate01 * 100;
        const price01 = x.cent / 100;
        const likelyOutcome = (winRate01 >= 0.5) ? x.side : opposite(x.side);
        return {
          side: x.side,
          price01,
          sec: x.sec,
          wins: x.wins,
          total: x.total,
          winRate: +winRate.toFixed(1),
          likelyOutcome,
        };
      })
      .sort((a, b) => (b.winRate - a.winRate) || (b.total - a.total) || (a.sec - b.sec) || (a.price01 - b.price01))
      .slice(0, normalized.topN);

    setResults({
      summary: { total: trades.length, wins: totalWins, winRate: overallWr },
      bestCombos,
      debug: { combos: pool.length, trades: trades.length }
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
              {["UP","DOWN","BOTH"].map(s => (
                <button key={s} onClick={() => setBuySide(s)}
                  className={`flex-1 py-2 rounded-lg font-bold text-sm transition ${
                    buySide === s ? "bg-indigo-600 text-white" : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
                  }`}>{s}</button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Entry Price Range (0-1)</label>
            <div className="flex gap-2 items-center">
              <input type="number" min="0" max="1" step="0.01" value={priceMin}
                onChange={e => setPriceMin(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]" />
              <span className="text-[var(--text3)]">to</span>
              <input type="number" min="0" max="1" step="0.01" value={priceMax}
                onChange={e => setPriceMax(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]" />
            </div>
            <p className="text-xs text-[var(--text3)] mt-1">Default is 0.01 to 0.99.</p>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Time Elapsed Range (seconds 0-300)</label>
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

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Top N rows</label>
            <input type="number" min="1" max="500" step="1" value={topN}
              onChange={e => setTopN(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]" />
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Min samples per (price,time) cell</label>
            <input type="number" min="1" step="1" value={minSamples}
              onChange={e => setMinSamples(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]" />
            <p className="text-xs text-[var(--text3)] mt-1">If your table is empty, lower this.</p>
          </div>
        </div>

        <button onClick={runBacktest} disabled={sessions.length === 0}
          className="w-full py-3 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 text-white rounded-xl font-bold text-base">
          Run Backtest ({sessions.length} session{sessions.length !== 1 ? "s" : ""} loaded)
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

              <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm">
                <p className="text-sm font-bold mb-2">Best price + time combos (table, sorted by win rate)</p>

                {results.bestCombos.length === 0 ? (
                  <div className="text-sm text-[var(--text3)]">
                    No rows. Try: set Min samples to 1, widen filters, or confirm sessions have outcomes.
                  </div>
                ) : (
                  <div className="overflow-x-auto">
                    <table className="w-full text-xs text-[var(--text1)]">
                      <thead>
                        <tr className="text-[var(--text3)] border-b border-[var(--border)]">
                          <th className="text-left py-1 pr-4">Side</th>
                          <th className="text-right pr-4">Price</th>
                          <th className="text-right pr-4">Elapsed</th>
                          <th className="text-right pr-4">WinRate</th>
                          <th className="text-right pr-4">Wins</th>
                          <th className="text-right pr-4">N</th>
                          <th className="text-right">Likely outcome</th>
                        </tr>
                      </thead>
                      <tbody>
                        {results.bestCombos.map((r, i) => (
                          <tr key={i} className="border-b border-[var(--border)] hover:bg-[var(--bg2)]">
                            <td className={`py-1 pr-4 font-bold ${r.side === "UP" ? "text-green-600" : "text-red-600"}`}>{r.side}</td>
                            <td className="text-right pr-4">{fmtPrice01(r.price01)}</td>
                            <td className="text-right pr-4">{fmtTime(r.sec)}</td>
                            <td className="text-right pr-4">{r.winRate}%</td>
                            <td className="text-right pr-4">{r.wins}</td>
                            <td className="text-right pr-4">{r.total}</td>
                            <td className="text-right font-bold">{r.likelyOutcome}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}

                <div className="text-xs text-[var(--text3)] mt-3">
                  Debug: combos scanned={results.debug?.combos ?? 0}, trades={results.debug?.trades ?? 0}
                </div>
              </div>
            </>
          ) : (
            <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-6 text-center text-[var(--text3)]">
              No matching trades.
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