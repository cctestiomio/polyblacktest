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
  // Defaults requested: 0.01 - 0.99
  const [buySide, setBuySide] = useState("BOTH"); // UP, DOWN, BOTH
  const [priceMin, setPriceMin] = useState(0.01);
  const [priceMax, setPriceMax] = useState(0.99);
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);

  // Output controls
  const [rankSide, setRankSide] = useState("BOTH"); // UP, DOWN, BOTH
  const [topN, setTopN] = useState(30);
  const [minSamples, setMinSamples] = useState(10);

  // What-if lookup
  const [qSide, setQSide] = useState("UP");
  const [qPrice, setQPrice] = useState(0.60);
  const [qElapsed, setQElapsed] = useState(120);

  const [results, setResults] = useState(null);

  const normalized = useMemo(() => {
    const pMin = clamp(Math.min(priceMin, priceMax), 0, 1);
    const pMax = clamp(Math.max(priceMin, priceMax), 0, 1);
    const eMin = clamp(Math.min(elapsedMin, elapsedMax), 0, 300);
    const eMax = clamp(Math.max(elapsedMin, elapsedMax), 0, 300);
    return {
      pMin, pMax, eMin, eMax,
      topN: clamp(topN, 5, 200),
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

      for (const point of session.priceHistory ?? []) {
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
      setResults({ summary: null, bestCombos: [], comboBySide });
      return;
    }

    const wins = trades.reduce((acc, t) => acc + (t.win ? 1 : 0), 0);
    const wr = wins / trades.length;

    let pool = [];
    if (rankSide === "BOTH") pool = [...comboBySide.UP.values(), ...comboBySide.DOWN.values()];
    else pool = [...comboBySide[rankSide].values()];

    const bestCombos = pool
      .filter(x => x.total >= normalized.minSamples)
      .map(x => {
        const winRate = (x.wins / x.total) * 100;
        const price01 = x.cent / 100;
        const label = (rankSide === "BOTH")
          ? `${x.side} ${fmtPrice01(price01)} @ ${fmtTime(x.sec)}`
          : `${fmtPrice01(price01)} @ ${fmtTime(x.sec)}`;

        const likelyOutcome = (winRate >= 50) ? x.side : opposite(x.side);

        return {
          label,
          winRate: +winRate.toFixed(1),
          wins: x.wins,
          total: x.total,
          side: x.side,
          sec: x.sec,
          cent: x.cent,
          likelyOutcome
        };
      })
      .sort((a, b) => (b.winRate - a.winRate) || (b.total - a.total) || (a.sec - b.sec) || (a.cent - b.cent))
      .slice(0, normalized.topN);

    setResults({
      summary: { total: trades.length, wins, winRate: wr },
      bestCombos,
      comboBySide
    });
  };

  const whatIf = useMemo(() => {
    if (!results?.comboBySide) return null;

    const side = qSide;
    const sec = clamp(Math.round(qElapsed), 0, 300);
    const cent = clamp(Math.round(clamp(qPrice, 0, 1) * 100), 0, 100);
    if (cent < 1 || cent > 99) return { ok: false, msg: "Price must round to 0.01 - 0.99." };

    const key = (sec * 100) + cent;
    const cell = results.comboBySide[side].get(key);
    if (!cell || !cell.total) return { ok: false, msg: "No samples for that exact price+time. Try nearby values." };

    const winRate = (cell.wins / cell.total) * 100;
    const likelyOutcome = (winRate >= 50) ? side : opposite(side);

    return {
      ok: true,
      side,
      priceStr: fmtPrice01(cent / 100),
      timeStr: fmtTime(sec),
      winRate: +winRate.toFixed(1),
      wins: cell.wins,
      total: cell.total,
      likelyOutcome
    };
  }, [results, qSide, qPrice, qElapsed]);

  const chartHeight = results?.bestCombos
    ? Math.max(520, 190 + (results.bestCombos.length * 18))
    : 520;

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
            <label className="text-xs text-[var(--text2)] block mb-1">Rank combos for</label>
            <div className="flex gap-2">
              {["UP","DOWN","BOTH"].map(s => (
                <button key={s} onClick={() => setRankSide(s)}
                  className={`flex-1 py-2 rounded-lg font-bold text-sm transition ${
                    rankSide === s ? "bg-indigo-600 text-white" : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
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
            <label className="text-xs text-[var(--text2)] block mb-1">Top N combos</label>
            <input type="number" min="5" max="200" step="1" value={topN}
              onChange={e => setTopN(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]" />
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Min samples per combo (n)</label>
            <input type="number" min="1" step="1" value={minSamples}
              onChange={e => setMinSamples(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]" />
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

              <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm space-y-3">
                <p className="text-sm font-bold">What-if lookup (exact price + exact time)</p>
                <div className="grid grid-cols-1 sm:grid-cols-4 gap-3 items-end">
                  <div>
                    <label className="text-xs text-[var(--text2)] block mb-1">Buy token</label>
                    <select value={qSide} onChange={e => setQSide(e.target.value)}
                      className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]">
                      <option value="UP">UP (YES)</option>
                      <option value="DOWN">DOWN (NO)</option>
                    </select>
                  </div>
                  <div>
                    <label className="text-xs text-[var(--text2)] block mb-1">Entry price (0-1)</label>
                    <input type="number" min="0" max="1" step="0.01" value={qPrice}
                      onChange={e => setQPrice(+e.target.value)}
                      className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]" />
                  </div>
                  <div>
                    <label className="text-xs text-[var(--text2)] block mb-1">Elapsed seconds (0-300)</label>
                    <input type="number" min="0" max="300" step="1" value={qElapsed}
                      onChange={e => setQElapsed(+e.target.value)}
                      className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]" />
                  </div>
                  <div className="text-sm">
                    {whatIf?.ok ? (
                      <div className="rounded-lg border border-[var(--border)] bg-[var(--bg2)] px-3 py-2">
                        <div className="font-semibold">{whatIf.side} at {whatIf.priceStr} and {whatIf.timeStr}</div>
                        <div>Historical win rate: {whatIf.winRate}% (wins={whatIf.wins}, n={whatIf.total})</div>
                        <div>Likely outcome: {whatIf.likelyOutcome}</div>
                      </div>
                    ) : (
                      <div className="text-[var(--text3)]">{whatIf?.msg ?? "Run a backtest to enable lookup."}</div>
                    )}
                  </div>
                </div>
              </div>

              <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm" style={{ height: chartHeight }}>
                <p className="text-sm font-bold mb-2">Best price+time combos (sorted highest to lowest win rate)</p>
                <ResponsiveContainer width="100%" height="92%">
                  <BarChart data={results.bestCombos} layout="vertical" margin={{ left: 20, right: 20, top: 10, bottom: 10 }}>
                    <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                    <XAxis type="number" domain={[0, 100]} tickFormatter={(v) => `${v}%`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                    <YAxis type="category" dataKey="label" width={240} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                    <Tooltip
                      formatter={(v, n, ctx) => {
                        const p = ctx?.payload;
                        if (!p) return [v, n];
                        return [`${p.winRate}% (wins=${p.wins}, n=${p.total}), likely outcome=${p.likelyOutcome}`, "Win Rate"];
                      }}
                      contentStyle={{ background: "var(--card)", border: "1px solid var(--border)", borderRadius: 8 }}
                    />
                    <Bar dataKey="winRate" radius={[4,4,4,4]}>
                      {results.bestCombos.map((e, i) => (
                        <Cell key={i} fill={e.winRate >= 50 ? "#16a34a" : "#dc2626"} />
                      ))}
                    </Bar>
                  </BarChart>
                </ResponsiveContainer>
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