param(
  [string]$RepoRoot = "",
  [switch]$DryRun
)

function Find-RepoRoot([string]$StartDir) {
  $dir = (Resolve-Path $StartDir).Path
  while ($true) {
    if (Test-Path (Join-Path $dir "package.json")) { return $dir }
    $parent = Split-Path $dir -Parent
    if ($parent -eq $dir -or [string]::IsNullOrWhiteSpace($parent)) { return $null }
    $dir = $parent
  }
}

function Backup-File([string]$Path) {
  if ($DryRun) { return $null }
  $bak = "$Path.bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
  Copy-Item -Path $Path -Destination $bak -Force
  return $bak
}

function Read-TextUtf8([string]$Path) {
  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-TextUtf8NoBom([string]$Path, [string]$Text) {
  if ($DryRun) { Write-Host "DRY RUN: Would write $Path"; return }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# --- Resolve repo root ---
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Find-RepoRoot (Get-Location).Path
} else {
  $RepoRoot = Find-RepoRoot $RepoRoot
}
if (-not $RepoRoot) { throw "Could not find repo root (package.json). Run from repo root." }
Write-Host "RepoRoot: $RepoRoot"

# --- Locate BacktestEngine.js (prefer src/components) ---
$engineFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -Filter "BacktestEngine.js" -ErrorAction SilentlyContinue
if (-not $engineFiles -or $engineFiles.Count -eq 0) { throw "No BacktestEngine.js found." }

$engine = $engineFiles | Where-Object { $_.FullName -match '[\\/]src[\\/]components[\\/]' } | Select-Object -First 1
if (-not $engine) { $engine = $engineFiles | Select-Object -First 1 }

Write-Host "Target BacktestEngine.js: $($engine.FullName)"

# --- New BacktestEngine implementation with your requested defaults ---
$engineText = @'
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

// stake=$10, buy at price p, shares = stake/p
// win -> profit = shares - stake ; lose -> -stake
function perBet(stake, price01) {
  const s = Math.max(0, Number(stake) || 0);
  const p = clamp(price01, 0.01, 0.99);
  const shares = s / p;
  return {
    profitIfWinEach: shares - s,
    lossIfLoseEach: -s
  };
}

// delta = stake*(1/current - 1/start)
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
  const [buySide, setBuySide] = useState("BOTH"); // UP, DOWN, BOTH

  // Defaults requested earlier
  const [priceMin, setPriceMin] = useState(0.01);
  const [priceMax, setPriceMax] = useState(0.99);

  // Remaining time filter (more intuitive than elapsed)
  const [remainingMin, setRemainingMin] = useState(0);
  const [remainingMax, setRemainingMax] = useState(WINDOW_SECS);

  // Default: 1 cent price buckets
  const [priceStepCents, setPriceStepCents] = useState(1);
  const [timeStepSecs, setTimeStepSecs] = useState(5);

  // Defaults you asked for (delta grouping enabled)
  const [useDeltaBuckets, setUseDeltaBuckets] = useState(true);
  const [deltaStepDollars, setDeltaStepDollars] = useState(10);

  // Defaults you asked for (Realized P/L, Top N, Min samples)
  const [sortBy, setSortBy] = useState("pl"); // winrate | roi | pl | delta
  const [topN, setTopN] = useState(100);
  const [minSamples, setMinSamples] = useState(3);

  const [results, setResults] = useState(null);

  const normalized = useMemo(() => {
    const pMin = clamp(Math.min(priceMin, priceMax), 0, 1);
    const pMax = clamp(Math.max(priceMin, priceMax), 0, 1);

    const rMin = clamp(Math.min(remainingMin, remainingMax), 0, WINDOW_SECS);
    const rMax = clamp(Math.max(remainingMin, remainingMax), 0, WINDOW_SECS);

    const ps = ([1,5,10].includes(Number(priceStepCents)) ? Number(priceStepCents) : 1);
    const ts = ([1,5,10].includes(Number(timeStepSecs)) ? Number(timeStepSecs) : 5);
    const ds = ([5,10,20,50].includes(Number(deltaStepDollars)) ? Number(deltaStepDollars) : 10);

    const s = (["winrate","roi","pl","delta"].includes(sortBy) ? sortBy : "pl");

    return {
      pMin, pMax,
      rMin, rMax,
      ps, ts,
      useDelta: !!useDeltaBuckets,
      ds,
      sortBy: s,
      topN: clamp(topN, 1, 500),
      minSamples: clamp(minSamples, 1, 1000000),
    };
  }, [
    priceMin, priceMax,
    remainingMin, remainingMax,
    priceStepCents, timeStepSecs,
    useDeltaBuckets, deltaStepDollars,
    sortBy, topN, minSamples
  ]);

  const runBacktest = () => {
    const sides = buySide === "BOTH" ? ["UP", "DOWN"] : [buySide];

    const cells = new Map();

    for (const session of sessions ?? []) {
      const outcome = session?.outcome;
      if (!outcome) continue;

      const points = Array.isArray(session?.priceHistory) ? session.priceHistory : [];
      if (!points.length) continue;

      // "Price To Beat" = earliest elapsed non-null price per side
      let startUp = null, startUpEl = Infinity;
      let startDown = null, startDownEl = Infinity;

      for (const p of points) {
        const e = Number(p?.elapsed);
        const el = Number.isFinite(e) ? e : Infinity;
        if (p?.up != null && el < startUpEl) { startUp = Number(p.up); startUpEl = el; }
        if (p?.down != null && el < startDownEl) { startDown = Number(p.down); startDownEl = el; }
      }

      // If only one side exists, derive the other.
      if (Number.isFinite(startUp) && !Number.isFinite(startDown)) startDown = 1 - startUp;
      if (Number.isFinite(startDown) && !Number.isFinite(startUp)) startUp = 1 - startDown;

      const hasStartUp = Number.isFinite(startUp) && startUp > 0.0001 && startUp < 0.9999;
      const hasStartDown = Number.isFinite(startDown) && startDown > 0.0001 && startDown < 0.9999;

      for (const point of points) {
        const secElapsed = clamp(Math.round(point?.elapsed ?? 0), 0, WINDOW_SECS);
        const secRemaining = clamp(WINDOW_SECS - secElapsed, 0, WINDOW_SECS);
        if (secRemaining < normalized.rMin || secRemaining > normalized.rMax) continue;

        for (const s of sides) {
          const price = (s === "DOWN") ? point?.down : point?.up;
          if (price == null) continue;
          if (price < normalized.pMin || price > normalized.pMax) continue;

          const cent = clamp(Math.round(Number(price) * 100), 0, 100);
          if (cent < 1 || cent > 99) continue;

          const centStart = (Math.floor((cent - 1) / normalized.ps) * normalized.ps) + 1;
          const centEnd = Math.min(99, centStart + normalized.ps - 1);

          const remStart = Math.floor(secRemaining / normalized.ts) * normalized.ts;
          const remEnd = Math.min(WINDOW_SECS, remStart + normalized.ts - 1);

          const win = (outcome === s);

          const startPrice = (s === "DOWN") ? startDown : startUp;
          const hasStart = (s === "DOWN") ? hasStartDown : hasStartUp;

          const d = hasStart ? deltaProfitIfWin(STAKE, startPrice, Number(price)) : null;
          const b = (d != null) ? bucketDelta(d, normalized.ds) : null;

          const key = (normalized.useDelta && b)
            ? `${s}|${remStart}|${centStart}|${b.bs}`
            : `${s}|${remStart}|${centStart}`;

          const cur = cells.get(key) ?? {
            side: s,
            remStart, remEnd,
            centStart, centEnd,

            deltaBucketLabel: b ? b.label : "missing start",
            deltaBucketStart: b ? b.bs : 0,

            wins: 0,
            total: 0,
            sumPrice01: 0,

            sumDelta: 0,
            deltaCount: 0,

            sumStartPrice: 0,
            startCount: 0
          };

          cur.total++;
          if (win) cur.wins++;
          cur.sumPrice01 += Number(price);

          if (d != null) { cur.sumDelta += d; cur.deltaCount++; }
          if (hasStart) { cur.sumStartPrice += Number(startPrice); cur.startCount++; }

          if (b && !normalized.useDelta) {
            cur.deltaBucketLabel = b.label;
            cur.deltaBucketStart = b.bs;
          }

          cells.set(key, cur);
        }
      }
    }

    const rows = [...cells.values()]
      .filter(x => x.total >= normalized.minSamples)
      .map(x => {
        const winRate01 = x.wins / x.total;
        const winRatePct = +(winRate01 * 100).toFixed(1);

        const avgPrice01 = x.sumPrice01 / x.total;
        const { profitIfWinEach, lossIfLoseEach } = perBet(STAKE, avgPrice01);

        const realizedPL = +((profitIfWinEach * x.wins) + (lossIfLoseEach * (x.total - x.wins))).toFixed(2);
        const realizedROI = +((realizedPL / (STAKE * x.total)) * 100).toFixed(2);

        const avgDelta = (x.deltaCount > 0) ? (x.sumDelta / x.deltaCount) : null;
        const avgDeltaLabel = (avgDelta == null) ? "missing start" : `$${avgDelta.toFixed(2)}`;

        const avgStartPrice01 = (x.startCount > 0) ? (x.sumStartPrice / x.startCount) : null;

        const priceLabel = fmtPriceRange(x.centStart, x.centEnd);
        const timeLabel = (x.remStart === x.remEnd) ? fmtMMSS(x.remStart) : `${fmtMMSS(x.remStart)}-${fmtMMSS(x.remEnd)}`;

        let metricVal = winRatePct;
        let metricLabel = "WinRate";
        if (normalized.sortBy === "roi") { metricVal = realizedROI; metricLabel = "Realized ROI%"; }
        if (normalized.sortBy === "pl") { metricVal = realizedPL; metricLabel = "Realized P/L"; }
        if (normalized.sortBy === "delta") { metricVal = (avgDelta == null) ? -999999 : +avgDelta.toFixed(2); metricLabel = "Avg Delta($)"; }

        return {
          ...x,
          winRate: winRatePct,
          avgPriceLabel: fmtPrice01(avgPrice01),
          avgStartPriceLabel: (avgStartPrice01 == null) ? "missing" : fmtPrice01(avgStartPrice01),
          timeLabel,
          priceLabel,
          avgDeltaLabel,
          realizedPL,
          realizedROI,
          metricVal,
          metricLabel,
          rowLabel: normalized.useDelta
            ? `${x.side} ${priceLabel} @ ${timeLabel} | d=${x.deltaBucketLabel}`
            : `${x.side} ${priceLabel} @ ${timeLabel}`
        };
      });

    rows.sort((a, b) => {
      if (normalized.sortBy === "roi") return (b.realizedROI - a.realizedROI) || (b.winRate - a.winRate) || (b.total - a.total);
      if (normalized.sortBy === "pl") return (b.realizedPL - a.realizedPL) || (b.winRate - a.winRate) || (b.total - a.total);
      if (normalized.sortBy === "delta") return (b.metricVal - a.metricVal) || (b.winRate - a.winRate) || (b.total - a.total);
      return (b.winRate - a.winRate) || (b.total - a.total);
    });

    setResults({
      rows: rows.slice(0, normalized.topN),
      chartRows: rows.slice(0, Math.min(30, normalized.topN)),
      debug: { cells: cells.size }
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
            <p className="text-xs text-[var(--text3)] mt-1">Default is 0.01 to 0.99.</p>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Time Remaining Range (seconds 0-300)</label>
            <div className="flex gap-2 items-center">
              <input type="number" min="0" max="300" step="1" value={remainingMin}
                onChange={e => setRemainingMin(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]" />
              <span className="text-[var(--text3)]">to</span>
              <input type="number" min="0" max="300" step="1" value={remainingMax}
                onChange={e => setRemainingMax(+e.target.value)}
                className="w-24 bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-1.5 text-sm text-[var(--text1)]" />
            </div>
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

          <div className="flex items-center gap-2">
            <input type="checkbox" checked={useDeltaBuckets} onChange={e => setUseDeltaBuckets(e.target.checked)} />
            <label className="text-xs text-[var(--text2)]">Group by Delta Bucket (PriceToBeat vs current)</label>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Delta bucket size ($)</label>
            <select value={deltaStepDollars} onChange={e => setDeltaStepDollars(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]">
              <option value={5}>$5</option>
              <option value={10}>$10</option>
              <option value={20}>$20</option>
              <option value={50}>$50</option>
            </select>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Sort best combos by</label>
            <select value={sortBy} onChange={e => setSortBy(e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]">
              <option value="winrate">WinRate</option>
              <option value="roi">Realized ROI%</option>
              <option value="pl">Realized P/L</option>
              <option value="delta">Avg Delta($)</option>
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

        <button onClick={runBacktest} disabled={!sessions?.length}
          className="w-full py-3 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 text-white rounded-xl font-bold text-base">
          Run Backtest ({sessions?.length ?? 0} session{(sessions?.length ?? 0) !== 1 ? "s" : ""} loaded)
        </button>
      </div>

      {results && (
        <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm space-y-4">
          <div className="bg-[var(--bg2)] border border-[var(--border)] rounded-xl p-3" style={{ height: chartHeight }}>
            <p className="text-xs text-[var(--text2)] mb-2">
              Top combos chart (metric: {results.chartRows?.[0]?.metricLabel ?? "Realized P/L"})
            </p>
            <ResponsiveContainer width="100%" height="92%">
              <BarChart data={(results.chartRows ?? []).slice().reverse()} layout="vertical" margin={{ left: 10, right: 20, top: 10, bottom: 10 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis type="number" stroke="#94a3b8" tick={{ fontSize: 11 }} />
                <YAxis type="category" dataKey="rowLabel" width={320} stroke="#94a3b8" tick={{ fontSize: 10 }} />
                <Tooltip
                  formatter={(v, n, ctx) => {
                    const p = ctx?.payload;
                    if (!p) return [v, n];
                    return [
                      `${p.metricLabel}=${p.metricVal}, winRate=${p.winRate}%, total=${p.total}, ROI=${p.realizedROI}%`,
                      "Cell"
                    ];
                  }}
                  contentStyle={{ background: "var(--card)", border: "1px solid var(--border)", borderRadius: 8 }}
                />
                <Bar dataKey="metricVal" radius={[4,4,4,4]}>
                  {(results.chartRows ?? []).slice().reverse().map((r, i) => {
                    const t = normalized.sortBy === "winrate"
                      ? (r.winRate / 100)
                      : normalized.sortBy === "roi"
                        ? clamp((r.realizedROI + 50) / 100, 0, 1)
                        : normalized.sortBy === "pl"
                          ? clamp((r.realizedPL + 50) / 100, 0, 1)
                          : 0.5;
                    return <Cell key={i} fill={colorRamp(t)} />;
                  })}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-xs text-[var(--text1)]">
              <thead>
                <tr className="text-[var(--text3)] border-b border-[var(--border)]">
                  <th className="text-left py-1 pr-4">Side</th>
                  <th className="text-right pr-4">Price bucket</th>
                  <th className="text-right pr-4">Avg price</th>
                  <th className="text-right pr-4">Start price</th>
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
                    <td className="text-right pr-4">{r.avgStartPriceLabel}</td>
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

          {results?.rows?.length === 0 && (
            <div className="bg-[var(--bg2)] border border-[var(--border)] rounded-xl p-4 text-sm text-[var(--text3)]">
              No matching cells. Widen filters or lower min samples.
            </div>
          )}
        </div>
      )}
    </div>
  );
}
'@

# --- Write/replace BacktestEngine.js ---
$bak = Backup-File $engine.FullName
Write-Host "Backup: $bak"
Write-TextUtf8NoBom $engine.FullName $engineText
Write-Host "Wrote upgraded BacktestEngine.js"

# --- Auto-click "Load from this Browser" after 3 seconds on Backtest page ---
# This searches for any JS/TS file that contains that exact text and injects an attribute + a useEffect click.
$codeFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -Include *.js,*.jsx,*.ts,*.tsx -ErrorAction SilentlyContinue
$found = $false

foreach ($cf in $codeFiles) {
  $p = $cf.FullName
  $t = $null
  try { $t = Read-TextUtf8 $p } catch { continue }

  if ($t -notlike '*Load from this Browser*') { continue }
  $found = $true

  $orig = $t

  if ($t -notmatch 'data-auto-load\s*=\s*"browser"') {
    $t = [regex]::Replace(
      $t,
      '(<button\b[^>]*)(>)\s*Load from this Browser',
      '$1 data-auto-load="browser"$2Load from this Browser',
      [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
  }

  if ($t -match 'import\s*\{\s*[^}]*\}\s*from\s*["'']react["'']\s*;') {
    $t = [regex]::Replace(
      $t,
      'import\s*\{\s*([^}]*)\s*\}\s*from\s*["'']react["'']\s*;',
      {
        param($m)
        $inside = $m.Groups[1].Value
        if ($inside -match '(^|,)\s*useEffect\s*(,|$)') { return $m.Value }
        return 'import { ' + $inside.Trim() + ', useEffect } from "react";'
      },
      [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
  }

  if ($t -notmatch 'PM_AUTOLOAD_BROWSER_BTN') {
    $inject = @'
  // PM_AUTOLOAD_BROWSER_BTN: auto-click "Load from this Browser" after 3s
  useEffect(() => {
    const t = setTimeout(() => {
      try {
        const btn = document.querySelector('button[data-auto-load="browser"]');
        if (btn) btn.click();
      } catch {}
    }, 3000);
    return () => clearTimeout(t);
  }, []);

'@

    $t2 = [regex]::Replace(
      $t,
      '(export\s+default\s+function\s+[A-Za-z0-9_]*\s*\([^)]*\)\s*\{\s*)',
      ('$1' + $inject),
      [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    if ($t2 -ne $t) { $t = $t2 }
    else { Write-Host "WARNING: Could not inject useEffect into $p (default-export function not found)." }
  }

  if ($t -ne $orig) {
    $bak2 = Backup-File $p
    Write-Host "Patched backtest page autoload: $p"
    Write-Host "Backup: $bak2"
    Write-TextUtf8NoBom $p $t
  } else {
    Write-Host "No autoload changes needed: $p"
  }
}

if (-not $found) {
  Write-Host 'WARNING: Did not find any file containing "Load from this Browser". If the button text differs, tell me the exact label.'
}

Write-Host "Done."
