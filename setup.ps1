<# patch-backtest-apply.ps1
   Self-checking patch:
   - Finds repo root by locating package.json (walks upward)
   - Finds BacktestEngine.js in repo (prefers src/components/BacktestEngine.js)
   - Overwrites it with "best combos + what-if" version, default price range 0.01..0.99
   - Fixes mojibake/weird chars in common UI files (ASCII only)
   - Writes UTF-8 (no BOM), makes timestamped backups, and verifies the change

   Usage (recommended):
     powershell -ExecutionPolicy Bypass -File .\patch-backtest-apply.ps1
     powershell -ExecutionPolicy Bypass -File .\patch-backtest-apply.ps1 -RepoRoot "C:\path\to\repo"
#>

param(
  [string]$RepoRoot = "",
  [switch]$DryRun
)

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Backup-And-Write([string]$Path, [string]$NewText) {
  if ($DryRun) {
    Write-Host "DRY RUN: Would write $Path"
    return $true
  }

  $backup = "$Path.bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
  Copy-Item -Path $Path -Destination $backup -Force
  Write-Utf8NoBom -Path $Path -Text $NewText

  Write-Host "Patched: $Path"
  Write-Host "Backup : $backup"
  return $true
}

function Fix-WeirdText([string]$Text) {
  # Mojibake -> ASCII (plus a few non-ASCII -> ASCII)
  $map = [ordered]@{
    "Ã—"  = "x"
    "â€“" = "-"
    "â€”" = "-"
    "â€¦" = "..."
    "â‰ˆ" = "~="
    "â€œ" = '"'
    "â€" = '"'
    "â€˜" = "'"
    "â€™" = "'"
    "Â "  = " "
    "Â·"  = " - "
    "Â¢"  = "c"
    "â—" = "*"   # WS dot mojibake
    "â—‹" = "o"
    "â–²" = "^"
    "â–¼" = "v"
  }
  foreach ($k in $map.Keys) { $Text = $Text.Replace($k, $map[$k]) }

  $Text = $Text.Replace("×","x").Replace("–","-").Replace("—","-")
  $Text = $Text.Replace("¢","c")
  $Text = $Text.Replace("●","*").Replace("○","o").Replace("▲","^").Replace("▼","v")
  $Text = $Text.Replace("✓","OK").Replace("✗","X")
  return $Text
}

function Find-RepoRoot([string]$StartDir) {
  $dir = (Resolve-Path $StartDir).Path
  while ($true) {
    if (Test-Path (Join-Path $dir "package.json")) { return $dir }
    $parent = Split-Path $dir -Parent
    if ($parent -eq $dir -or [string]::IsNullOrWhiteSpace($parent)) { return $null }
    $dir = $parent
  }
}

function Find-BacktestEngine([string]$Root) {
  $preferred = Join-Path $Root "src\components\BacktestEngine.js"
  if (Test-Path $preferred) { return $preferred }

  $candidates = Get-ChildItem -Path $Root -Recurse -File -Filter "BacktestEngine.js" -ErrorAction SilentlyContinue
  if ($candidates.Count -eq 1) { return $candidates[0].FullName }

  # Fallback: find by content
  foreach ($f in $candidates) {
    try {
      $t = Get-Content -Path $f.FullName -Raw -Encoding UTF8
      if ($t -match 'export\s+default\s+function\s+BacktestEngine') { return $f.FullName }
    } catch {}
  }
  return $null
}

# --- Resolve repo root ---
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Find-RepoRoot -StartDir (Get-Location).Path
} else {
  $RepoRoot = Find-RepoRoot -StartDir $RepoRoot
}

if (-not $RepoRoot) {
  Write-Error "Could not locate repo root (package.json). Run from repo root or pass -RepoRoot C:\path\to\repo."
  exit 1
}

Write-Host "RepoRoot: $RepoRoot"

# --- Locate BacktestEngine.js ---
$enginePath = Find-BacktestEngine -Root $RepoRoot
if (-not $enginePath) {
  Write-Error "Could not find BacktestEngine.js under $RepoRoot"
  exit 1
}

Write-Host "BacktestEngine: $enginePath"

# --- New BacktestEngine content (ASCII-only UI) ---
$engineNew = @'
"use client";
import { useMemo, useState } from "react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid,
  ResponsiveContainer, Cell,
} from "recharts";

function clamp(n, lo, hi) {
  const x = Number(n);
  if (!Number.isFinite(x)) return lo;
  return Math.min(hi, Math.max(lo, x));
}

function fmtUsdFromCent(cent) {
  return `$${(cent / 100).toFixed(2)}`;
}

function fmtTime(sec) {
  const s = Math.max(0, Math.min(300, Math.round(sec)));
  const m = Math.floor(s / 60);
  const r = String(s % 60).padStart(2, "0");
  return `${m}m${r}s`;
}

export default function BacktestEngine({ sessions }) {
  // Defaults per request
  const [buySide, setBuySide] = useState("BOTH"); // UP, DOWN, BOTH
  const [priceMin, setPriceMin] = useState(0.01);
  const [priceMax, setPriceMax] = useState(0.99);
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);

  // Rank settings
  const [rankSide, setRankSide] = useState("BOTH"); // UP, DOWN, BOTH
  const [topN, setTopN] = useState(30);
  const [minSamples, setMinSamples] = useState(10);

  // What-if
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
      minSamples: clamp(minSamples, 1, 1000000),
    };
  }, [priceMin, priceMax, elapsedMin, elapsedMax, topN, minSamples]);

  const runBacktest = () => {
    const sides = buySide === "BOTH" ? ["UP", "DOWN"] : [buySide];
    const trades = [];

    // Store exact (sec, cent) stats per side
    const comboBySide = { UP: new Map(), DOWN: new Map() }; // key = sec*100 + cent

    for (const session of sessions) {
      const outcome = session?.outcome;
      if (!outcome) continue;

      const points = Array.isArray(session?.priceHistory) ? session.priceHistory : [];
      for (const point of points) {
        const el = point?.elapsed ?? 0;
        if (el < normalized.eMin || el > normalized.eMax) continue;

        for (const s of sides) {
          const price = s === "DOWN" ? point?.down : point?.up;
          if (price == null) continue;
          if (price < normalized.pMin || price > normalized.pMax) continue;

          const sec = clamp(Math.round(el), 0, 300);
          const cent = clamp(Math.round(price * 100), 0, 100);
          if (cent < 1 || cent > 99) continue;

          const win = outcome === s;

          trades.push({
            slug: session?.slug ?? "?",
            elapsed: sec,
            price,
            side: s,
            outcome,
            win,
          });

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
      setResults({ trades: [], summary: null, bestCombos: [], comboBySide });
      return;
    }

    const wins = trades.reduce((acc, t) => acc + (t.win ? 1 : 0), 0);
    const winRate = wins / trades.length;

    let pool = [];
    if (rankSide === "BOTH") {
      pool = [...comboBySide.UP.values(), ...comboBySide.DOWN.values()];
    } else {
      pool = [...comboBySide[rankSide].values()];
    }

    const bestCombos = pool
      .filter(x => x.total >= normalized.minSamples)
      .map(x => {
        const wr = (x.wins / x.total) * 100;
        const label = (rankSide === "BOTH")
          ? `${x.side} ${fmtUsdFromCent(x.cent)} @ ${fmtTime(x.sec)}`
          : `${fmtUsdFromCent(x.cent)} @ ${fmtTime(x.sec)}`;
        return { label, side: x.side, sec: x.sec, cent: x.cent, wins: x.wins, total: x.total, winRate: +wr.toFixed(1) };
      })
      .sort((a, b) => (b.winRate - a.winRate) || (b.total - a.total) || (a.sec - b.sec) || (a.cent - b.cent))
      .slice(0, normalized.topN);

    setResults({
      trades,
      summary: { total: trades.length, wins, winRate },
      bestCombos,
      comboBySide,
      params: { ...normalized, buySide, rankSide },
    });
  };

  const whatIf = useMemo(() => {
    if (!results?.comboBySide) return null;

    const side = qSide;
    const sec = clamp(Math.round(qElapsed), 0, 300);
    const cent = clamp(Math.round(clamp(qPrice, 0, 1) * 100), 0, 100);

    if (cent < 1 || cent > 99) {
      return { ok: false, msg: "Price must be between 0.01 and 0.99 (after rounding)." };
    }

    const key = (sec * 100) + cent;
    const cell = results.comboBySide[side].get(key);

    if (!cell || !cell.total) {
      return { ok: false, msg: "No samples for that exact price+time. Try a nearby value or widen filters." };
    }

    const wr = (cell.wins / cell.total) * 100;
    const likelyOutcome = (wr >= 50) ? side : (side === "UP" ? "DOWN" : "UP");

    return {
      ok: true,
      side,
      priceStr: fmtUsdFromCent(cent),
      timeStr: fmtTime(sec),
      winRate: +wr.toFixed(1),
      wins: cell.wins,
      total: cell.total,
      likelyOutcome,
    };
  }, [results, qSide, qPrice, qElapsed]);

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
                    buySide===s ? "bg-indigo-600 text-white" : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
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
                    rankSide===s ? "bg-indigo-600 text-white" : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
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
                <SCard label="Win Rate" value={`${(results.summary.winRate*100).toFixed(1)}%`}
                  color={results.summary.winRate >= 0.5 ? "text-green-600 dark:text-green-400" : "text-red-600 dark:text-red-400"} />
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

              <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm" style={{ height: 560 }}>
                <p className="text-sm font-bold mb-2">Best price+time combos (sorted highest to lowest win rate)</p>
                <ResponsiveContainer width="100%" height="92%">
                  <BarChart data={results.bestCombos} layout="vertical" margin={{ left: 20, right: 20, top: 10, bottom: 10 }}>
                    <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                    <XAxis type="number" domain={[0, 100]} tickFormatter={(v) => `${v}%`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                    <YAxis type="category" dataKey="label" width={190} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                    <Tooltip
                      formatter={(v, n, ctx) => {
                        const p = ctx?.payload;
                        if (!p) return [v, n];
                        return [`${p.winRate}% (wins=${p.wins}, n=${p.total})`, "Win Rate"];
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
'@

$engineNew = Fix-WeirdText $engineNew
Backup-And-Write -Path $enginePath -NewText $engineNew | Out-Null

# Verify write worked (marker strings must exist)
if (-not $DryRun) {
  $verify = Get-Content -Path $enginePath -Raw -Encoding UTF8
  if (($verify -notmatch 'useState\(0\.01\)') -or ($verify -notmatch 'Best price\+time combos')) {
    Write-Error "Patch verification failed: file did not contain expected markers after write."
    exit 1
  }
  Write-Host "Verified: BacktestEngine.js updated successfully."
}

# --- Fix weird characters in other UI files ---
$uiPaths = @(
  "src\components\LiveTracker.js",
  "src\app\page.js",
  "src\app\backtest\page.js"
) | ForEach-Object { Join-Path $RepoRoot $_ }

foreach ($p in $uiPaths) {
  if (-not (Test-Path $p)) { continue }
  $orig = Get-Content -Path $p -Raw -Encoding UTF8
  $fixed = Fix-WeirdText $orig

  # Force common label normalization if present
  $fixed = $fixed.Replace("Entry Price Range (0–1)", "Entry Price Range (0-1)")
  $fixed = $fixed.Replace("Entry Price Range (0â€“1)", "Entry Price Range (0-1)")

  if ($fixed -ne $orig) {
    Backup-And-Write -Path $p -NewText $fixed | Out-Null
  } elseif ($DryRun) {
    Write-Host "DRY RUN: No changes needed in $p"
  }
}

Write-Host "Done."
