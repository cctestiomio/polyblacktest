<# patch-backtestengine-best-combos.ps1
   - Overwrites src/components/BacktestEngine.js
   - Defaults Entry Price Range to 0.01 .. 0.99
   - After "Run Backtest", computes best (price cent + elapsed second) combos and shows them
     sorted by win rate (highest -> lowest) in a bar chart.
   - Also includes 1c and 1s charts and a simple mojibake-fix pass on key UI files.

   Usage:
     .\patch-backtestengine-best-combos.ps1
     .\patch-backtestengine-best-combos.ps1 -DryRun
#>

param(
  [string]$RepoRoot = (Get-Location).Path,
  [switch]$DryRun
)

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Backup-And-Write([string]$Path, [string]$NewText) {
  if ($DryRun) {
    Write-Host "DRY RUN: Would write $Path"
    return
  }
  $backup = "$Path.bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
  Copy-Item -Path $Path -Destination $backup -Force
  Write-Utf8NoBom -Path $Path -Text $NewText
  Write-Host "Patched: $Path"
  Write-Host "Backup : $backup"
}

function Fix-Mojibake([string]$Text) {
  $map = [ordered]@{
    # Common mojibake sequences -> ASCII-safe
    "Ã—" = "x"
    "â€“" = "-"
    "â€”" = "-"
    "â€¦" = "..."
    "â‰ˆ" = "~="
    "â€œ" = '"'
    "â€" = '"'
    "â€˜" = "'"
    "â€™" = "'"
    "Â "  = " "
    "Â¢"  = "c"
    "Â·"  = " - "
  }
  foreach ($k in $map.Keys) { $Text = $Text.Replace($k, $map[$k]) }

  # Normalize a few symbols so you don't fight encoding again
  $Text = $Text.Replace("¢","c")
  $Text = $Text.Replace("×","x")
  $Text = $Text.Replace("–","-")
  $Text = $Text.Replace("—","-")

  return $Text
}

# -------- Overwrite BacktestEngine.js --------
$enginePath = Join-Path $RepoRoot "src\components\BacktestEngine.js"
if (-not (Test-Path $enginePath)) {
  Write-Error "Cannot find: $enginePath"
  exit 1
}

$engineNew = @'
"use client";
import { useMemo, useState } from "react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid,
  ResponsiveContainer, Cell, LineChart, Line,
} from "recharts";

const PRICE_CENTS = Array.from({ length: 99 }, (_, i) => i + 1); // 1..99
const TIME_SECS = Array.from({ length: 301 }, (_, i) => i);      // 0..300

function clamp(n, lo, hi) {
  const x = Number(n);
  if (!Number.isFinite(x)) return lo;
  return Math.min(hi, Math.max(lo, x));
}

export default function BacktestEngine({ sessions }) {
  const [side, setSide] = useState("UP");          // UP, DOWN, BOTH
  const [priceMin, setPriceMin] = useState(0.01);  // default per request
  const [priceMax, setPriceMax] = useState(0.99);  // default per request
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);

  const [view, setView] = useState("bestCombos"); // bestCombos | price | time
  const [topN, setTopN] = useState(25);
  const [minSamples, setMinSamples] = useState(10);

  const [results, setResults] = useState(null);

  const normalized = useMemo(() => {
    const pMin = clamp(Math.min(priceMin, priceMax), 0, 1);
    const pMax = clamp(Math.max(priceMin, priceMax), 0, 1);
    const eMin = clamp(Math.min(elapsedMin, elapsedMax), 0, 300);
    const eMax = clamp(Math.max(elapsedMin, elapsedMax), 0, 300);

    return {
      pMin, pMax, eMin, eMax,
      topN: clamp(topN, 5, 200),
      minSamples: clamp(minSamples, 1, 1000000),
    };
  }, [priceMin, priceMax, elapsedMin, elapsedMax, topN, minSamples]);

  const runBacktest = () => {
    const sides = side === "BOTH" ? ["UP","DOWN"] : [side];
    const trades = [];

    for (const session of sessions) {
      if (!session?.outcome) continue;

      for (const point of session.priceHistory ?? []) {
        const el = point?.elapsed ?? 0;
        if (el < normalized.eMin || el > normalized.eMax) continue;

        for (const s of sides) {
          const price = s === "DOWN" ? point?.down : point?.up;
          if (price == null) continue;
          if (price < normalized.pMin || price > normalized.pMax) continue;

          const win = session.outcome === s;
          trades.push({
            slug: session.slug ?? "?",
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
      setResults({ trades: [], summary: null, chartPrice: [], chartTime: [], bestCombos: [] });
      return;
    }

    const wins = trades.reduce((acc, t) => acc + (t.win ? 1 : 0), 0);
    const winRate = wins / trades.length;

    // --- 1c chart ---
    const byCent = new Array(100).fill(null).map(() => ({ wins: 0, total: 0 }));
    // --- 1s chart ---
    const bySec = new Array(301).fill(null).map(() => ({ wins: 0, total: 0 }));
    // --- combo stats (sec + cent) ---
    const combo = new Map(); // key = sec*100 + cent

    for (const t of trades) {
      const cent = clamp(Math.round(t.price * 100), 0, 100);
      const sec = clamp(Math.round(t.elapsed), 0, 300);

      if (cent >= 1 && cent <= 99) {
        byCent[cent].total++; if (t.win) byCent[cent].wins++;
        const key = (sec * 100) + cent;
        const cur = combo.get(key) ?? { wins: 0, total: 0, sec, cent };
        cur.total++; if (t.win) cur.wins++;
        combo.set(key, cur);
      }

      bySec[sec].total++; if (t.win) bySec[sec].wins++;
    }

    const chartPrice = PRICE_CENTS.map((c) => {
      const { wins, total } = byCent[c];
      return {
        cent: c,
        label: `${c}c`,
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

    const bestCombos = Array.from(combo.values())
      .filter(x => x.total >= normalized.minSamples)
      .map(x => ({
        sec: x.sec,
        cent: x.cent,
        label: `${x.cent}c @ ${x.sec}s`,
        wins: x.wins,
        total: x.total,
        winRate: +((x.wins / x.total) * 100).toFixed(1),
      }))
      .sort((a, b) => (b.winRate - a.winRate) || (b.total - a.total) || (a.sec - b.sec) || (a.cent - b.cent))
      .slice(0, normalized.topN);

    setResults({
      trades,
      summary: { total: trades.length, wins, winRate },
      chartPrice,
      chartTime,
      bestCombos,
      params: { ...normalized, side },
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
                <button
                  key={s}
                  onClick={() => setSide(s)}
                  className={`flex-1 py-2 rounded-lg font-bold text-sm transition ${
                    side===s
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
            <label className="text-xs text-[var(--text2)] block mb-1">Output View</label>
            <div className="flex gap-2">
              {[["bestCombos","Best Price+Time"],["price","Entry Price (1c)"],["time","Elapsed Time (1s)"]].map(([v,l]) => (
                <button
                  key={v}
                  onClick={() => setView(v)}
                  className={`flex-1 py-2 rounded-lg text-sm transition ${
                    view===v
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
            <p className="text-xs text-[var(--text3)] mt-1">Default is 0.01-0.99 to show full domain</p>
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
            <label className="text-xs text-[var(--text2)] block mb-1">Top N combos (for Best Price+Time)</label>
            <input
              type="number" min="5" max="200" step="1" value={topN}
              onChange={e => setTopN(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]"
            />
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Min samples per combo (n)</label>
            <input
              type="number" min="1" step="1" value={minSamples}
              onChange={e => setMinSamples(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]"
            />
            <p className="text-xs text-[var(--text3)] mt-1">Increase this to avoid "lucky" 1-of-1 cells.</p>
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
                  value={`${(results.summary.winRate*100).toFixed(1)}%`}
                  color={results.summary.winRate >= 0.5 ? "text-green-600 dark:text-green-400" : "text-red-600 dark:text-red-400"}
                />
              </div>

              {view === "bestCombos" && (
                <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm" style={{ height: 520 }}>
                  <p className="text-xs text-[var(--text2)] mb-3">
                    Best Price+Time combos (sorted highest to lowest win rate)
                  </p>
                  <ResponsiveContainer width="100%" height="92%">
                    <BarChart data={results.bestCombos} layout="vertical" margin={{ left: 20, right: 20, top: 10, bottom: 10 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                      <XAxis type="number" domain={[0, 100]} tickFormatter={(v) => `${v}%`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                      <YAxis type="category" dataKey="label" width={120} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                      <Tooltip
                        formatter={(v, n, ctx) => {
                          const p = ctx?.payload;
                          if (!p) return [v, n];
                          return [`${p.winRate}% (wins=${p.wins}, n=${p.total})`, "Win Rate"];
                        }}
                        contentStyle={{ background:"var(--card)", border:"1px solid var(--border)", borderRadius:8 }}
                      />
                      <Bar dataKey="winRate" radius={[4,4,4,4]}>
                        {results.bestCombos.map((e, i) => (
                          <Cell key={i} fill={e.winRate >= 50 ? "#16a34a" : "#dc2626"} />
                        ))}
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>
                  {results.bestCombos.length === 0 && (
                    <p className="text-xs text-[var(--text3)] mt-3">
                      No combos met min samples. Lower min samples (n) or widen your filters.
                    </p>
                  )}
                </div>
              )}

              {view === "price" && (
                <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm" style={{ height: 340 }}>
                  <p className="text-xs text-[var(--text2)] mb-3">Win Rate by Entry Price (1c increments)</p>
                  <ResponsiveContainer width="100%" height="90%">
                    <BarChart data={results.chartPrice}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                      <XAxis dataKey="cent" tickFormatter={(v) => `${v}c`} interval={9} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                      <YAxis domain={[0,100]} tickFormatter={(v) => `${v}%`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                      <Tooltip
                        formatter={(v, n, ctx) => {
                          const p = ctx?.payload;
                          if (!p) return [v, n];
                          return [p.total ? `${p.winRate}% (n=${p.total})` : "no data", "Win Rate"];
                        }}
                        labelFormatter={(cent) => `${cent}c`}
                        contentStyle={{ background:"var(--card)", border:"1px solid var(--border)", borderRadius:8 }}
                      />
                      <Bar dataKey="winRate" radius={[3,3,0,0]}>
                        {results.chartPrice.map((e,i) => (
                          <Cell key={i} fill={e.winRate == null ? "rgba(148,163,184,0.25)" : (e.winRate >= 50 ? "#16a34a" : "#dc2626")} />
                        ))}
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              )}

              {view === "time" && (
                <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm" style={{ height: 340 }}>
                  <p className="text-xs text-[var(--text2)] mb-3">Win Rate by Elapsed Time (1s increments)</p>
                  <ResponsiveContainer width="100%" height="90%">
                    <LineChart data={results.chartTime}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                      <XAxis dataKey="sec" tickFormatter={(v) => `${v}s`} interval={29} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                      <YAxis domain={[0,100]} tickFormatter={(v) => `${v}%`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                      <Tooltip
                        formatter={(v, n, ctx) => {
                          const p = ctx?.payload;
                          if (!p) return [v, n];
                          return [p.total ? `${p.winRate}% (n=${p.total})` : "no data", "Win Rate"];
                        }}
                        labelFormatter={(sec) => `${sec}s`}
                        contentStyle={{ background:"var(--card)", border:"1px solid var(--border)", borderRadius:8 }}
                      />
                      <Line type="monotone" dataKey="winRate" stroke="#6366f1" dot={false} connectNulls={false} strokeWidth={2} />
                    </LineChart>
                  </ResponsiveContainer>
                </div>
              )}
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
'@

$engineNew = Fix-Mojibake $engineNew
Backup-And-Write -Path $enginePath -NewText $engineNew

# -------- Mojibake-fix pass on other UI files --------
$other = @(
  "src\components\LiveTracker.js",
  "src\app\backtest\page.js",
  "src\app\page.js"
) | ForEach-Object { Join-Path $RepoRoot $_ }

foreach ($p in $other) {
  if (-not (Test-Path $p)) { continue }
  $orig = Get-Content -Path $p -Raw -Encoding UTF8
  $fixed = Fix-Mojibake $orig
  if ($fixed -ne $orig) {
    Backup-And-Write -Path $p -NewText $fixed
  } elseif ($DryRun) {
    Write-Host "DRY RUN: No mojibake changes needed in $p"
  }
}
