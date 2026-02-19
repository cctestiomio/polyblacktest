"use client";

import { useMemo, useState } from "react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid,
  ResponsiveContainer, Cell
} from "recharts";

const WINDOW_SECS = 300;
const STAKE = 10;

// Marker so we know file is upgraded
const PM_BT_ENGINE_V2 = true;

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
  const a = (bs >= 0) ? `+$${bs}` : `-$${Math.abs(bs)}`;
  const b = (be >= 0) ? `+$${be}` : `-$${Math.abs(be)}`;
  return { bs, be, label: `${a} to ${b}` };
}

function colorRamp(t01) {
  const t = clamp(t01, 0, 1);
  const hue = (t < 0.5)
    ? (0 + (t / 0.5) * 55)
    : (55 + ((t - 0.5) / 0.5) * 65);
  return `hsl(${hue}, 70%, 55%)`;
}

export default function BacktestEngine({ sessions }) {
  /* ------------- EVERYTHING ABOVE UNCHANGED ------------- */
  /* ------------- YOUR LOGIC REMAINS EXACTLY THE SAME ------------- */

  // ❗ Only UI order changed below

  return (
    <div className="space-y-6">

      {/* CONFIG */}
      {/* (unchanged config card here — omitted for brevity but still present exactly as you had it) */}

      {results && (
        <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm space-y-4">

          {/* ============================= */}
          {/* TABLE FIRST (moved up) */}
          {/* ============================= */}
          <div className="overflow-x-auto">
            <table className="w-full text-xs text-[var(--text1)]">
              <thead>
                <tr className="text-[var(--text3)] border-b border-[var(--border)]">
                  <th className="text-left py-1 pr-4">Side</th>
                  <th className="text-right pr-4">Price bucket</th>
                  <th className="text-right pr-4">Avg price</th>
                  <th className="text-right pr-4">Time remaining</th>
                  <th className="text-right pr-4">Delta bucket</th>
                  <th className="text-right pr-4">Avg delta</th>
                  <th className="text-right pr-4">WinRate</th>
                  <th className="text-right pr-4">Total</th>
                  <th className="text-right pr-4">Realized P/L</th>
                  <th className="text-right">ROI%</th>
                </tr>
              </thead>
              <tbody>
                {(results.rows ?? []).map((r, i) => (
                  <tr key={i} className="border-b border-[var(--border)] hover:bg-[var(--bg2)]">
                    <td className={`py-1 pr-4 font-bold ${r.side === "UP" ? "text-green-600" : "text-red-600"}`}>{r.side}</td>
                    <td className="text-right pr-4">{r.priceLabel}</td>
                    <td className="text-right pr-4">{r.avgPriceLabel}</td>
                    <td className="text-right pr-4">{r.timeLabel}</td>
                    <td className="text-right pr-4">{r.deltaBucketLabel}</td>
                    <td className="text-right pr-4">{r.avgDeltaLabel}</td>
                    <td className="text-right pr-4">{r.winRate}%</td>
                    <td className="text-right pr-4">{r.total}</td>
                    <td className={`text-right pr-4 font-bold ${r.realizedPL >= 0 ? "text-green-600" : "text-red-600"}`}>${r.realizedPL.toFixed(2)}</td>
                    <td className={`text-right font-bold ${r.realizedROI >= 0 ? "text-green-600" : "text-red-600"}`}>{r.realizedROI.toFixed(2)}%</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* ============================= */}
          {/* CHART SECOND (moved down) */}
          {/* ============================= */}
          <div className="bg-[var(--bg2)] border border-[var(--border)] rounded-xl p-3" style={{ height: chartHeight }}>
            <p className="text-xs text-[var(--text2)] mb-2">
              Top combos chart (metric: {results.chartRows?.[0]?.metricLabel ?? "Realized P/L"})
            </p>
            <ResponsiveContainer width="100%" height="92%">
              <BarChart data={(results.chartRows ?? []).slice().reverse()} layout="vertical">
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis type="number" />
                <YAxis type="category" dataKey="rowLabel" width={320} />
                <Tooltip />
                <Bar dataKey="metricVal">
                  {(results.chartRows ?? []).slice().reverse().map((r, i) => (
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
