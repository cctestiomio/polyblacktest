<# a.ps1
   Fixes:
   - Default Entry Price Range to 0.01..0.99
   - Adds optimal Price+Time chart sorted by win rate (highest->lowest)
   - Adds what-if lookup (buy UP/DOWN at price+time -> win rate + likely outcome)
   - Removes mojibake/weird characters (ASCII-only) across src
   - Patches ALL copies of BacktestEngine.js to avoid "wrong file" problems
   - Verifies patch applied

   Run:
     powershell -ExecutionPolicy Bypass -File .\a.ps1
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
  if ($DryRun) { Write-Host "DRY RUN: Would write $Path"; return }
  $backup = "$Path.bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
  Copy-Item -Path $Path -Destination $backup -Force
  Write-Utf8NoBom -Path $Path -Text $NewText
  Write-Host "Patched: $Path"
  Write-Host "Backup : $backup"
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

function Fix-WeirdText([string]$Text) {
  # Mojibake + weird symbols -> ASCII
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
    "â—" = "*"
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

# --- Resolve repo root ---
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Find-RepoRoot (Get-Location).Path
} else {
  $RepoRoot = Find-RepoRoot $RepoRoot
}
if (-not $RepoRoot) { throw "Could not find repo root (package.json). Run from repo root or pass -RepoRoot." }

Write-Host "RepoRoot: $RepoRoot"

# --- 1) Repo-wide weird character cleanup under src (optional but recommended) ---
$srcDir = Join-Path $RepoRoot "src"
if (Test-Path $srcDir) {
  $allJs = Get-ChildItem -Path $srcDir -Recurse -File -Include *.js,*.jsx,*.ts,*.tsx -ErrorAction SilentlyContinue
  foreach ($f in $allJs) {
    try {
      $orig = Get-Content -Path $f.FullName -Raw -Encoding UTF8
      $fixed = Fix-WeirdText $orig
      if ($fixed -ne $orig) {
        if ($DryRun) { Write-Host "DRY RUN: Would normalize text in $($f.FullName)"; continue }
        $backup = "$($f.FullName).bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item $f.FullName $backup -Force
        Write-Utf8NoBom $f.FullName $fixed
        Write-Host "Normalized text: $($f.FullName)"
      }
    } catch {}
  }
} else {
  Write-Host "WARNING: src/ not found. Skipping repo-wide text normalization."
}

# --- 2) Patch ALL BacktestEngine.js copies ---
$engineFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -Filter "BacktestEngine.js" -ErrorAction SilentlyContinue
if (-not $engineFiles -or $engineFiles.Count -eq 0) { throw "Could not find any BacktestEngine.js in repo." }

Write-Host "Found BacktestEngine.js files:"
$engineFiles | ForEach-Object { Write-Host " - $($_.FullName)" }

$engineNew = @'
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
  // Defaults requested: 0.01..0.99
  const [buySide, setBuySide] = useState("BOTH"); // UP, DOWN, BOTH
  const [priceMin, setPriceMin] = useState(0.01);
  const [priceMax, setPriceMax] = useState(0.99);
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);

  // Ranking output: best (side + price + time) combos
  const [rankSide, setRankSide] = useState("BOTH"); // UP, DOWN, BOTH
  const [topN, setTopN] = useState(30);
  const [minSamples, setMinSamples] = useState(10);

  // What-if query
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
    const comboBySide = { UP: new Map(), DOWN: new Map() }; // key=sec*100+cent

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
          trades.push({ slug: session?.slug ?? "?", sec, cent, side: s, outcome, win });

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

    const totalWins = trades.reduce((acc, t) => acc + (t.win ? 1 : 0), 0);
    const overallWr = totalWins / trades.length;

    let pool = [];
    if (rankSide === "BOTH") pool = [...comboBySide.UP.values(), ...comboBySide.DOWN.values()];
    else pool = [...comboBySide[rankSide].values()];

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
      summary: { total: trades.length, wins: totalWins, winRate: overallWr },
      bestCombos,
      comboBySide
    });
  };

  const whatIf = useMemo(() => {
    if (!results?.comboBySide) return null;

    const side = qSide;
    const sec = clamp(Math.round(qElapsed), 0, 300);
    const cent = clamp(Math.round(clamp(qPrice, 0, 1) * 100), 0, 100);
    if (cent < 1 || cent > 99) return { ok: false, msg: "Pick a price that rounds to 0.01 - 0.99." };

    const key = (sec * 100) + cent;
    const cell = results.comboBySide[side].get(key);
    if (!cell || !cell.total) return { ok: false, msg: "No samples for that exact price+time." };

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
      likelyOutcome
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
                    <YAxis type="category" dataKey="label" width={210} stroke="#94a3b8" tick={{ fontSize: 11 }} />
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

foreach ($f in $engineFiles) {
  Backup-And-Write $f.FullName $engineNew
}

# --- 3) Verify patch markers exist in each BacktestEngine.js ---
if (-not $DryRun) {
  foreach ($f in $engineFiles) {
    $t = Get-Content -Path $f.FullName -Raw -Encoding UTF8
    if (($t -notmatch 'useState\(0\.01\)') -or ($t -notmatch 'Best price\+time combos')) {
      throw "Verification failed for: $($f.FullName) (markers not found after patch)"
    }
    Write-Host "Verified: $($f.FullName)"
  }
}

Write-Host "All done."
