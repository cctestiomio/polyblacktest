"use client";
import { useMemo, useState } from "react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid,
  ResponsiveContainer, Cell
} from "recharts";

function clamp(n, lo, hi) {
  const x = Number(n);
  if (!Number.isFinite(x)) return lo;
  return Math.min(hi, Math.max(lo, x));
}

function fmtMMSS(sec) {
  const s = clamp(Math.round(sec), 0, 300);
  const m = Math.floor(s / 60);
  const r = String(s % 60).padStart(2, "0");
  return `${m}m${r}s`;
}

function fmtPrice01(p01) {
  const p = clamp(p01, 0, 1);
  return `$${p.toFixed(2)}`;
}

function fmtPriceRange(centStart, centEnd) {
  const a = (centStart / 100).toFixed(2);
  const b = (centEnd / 100).toFixed(2);
  return centStart === centEnd ? `$${a}` : `$${a}-$${b}`;
}

function opposite(side) {
  return side === "UP" ? "DOWN" : "UP";
}

// stake = $10, buy at price p, shares=stake/p
// if correct -> profit=shares - stake
// if wrong -> profit=-stake
function profitPerBet(stake, avgPrice01) {
  const s = Math.max(0, Number(stake) || 0);
  const p = clamp(avgPrice01, 0.01, 0.99);
  const shares = s / p;
  const profitIfWinEach = shares - s;
  const lossIfLoseEach = -s;
  return { stake: s, shares, profitIfWinEach, lossIfLoseEach };
}

function colorForMetric(sortBy, value) {
  let t = 0.5;
  if (sortBy === "winrate") t = clamp(value / 100, 0, 1);
  else if (sortBy === "roi") t = clamp((value + 100) / 200, 0, 1);
  else t = clamp((value + 10) / 60, 0, 1);

  const hue = (t < 0.5) ? (0 + (t / 0.5) * 55) : (55 + ((t - 0.5) / 0.5) * 65);
  return `hsl(${hue}, 70%, 55%)`;
}

export default function BacktestEngine({ sessions }) {
  // Defaults
  const [buySide, setBuySide] = useState("BOTH"); // UP, DOWN, BOTH
  const [priceMin, setPriceMin] = useState(0.10);
  const [priceMax, setPriceMax] = useState(0.90);
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);

  const [priceStepCents, setPriceStepCents] = useState(5); // 1,5,10
  const [timeStepSecs, setTimeStepSecs] = useState(5);     // 1,5,10

  const [sortBy, setSortBy] = useState("winrate"); // winrate | roi | pl
  const [topN, setTopN] = useState(50);
  const [minSamples, setMinSamples] = useState(1);

  const STAKE = 10;

  const [results, setResults] = useState(null);

  const normalized = useMemo(() => {
    const pMin = clamp(Math.min(priceMin, priceMax), 0, 1);
    const pMax = clamp(Math.max(priceMin, priceMax), 0, 1);
    const eMin = clamp(Math.min(elapsedMin, elapsedMax), 0, 300);
    const eMax = clamp(Math.max(elapsedMin, elapsedMax), 0, 300);

    const ps = ([1,5,10].includes(Number(priceStepCents)) ? Number(priceStepCents) : 5);
    const ts = ([1,5,10].includes(Number(timeStepSecs)) ? Number(timeStepSecs) : 5);

    const s = (sortBy === "roi" || sortBy === "pl" || sortBy === "winrate") ? sortBy : "winrate";

    return {
      pMin, pMax, eMin, eMax,
      ps, ts,
      sortBy: s,
      topN: clamp(topN, 1, 500),
      minSamples: clamp(minSamples, 1, 1000000),
    };
  }, [priceMin, priceMax, elapsedMin, elapsedMax, priceStepCents, timeStepSecs, sortBy, topN, minSamples]);

  const runBacktest = () => {
    const sides = buySide === "BOTH" ? ["UP", "DOWN"] : [buySide];

    let tradesCount = 0;
    let winsCount = 0;

    // key = side|remStart|centStart
    const cells = new Map();

    for (const session of sessions) {
      const outcome = session?.outcome;
      if (!outcome) continue;

      const points = Array.isArray(session?.priceHistory) ? session.priceHistory : [];
      for (const point of points) {
        const el = point?.elapsed ?? 0;
        if (el < normalized.eMin || el > normalized.eMax) continue;

        const secElapsed = clamp(Math.round(el), 0, 300);
        const secRemaining = clamp(300 - secElapsed, 0, 300);

        for (const s of sides) {
          const price = (s === "DOWN") ? point?.down : point?.up;
          if (price == null) continue;
          if (price < normalized.pMin || price > normalized.pMax) continue;

          const cent = clamp(Math.round(price * 100), 0, 100);
          if (cent < 1 || cent > 99) continue;

          const centStart = (Math.floor((cent - 1) / normalized.ps) * normalized.ps) + 1;
          const centEnd = Math.min(99, centStart + normalized.ps - 1);

          const remStart = Math.floor(secRemaining / normalized.ts) * normalized.ts;
          const remEnd = Math.min(300, remStart + normalized.ts - 1);

          const win = outcome === s;

          tradesCount++;
          if (win) winsCount++;

          const key = `${s}|${remStart}|${centStart}`;
          const cur = cells.get(key) ?? {
            side: s,
            remStart, remEnd,
            centStart, centEnd,
            wins: 0,
            total: 0,
            sumPrice01: 0
          };

          cur.total++;
          if (win) cur.wins++;
          cur.sumPrice01 += price;

          cells.set(key, cur);
        }
      }
    }

    if (tradesCount === 0) {
      setResults({ summary: null, rows: [], chartRows: [], debug: { trades: 0, cells: 0 } });
      return;
    }

    const allRows = [...cells.values()]
      .filter(x => x.total >= normalized.minSamples)
      .map(x => {
        const winRate01 = x.wins / x.total;
        const winRatePct = +(winRate01 * 100).toFixed(1);

        const avgPrice01 = x.sumPrice01 / x.total;
        const per = profitPerBet(STAKE, avgPrice01);

        const profitIfWinEach = +per.profitIfWinEach.toFixed(2);
        const lossIfLoseEach = +per.lossIfLoseEach.toFixed(2);

        // FIX: scale ProfitIfWin by how many wins happened in this cell.
        // Example: profitIfWinEach=$15 and wins=4 => ProfitIfWin=$60
        const profitIfWin = +(profitIfWinEach * x.wins).toFixed(2);

        // Also show what would have happened historically if you bet every occurrence:
        const realizedPL = +((profitIfWinEach * x.wins) + (lossIfLoseEach * (x.total - x.wins))).toFixed(2);
        const realizedROI = +((realizedPL / (STAKE * x.total)) * 100).toFixed(2);

        // Expected values (per bet * count)
        const expectedPL = +(((winRate01 * profitIfWinEach) + ((1 - winRate01) * lossIfLoseEach)) * x.total).toFixed(2);
        const expectedROI = +((expectedPL / (STAKE * x.total)) * 100).toFixed(2);

        const likelyOutcome = (winRate01 >= 0.5) ? x.side : opposite(x.side);

        const priceLabel = fmtPriceRange(x.centStart, x.centEnd);
        const timeLabel = (x.remStart === x.remEnd)
          ? fmtMMSS(x.remStart)
          : `${fmtMMSS(x.remStart)}-${fmtMMSS(x.remEnd)}`;

        let metricVal = winRatePct;
        let metricLabel = "WinRate";
        if (normalized.sortBy === "roi") { metricVal = realizedROI; metricLabel = "Realized ROI%"; }
        if (normalized.sortBy === "pl") { metricVal = realizedPL; metricLabel = "Realized P/L"; }

        return {
          ...x,
          winRate: winRatePct,
          avgPrice01,
          avgPriceLabel: fmtPrice01(avgPrice01),
          likelyOutcome,
          priceLabel,
          timeLabel,
          winTotal: `${x.wins}/${x.total}`,

          profitIfWinEach,
          profitIfWin,     // scaled by wins (the requested behavior)
          realizedPL,
          realizedROI,

          expectedPL,
          expectedROI,

          metricVal,
          metricLabel,
          rowLabel: `${x.side} ${priceLabel} @ ${timeLabel}`
        };
      });

    allRows.sort((a, b) => {
      if (normalized.sortBy === "roi") {
        return (b.realizedROI - a.realizedROI) || (b.winRate - a.winRate) || (b.total - a.total);
      }
      if (normalized.sortBy === "pl") {
        return (b.realizedPL - a.realizedPL) || (b.winRate - a.winRate) || (b.total - a.total);
      }
      return (b.winRate - a.winRate) || (b.total - a.total) || (a.remStart - b.remStart) || (a.centStart - b.centStart);
    });

    setResults({
      summary: { total: tradesCount, wins: winsCount, winRate: winsCount / tradesCount },
      rows: allRows.slice(0, normalized.topN),
      chartRows: allRows.slice(0, Math.min(30, normalized.topN)),
      debug: { trades: tradesCount, cells: cells.size, priceStep: normalized.ps, timeStep: normalized.ts, sortBy: normalized.sortBy }
    });
  };

  const chartHeight = results?.chartRows
    ? Math.max(320, 120 + (results.chartRows.length * 18))
    : 320;

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
            <p className="text-xs text-[var(--text3)] mt-1">Default is 0.10 to 0.90.</p>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Time Elapsed Range filter (seconds 0-300)</label>
            <div className="flex gap-2 items-center">
              <input type="number" min="0" max="300" step="1" value={elapsedMin}
                onChange={e => setElapsedMin(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]" />
              <span className="text-[var(--text3)]">to</span>
              <input type="number" min="0" max="300" step="1" value={elapsedMax}
                onChange={e => setElapsedMax(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]" />
            </div>
            <p className="text-xs text-[var(--text3)] mt-1">Best-combos uses time remaining (300 - elapsed).</p>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Group Price by</label>
            <select value={priceStepCents} onChange={e => setPriceStepCents(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]">
              <option value={1}>1 cent</option>
              <option value={5}>5 cents</option>
              <option value={10}>10 cents</option>
            </select>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Group Time by</label>
            <select value={timeStepSecs} onChange={e => setTimeStepSecs(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]">
              <option value={1}>1 second</option>
              <option value={5}>5 seconds</option>
              <option value={10}>10 seconds</option>
            </select>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Sort best combos by</label>
            <select value={sortBy} onChange={e => setSortBy(e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]">
              <option value="winrate">WinRate</option>
              <option value="roi">Realized ROI% (bet every occurrence)</option>
              <option value="pl">Realized P/L (bet every occurrence)</option>
            </select>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Top N rows</label>
            <input type="number" min="1" max="500" step="1" value={topN}
              onChange={e => setTopN(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]" />
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Min samples per cell</label>
            <input type="number" min="1" step="1" value={minSamples}
              onChange={e => setMinSamples(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]" />
          </div>
        </div>

        <button onClick={runBacktest} disabled={sessions.length === 0}
          className="w-full py-3 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 text-white rounded-xl font-bold text-base">
          Run Backtest ({sessions.length} session{sessions.length !== 1 ? "s" : ""} loaded)
        </button>

        <p className="text-xs text-[var(--text3)]">
          Profit numbers assume $10 stake per occurrence, shares=10/avgPrice, payout $1 if correct, $0 if wrong (fees ignored).
        </p>
      </div>

      {results && (
        <div className="space-y-4">
          {results.summary ? (
            <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm">
              <p className="text-sm font-bold mb-2">Best price + time combos (sorted by selected metric)</p>

              <div className="overflow-x-auto">
                <table className="w-full text-xs text-[var(--text1)]">
                  <thead>
                    <tr className="text-[var(--text3)] border-b border-[var(--border)]">
                      <th className="text-left py-1 pr-4">Side</th>
                      <th className="text-right pr-4">Price bucket</th>
                      <th className="text-right pr-4">Avg price</th>
                      <th className="text-right pr-4">Time remaining</th>
                      <th className="text-right pr-4">WinRate</th>
                      <th className="text-right pr-4">Win/Total</th>
                      <th className="text-right pr-4">ProfitIfWin</th>
                      <th className="text-right pr-4">RealizedPL</th>
                      <th className="text-right pr-4">RealizedROI%</th>
                      <th className="text-right">Likely</th>
                    </tr>
                  </thead>
                  <tbody>
                    {results.rows.map((r, i) => (
                      <tr key={i} className="border-b border-[var(--border)] hover:bg-[var(--bg2)]">
                        <td className={`py-1 pr-4 font-bold ${r.side === "UP" ? "text-green-600" : "text-red-600"}`}>{r.side}</td>
                        <td className="text-right pr-4">{r.priceLabel}</td>
                        <td className="text-right pr-4">{r.avgPriceLabel}</td>
                        <td className="text-right pr-4">{r.timeLabel}</td>
                        <td className="text-right pr-4">{r.winRate}%</td>
                        <td className="text-right pr-4">{r.winTotal}</td>
                        <td className="text-right pr-4">${r.profitIfWin.toFixed(2)}</td>
                        <td className={`text-right pr-4 font-bold ${r.realizedPL >= 0 ? "text-green-600" : "text-red-600"}`}>${r.realizedPL.toFixed(2)}</td>
                        <td className={`text-right pr-4 font-bold ${r.realizedROI >= 0 ? "text-green-600" : "text-red-600"}`}>{r.realizedROI.toFixed(2)}%</td>
                        <td className="text-right font-bold">{r.likelyOutcome}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              <div className="mt-4 bg-[var(--bg2)] border border-[var(--border)] rounded-xl p-3" style={{ height: chartHeight }}>
                <p className="text-xs text-[var(--text2)] mb-2">Top combos chart (metric: {results.chartRows?.[0]?.metricLabel ?? "WinRate"})</p>

                <ResponsiveContainer width="100%" height="92%">
                  <BarChart data={(results.chartRows ?? []).slice().reverse()} layout="vertical" margin={{ left: 10, right: 20, top: 10, bottom: 10 }}>
                    <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                    <XAxis
                      type="number"
                      stroke="#94a3b8"
                      tick={{ fontSize: 11 }}
                      tickFormatter={(v) => {
                        if (normalized.sortBy === "winrate") return `${v}%`;
                        if (normalized.sortBy === "roi") return `${v}%`;
                        return `$${v}`;
                      }}
                    />
                    <YAxis type="category" dataKey="rowLabel" width={260} stroke="#94a3b8" tick={{ fontSize: 10 }} />
                    <Tooltip
                      formatter={(v, n, ctx) => {
                        const p = ctx?.payload;
                        if (!p) return [v, n];
                        return [
                          `${p.metricLabel}=${p.metricVal}, winRate=${p.winRate}%, win/total=${p.winTotal}, profitIfWinEach=$${p.profitIfWinEach}, profitIfWin=$${p.profitIfWin}, realizedPL=$${p.realizedPL}`,
                          "Combo"
                        ];
                      }}
                      contentStyle={{ background: "var(--card)", border: "1px solid var(--border)", borderRadius: 8 }}
                    />
                    <Bar dataKey="metricVal" radius={[4,4,4,4]}>
                      {(results.chartRows ?? []).slice().reverse().map((e, i) => (
                        <Cell key={i} fill={colorForMetric(normalized.sortBy, e.metricVal)} />
                      ))}
                    </Bar>
                  </BarChart>
                </ResponsiveContainer>
              </div>

              <div className="text-xs text-[var(--text3)] mt-3">
                Note: ProfitIfWin is scaled by wins (profit per bet times wins). RealizedPL includes losses too (bet every occurrence).
              </div>
            </div>
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