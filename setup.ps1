<# patch-ui-heatmap-hover-and-mojibake.ps1
   - Replaces BacktestEngine.js with a heatmap that supports hover tooltip via mouse position.
   - Fixes common mojibake sequences across tracker/backtest files.
   - Writes files as UTF-8 (no BOM) and creates timestamped backups.

   Usage:
     .\patch-ui-heatmap-hover-and-mojibake.ps1
     .\patch-ui-heatmap-hover-and-mojibake.ps1 -DryRun
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
  # Replace the common garbled sequences + normalize to ASCII where helpful.
  $map = [ordered]@{
    "Ã—" = "x"     # multiplication sign mojibake
    "â€“" = "-"     # en dash mojibake
    "â€”" = "-"     # em dash mojibake
    "â€¦" = "..."   # ellipsis mojibake
    "â‰ˆ" = "~="    # approx mojibake

    "â€œ" = '"'     # opening quote mojibake
    "â€" = '"'     # closing quote mojibake
    "â€˜" = "'"     # opening apostrophe mojibake
    "â€™" = "'"     # closing apostrophe mojibake

    "Â "  = " "     # NBSP mojibake
    "Â·"  = " - "   # middot mojibake -> ASCII-ish separator
    "Â¢"  = "c"     # cents mojibake -> ASCII
  }

  foreach ($k in $map.Keys) { $Text = $Text.Replace($k, $map[$k]) }

  # Also normalize a few legit-but-non-ASCII characters to avoid future encoding issues
  $Text = $Text.Replace("¢", "c")
  $Text = $Text.Replace("✓", "W")
  $Text = $Text.Replace("✗", "L")
  $Text = $Text.Replace("●", "*")
  $Text = $Text.Replace("○", "o")
  $Text = $Text.Replace("▲", "^")
  $Text = $Text.Replace("▼", "v")

  return $Text
}

# --- 1) Overwrite BacktestEngine.js with hoverable heatmap + cleaner strings ---
$enginePath = Join-Path $RepoRoot "src\components\BacktestEngine.js"
if (-not (Test-Path $enginePath)) {
  Write-Error "Cannot find: $enginePath"
  exit 1
}

$engineNew = @'
"use client";
import { useMemo, useRef, useState } from "react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid,
  ResponsiveContainer, Cell, LineChart, Line
} from "recharts";

const PRICE_CENTS = Array.from({ length: 99 }, (_, i) => i + 1); // 1..99
const TIME_SECS = Array.from({ length: 301 }, (_, i) => i);      // 0..300

function clamp(n, lo, hi) {
  const x = Number(n);
  if (!Number.isFinite(x)) return lo;
  return Math.min(hi, Math.max(lo, x));
}

function colorForWinRate01(wr) {
  // wr: 0..1, neutral around 0.5
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

  // Heatmap hover
  const heatWrapRef = useRef(null);
  const [hover, setHover] = useState(null); // {sec, cent, wins, total, winRate, x, y}

  const normalized = useMemo(() => {
    const pMin = clamp(Math.min(priceMin, priceMax), 0, 1);
    const pMax = clamp(Math.max(priceMin, priceMax), 0, 1);
    const eMin = clamp(Math.min(elapsedMin, elapsedMax), 0, 300);
    const eMax = clamp(Math.max(elapsedMin, elapsedMax), 0, 300);
    return { pMin, pMax, eMin, eMax };
  }, [priceMin, priceMax, elapsedMin, elapsedMax]);

  const runBacktest = () => {
    const trades = [];
    const sides = side === "BOTH" ? ["UP", "DOWN"] : [side];

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
          trades.push({ slug: session.slug, elapsed: el, price, side: s, outcome: session.outcome, win });
        }
      }
    }

    if (!trades.length) {
      setResults({ trades: [], summary: null, chartPrice: [], chartTime: [], heat: new Map() });
      return;
    }

    const wins = trades.reduce((acc, t) => acc + (t.win ? 1 : 0), 0);
    const winRate = wins / trades.length;

    const byCent = new Array(100).fill(null).map(() => ({ wins: 0, total: 0 }));
    const bySec = new Array(301).fill(null).map(() => ({ wins: 0, total: 0 }));
    const heat = new Map(); // key = sec*100 + cent

    for (const t of trades) {
      const cent = clamp(Math.round(t.price * 100), 0, 100);
      const sec = clamp(Math.round(t.elapsed), 0, 300);

      if (cent >= 1 && cent <= 99) {
        byCent[cent].total++; if (t.win) byCent[cent].wins++;
      }
      bySec[sec].total++; if (t.win) bySec[sec].wins++;

      if (cent >= 1 && cent <= 99) {
        const key = (sec * 100) + cent;
        const cur = heat.get(key) ?? { wins: 0, total: 0 };
        cur.total++; if (t.win) cur.wins++;
        heat.set(key, cur);
      }
    }

    const chartPrice = PRICE_CENTS.map((c) => {
      const { wins, total } = byCent[c];
      return { cent: c, label: `${c}c`, winRate: total ? +((wins / total) * 100).toFixed(1) : null, wins, total };
    });

    const chartTime = TIME_SECS.map((s) => {
      const { wins, total } = bySec[s];
      return { sec: s, label: `${s}s`, winRate: total ? +((wins / total) * 100).toFixed(1) : null, wins, total };
    });

    setResults({
      trades,
      summary: { total: trades.length, wins, winRate },
      chartPrice,
      chartTime,
      heat,
      params: { ...normalized, side }
    });
  };

  const onHeatMove = (e) => {
    if (!results?.heat || !heatWrapRef.current) return;
    const r = heatWrapRef.current.getBoundingClientRect();
    const px = e.clientX - r.left;
    const py = e.clientY - r.top;

    if (px < 0 || py < 0 || px > r.width || py > r.height) { setHover(null); return; }

    // Map pixel -> grid coordinate (sec: 0..300, cent: 1..99)
    const sec = clamp(Math.floor((px / r.width) * 301), 0, 300);
    const cent = clamp(99 - Math.floor((py / r.height) * 99), 1, 99);

    const key = (sec * 100) + cent;
    const cell = results.heat.get(key) ?? { wins: 0, total: 0 };
    const wr01 = cell.total ? (cell.wins / cell.total) : null;

    setHover({
      sec, cent,
      wins: cell.wins, total: cell.total,
      winRate: wr01 != null ? +(wr01 * 100).toFixed(1) : null,
      x: px, y: py
    });
  };

  const onHeatLeave = () => setHover(null);

  return (
    <div className="space-y-6">
      <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-5 shadow-sm space-y-4">
        <h2 className="text-lg font-bold">Backtest Configuration</h2>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Buy Side</label>
            <div className="flex gap-2">
              {["UP","DOWN","BOTH"].map(s => (
                <button key={s} onClick={() => setSide(s)}
                  className={`flex-1 py-2 rounded-lg font-bold text-sm transition ${
                    side===s ? "bg-indigo-600 text-white" : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
                  }`}>{s}</button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Chart View</label>
            <div className="flex gap-2">
              {[
                ["priceRange","Entry Price (1c)"],
                ["elapsedRange","Elapsed Time (1s)"],
                ["priceTime","Price x Time (Heatmap)"],
              ].map(([v,l]) => (
                <button key={v} onClick={() => setGroupBy(v)}
                  className={`flex-1 py-2 rounded-lg text-sm transition ${
                    groupBy===v ? "bg-indigo-600 text-white" : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
                  }`}>{l}</button>
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
            <p className="text-xs text-[var(--text3)] mt-1">Tip: set 0.01-0.99 to show full domain</p>
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

              {groupBy === "priceRange" && (
                <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm" style={{ height: 340 }}>
                  <p className="text-xs text-[var(--text2)] mb-3">Win Rate by Entry Price (1c increments)</p>
                  <ResponsiveContainer width="100%" height="90%">
                    <BarChart data={results.chartPrice}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                      <XAxis dataKey="cent" tickFormatter={(v) => `${v}c`} interval={0} angle={-60} textAnchor="end" height={80} stroke="#94a3b8" tick={{ fontSize: 10 }} />
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

              {groupBy === "elapsedRange" && (
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

              {groupBy === "priceTime" && (
                <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm">
                  <p className="text-xs text-[var(--text2)] mb-2">Win Rate Heatmap (Price x Time)</p>
                  <p className="text-xs text-[var(--text3)] mb-3">
                    Hover anywhere on the heatmap to see: elapsed seconds, entry price (cents), win rate, and sample size.
                  </p>

                  <div
                    ref={heatWrapRef}
                    onMouseMove={onHeatMove}
                    onMouseLeave={onHeatLeave}
                    className="relative w-full border border-[var(--border)] rounded-lg overflow-hidden"
                    style={{ height: 420 }}
                  >
                    {/* Render heat cells in an SVG, but use container mouse position for hover (reliable). */}
                    <svg viewBox="0 0 301 99" preserveAspectRatio="none" width="100%" height="100%">
                      <rect x="0" y="0" width="301" height="99" fill="rgba(148,163,184,0.08)" />
                      {Array.from(results.heat.entries()).map(([key, v]) => {
                        const sec = Math.floor(key / 100);
                        const cent = key % 100;
                        if (cent < 1 || cent > 99) return null;
                        const wr01 = v.total ? (v.wins / v.total) : 0.5;
                        const fill = colorForWinRate01(wr01);
                        const y = (99 - cent);
                        return <rect key={key} x={sec} y={y} width="1" height="1" fill={fill} opacity="0.95" />;
                      })}
                    </svg>

                    {/* Hover tooltip */}
                    {hover && (
                      <div
                        className="absolute pointer-events-none"
                        style={{
                          left: Math.min(Math.max(hover.x + 12, 8), (heatWrapRef.current?.clientWidth ?? 0) - 180),
                          top: Math.min(Math.max(hover.y + 12, 8), (heatWrapRef.current?.clientHeight ?? 0) - 90),
                          width: 180
                        }}
                      >
                        <div className="rounded-lg border border-[var(--border)] bg-[var(--card)] shadow-lg px-3 py-2 text-xs text-[var(--text1)]">
                          <div className="font-semibold mb-1">t={hover.sec}s, price={hover.cent}c</div>
                          <div>Win rate: {hover.winRate != null ? `${hover.winRate}%` : "no data"}</div>
                          <div>Samples: n={hover.total}, wins={hover.wins}</div>
                        </div>
                      </div>
                    )}
                  </div>

                  <div className="mt-3 text-xs text-[var(--text3)] flex items-center gap-3">
                    <span>0%</span>
                    <div className="flex-1 h-2 rounded" style={{ background: "linear-gradient(90deg, #dc2626, #eab308, #16a34a)" }} />
                    <span>100%</span>
                  </div>
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

# Ensure our new engine file has no mojibake sequences either
$engineNew = Fix-Mojibake $engineNew
Backup-And-Write -Path $enginePath -NewText $engineNew

# --- 2) Fix mojibake in tracker/backtest pages/components ---
$otherFiles = @(
  "src\components\LiveTracker.js",
  "src\app\backtest\page.js",
  "src\app\page.js"
) | ForEach-Object { Join-Path $RepoRoot $_ }

foreach ($p in $otherFiles) {
  if (-not (Test-Path $p)) { continue }
  $content = Get-Content -Path $p -Raw -Encoding UTF8
  $fixed = Fix-Mojibake $content
  if ($fixed -ne $content) {
    Backup-And-Write -Path $p -NewText $fixed
  } elseif ($DryRun) {
    Write-Host "DRY RUN: No mojibake changes needed in $p"
  }
}
