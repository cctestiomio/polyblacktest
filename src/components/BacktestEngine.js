"use client";

import { useState } from "react";
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

export default function BacktestEngine({ sessions }) {
  /* =========================
     STATE (unchanged)
  ========================= */
  const [results, setResults] = useState(null);

  /* =========================
     DEMO BACKTEST (same logic)
  ========================= */
  const runBacktest = () => {
    const rows = [];

    for (let i = 0; i < 25; i++) {
      const winRate = Math.random();
      const total = 10;
      const stake = 10;

      const profitIfWin = stake;
      const lossIfLose = -stake;

      const wins = Math.floor(winRate * total);

      const realizedPL =
        profitIfWin * wins + lossIfLose * (total - wins);

      rows.push({
        side: winRate > 0.5 ? "UP" : "DOWN",
        priceLabel: "$0.50",
        avgPriceLabel: "$0.50",
        timeLabel: "1m00s",
        deltaBucketLabel: "$0-$10",
        avgDeltaLabel: "$2.1",
        winRate: +(winRate * 100).toFixed(1),
        total,
        realizedPL: +realizedPL.toFixed(2),
        realizedROI: +((realizedPL / (stake * total)) * 100).toFixed(2),
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
     UI
     TABLE FIRST
     CHART SECOND
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
        <div className="space-y-6">

          {/* ========================= */}
          {/* TABLE (FIRST) */}
          {/* ========================= */}
          <div className="overflow-x-auto">
            <table className="w-full text-xs border">
              <thead>
                <tr className="bg-gray-100">
                  <th className="p-2 text-left">Side</th>
                  <th className="p-2">Price</th>
                  <th className="p-2">Time</th>
                  <th className="p-2">WinRate</th>
                  <th className="p-2">Total</th>
                  <th className="p-2">P/L</th>
                  <th className="p-2">ROI%</th>
                </tr>
              </thead>

              <tbody>
                {results.rows.map((r, i) => (
                  <tr key={i} className="border-t">
                    <td className="p-2">{r.side}</td>
                    <td className="p-2">{r.priceLabel}</td>
                    <td className="p-2">{r.timeLabel}</td>
                    <td className="p-2">{r.winRate}%</td>
                    <td className="p-2">{r.total}</td>
                    <td className="p-2">${r.realizedPL}</td>
                    <td className="p-2">{r.realizedROI}%</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* ========================= */}
          {/* CHART (SECOND) */}
          {/* ========================= */}
          <div style={{ height: chartHeight }}>
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={results.chartRows} layout="vertical">
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis type="number" />
                <YAxis
                  type="category"
                  dataKey="rowLabel"
                  width={100}
                />
                <Tooltip />

                <Bar dataKey="metricVal">
                  {results.chartRows.map((r, i) => (
                    <Cell
                      key={i}
                      fill={
                        r.metricVal >= 0
                          ? "hsl(140 60% 50%)"
                          : "hsl(0 70% 55%)"
                      }
                    />
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
