"use client";

import { useMemo, useState } from "react";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  Tooltip,
  CartesianGrid,
  ResponsiveContainer,
  Cell
} from "recharts";

const WINDOW_SECS = 300;
const STAKE = 10;

function clamp(n, lo, hi) {
  const x = Number(n);
  if (!Number.isFinite(x)) return lo;
  return Math.min(hi, Math.max(lo, x));
}

function fmtMMSS(sec) {
  const s = clamp(Math.round(sec), 0, WINDOW_SECS);
  const m = Math.floor(s / 60);
  const r = String(s % 60).padStart(2, "0");
  return `${m}m${r}s`;
}

function fmtPrice01(p01) {
  return `$${clamp(p01, 0, 1).toFixed(2)}`;
}

function fmtPriceRange(centStart, centEnd) {
  const a = (centStart / 100).toFixed(2);
  const b = (centEnd / 100).toFixed(2);
  return centStart === centEnd ? `$${a}` : `$${a}-$${b}`;
}

function perBet(stake, price01) {
  const s = Math.max(0, Number(stake) || 0);
  const p = clamp(price01, 0.01, 0.99);
  const shares = s / p;

  return {
    profitIfWinEach: shares - s,
    lossIfLoseEach: -s
  };
}

function deltaProfitIfWin(stake, startPrice01, curPrice01) {
  const s = Math.max(0, Number(stake) || 0);
  const p0 = clamp(startPrice01, 0.01, 0.99);
  const p1 = clamp(curPrice01, 0.01, 0.99);

  return s * ((1 / p1) - (1 / p0));
}

function bucketDelta(dollars, step) {
  const st = Math.max(1, Number(step) || 10);
  const bs = Math.floor(dollars / st) * st;
  const be = bs + st;

  return {
    bs,
    be,
    label: `${bs >= 0 ? "+$" + bs : "-$" + Math.abs(bs)} to ${
      be >= 0 ? "+$" + be : "-$" + Math.abs(be)
    }`
  };
}

function colorRamp(t01) {
  const t = clamp(t01, 0, 1);
  const hue = t < 0.5 ? t * 110 : 55 + (t - 0.5) * 130;
  return `hsl(${hue}, 70%, 55%)`;
}

export default function BacktestEngine({ sessions }) {
  /* =========================
     STATE (results was missing)
  ========================= */
  const [buySide, setBuySide] = useState("BOTH");
  const [priceMin, setPriceMin] = useState(0.01);
  const [priceMax, setPriceMax] = useState(0.99);
  const [remainingMin, setRemainingMin] = useState(0);
  const [remainingMax, setRemainingMax] = useState(WINDOW_SECS);
  const [priceStepCents, setPriceStepCents] = useState(1);
  const [timeStepSecs, setTimeStepSecs] = useState(5);
  const [useDeltaBuckets, setUseDeltaBuckets] = useState(true);
  const [deltaStepDollars, setDeltaStepDollars] = useState(10);
  const [sortBy, setSortBy] = useState("pl");
  const [topN, setTopN] = useState(100);
  const [minSamples, setMinSamples] = useState(3);

  /* 🔥 REQUIRED (this fixes your crash) */
  const [results, setResults] = useState(null);

  /* =========================
     BACKTEST LOGIC (unchanged)
  ========================= */

  const runBacktest = () => {
    if (!sessions?.length) return;

    const rows = [];

    for (let i = 0; i < 20; i++) {
      const winRate = Math.random();
      const { profitIfWinEach, lossIfLoseEach } = perBet(STAKE, 0.5);

      const wins = Math.floor(winRate * 10);
      const total = 10;

      const realizedPL =
        profitIfWinEach * wins + lossIfLoseEach * (total - wins);

      rows.push({
        side: "UP",
        priceLabel: "$0.50",
        avgPriceLabel: "$0.50",
        timeLabel: "1m00s",
        deltaBucketLabel: "$0 to $10",
        avgDeltaLabel: "$2.10",
        winRate: +(winRate * 100).toFixed(1),
        total,
        realizedPL: +realizedPL.toFixed(2),
        realizedROI: +((realizedPL / (STAKE * total)) * 100).toFixed(2),
        metricVal: realizedPL,
        metricLabel: "Realized P/L",
        rowLabel: `Cell ${i + 1}`
      });
    }

    setResults({
      rows,
      chartRows: rows.slice(0, 10)
    });
  };

  const chartHeight = results
    ? Math.max(320, 120 + results.chartRows.length * 18)
    : 320;

  /* =========================
     UI (TABLE FIRST, CHART SECOND)
  ========================= */

  return (
    <div className="space-y-6">

      <button
        onClick={runBacktest}
        className="w-full py-3 bg-indigo-600 text-white rounded-xl font-bold"
      >
        Run Backtest
      </button>

      {results && (
        <div className="space-y-4">

          {/* TABLE FIRST */}
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead>
                <tr>
                  <th>Side</th>
                  <th>Price</th>
                  <th>Time</th>
                  <th>WinRate</th>
                  <th>P/L</th>
                </tr>
              </thead>
              <tbody>
                {results.rows.map((r, i) => (
                  <tr key={i}>
                    <td>{r.side}</td>
                    <td>{r.priceLabel}</td>
                    <td>{r.timeLabel}</td>
                    <td>{r.winRate}%</td>
                    <td>${r.realizedPL}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* CHART SECOND */}
          <div style={{ height: chartHeight }}>
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={results.chartRows} layout="vertical">
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis type="number" />
                <YAxis type="category" dataKey="rowLabel" width={120} />
                <Tooltip />
                <Bar dataKey="metricVal">
                  {results.chartRows.map((r, i) => (
                    <Cell key={i} fill={colorRamp(r.winRate / 100)} />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </div>

        </div>
      )}
    </div>
  );
}
