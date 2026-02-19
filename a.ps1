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

function Write-Utf8NoBomBytes([string]$Path, [byte[]]$Bytes) {
  if ($DryRun) { return }
  [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

function Backup-File([string]$Path) {
  if ($DryRun) { return $null }
  $bak = "$Path.bak.$(Get-Date -Format yyyyMMdd-HHmmss)"
  Copy-Item -Path $Path -Destination $bak -Force
  return $bak
}

function HexToBytes([string]$hex) {
  $h = ($hex -replace '[^0-9A-Fa-f]', '')
  if (($h.Length % 2) -ne 0) { throw "Hex string must have even length: $hex" }
  $bytes = New-Object byte[] ($h.Length / 2)
  for ($i=0; $i -lt $bytes.Length; $i++) {
    $bytes[$i] = [Convert]::ToByte($h.Substring($i*2, 2), 16)
  }
  return $bytes
}

function Replace-Bytes([byte[]]$data, [byte[]]$find, [byte[]]$repl) {
  if ($find.Length -eq 0) { return ,$data }
  $out = New-Object System.Collections.Generic.List[byte] ($data.Length)
  $i = 0
  while ($i -lt $data.Length) {
    $match = $false
    if ($i + $find.Length -le $data.Length) {
      $match = $true
      for ($j=0; $j -lt $find.Length; $j++) {
        if ($data[$i+$j] -ne $find[$j]) { $match = $false; break }
      }
    }
    if ($match) {
      [void]$out.AddRange($repl)
      $i += $find.Length
    } else {
      [void]$out.Add($data[$i])
      $i++
    }
  }
  return ,$out.ToArray()
}

function Normalize-FileBytes([string]$Path, $patterns) {
  $orig = [System.IO.File]::ReadAllBytes($Path)
  $cur = $orig
  foreach ($p in $patterns) {
    $cur = Replace-Bytes $cur $p.Find $p.Repl
  }
  if (-not ($cur.Length -eq $orig.Length -and $cur.SequenceEqual($orig))) {
    $bak = Backup-File $Path
    if ($DryRun) {
      Write-Host "DRY RUN: Would normalize $Path"
    } else {
      [System.IO.File]::WriteAllBytes($Path, $cur)
      Write-Host "Normalized: $Path"
      Write-Host "Backup    : $bak"
    }
  }
}

# --- Resolve repo root ---
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Find-RepoRoot (Get-Location).Path
} else {
  $RepoRoot = Find-RepoRoot $RepoRoot
}
if (-not $RepoRoot) { throw "Could not find repo root (package.json). Run from repo root." }
Write-Host "RepoRoot: $RepoRoot"

# --- Normalize common mojibake across src (ASCII replacements) ---
$patterns = @(
  @{ Find = (HexToBytes "C382C2A0"); Repl = [byte[]](0x20) }                             # NBSP shown as A0 -> space
  @{ Find = (HexToBytes "C382C2A2"); Repl = [byte[]](0x63) }                             # "Â¢" -> "c"
  @{ Find = (HexToBytes "C3A2C280C293"); Repl = [byte[]](0x2D) }                         # "â€“" -> "-"
  @{ Find = (HexToBytes "C3A2C280C294"); Repl = [byte[]](0x2D) }                         # "â€”" -> "-"
  @{ Find = (HexToBytes "C383C297");     Repl = [byte[]](0x78) }                         # "Ã" + 0x97 -> "x"
  @{ Find = (HexToBytes "C3A2C296C2B6"); Repl = [byte[]](0x3E) }                         # "â–¶" -> ">"
  @{ Find = (HexToBytes "C3A2C29CC293"); Repl = [byte[]](0x4F,0x4B) }                    # "âœ“" -> "OK"
  @{ Find = (HexToBytes "C3A2C29CC297"); Repl = [byte[]](0x58) }                         # "âœ—" -> "X"
  @{ Find = (HexToBytes "C3A2C297C28F"); Repl = [byte[]](0x2A) }                         # "â—" -> "*"
)

$srcDir = Join-Path $RepoRoot "src"
if (Test-Path $srcDir) {
  $files = Get-ChildItem -Path $srcDir -Recurse -File -Include *.js,*.jsx,*.ts,*.tsx -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    try { Normalize-FileBytes $f.FullName $patterns } catch {}
  }
}

# --- Overwrite ALL BacktestEngine.js copies with best-combos + $10 P/L simulation ---
$engineFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -Filter "BacktestEngine.js" -ErrorAction SilentlyContinue
if (-not $engineFiles -or $engineFiles.Count -eq 0) { throw "No BacktestEngine.js found." }

Write-Host "BacktestEngine.js files found:"
$engineFiles | ForEach-Object { Write-Host " - $($_.FullName)" }

$engineText = @'
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

function plForStake(stake, price01, winRate01) {
  const p = clamp(price01, 0.01, 0.99);
  const stakeClamped = Math.max(0, Number(stake) || 0);
  const shares = stakeClamped / p;

  const profitIfWin = shares - stakeClamped; // payout = shares * $1, cost = stake
  const lossIfLose = -stakeClamped;

  const w = clamp(winRate01, 0, 1);
  const expectedPL = (w * profitIfWin) + ((1 - w) * lossIfLose);

  return {
    stake: stakeClamped,
    shares,
    profitIfWin,
    lossIfLose,
    expectedPL
  };
}

export default function BacktestEngine({ sessions }) {
  // Defaults requested
  const [buySide, setBuySide] = useState("BOTH"); // UP, DOWN, BOTH
  const [priceMin, setPriceMin] = useState(0.01);
  const [priceMax, setPriceMax] = useState(0.99);
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);

  // Output controls
  const [rankSide, setRankSide] = useState("BOTH"); // UP, DOWN, BOTH
  const [topN, setTopN] = useState(30);
  const [minSamples, setMinSamples] = useState(10);
  const [stake, setStake] = useState(10);

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
      stake: Math.max(0, Number(stake) || 0)
    };
  }, [priceMin, priceMax, elapsedMin, elapsedMax, topN, minSamples, stake]);

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

    const totalWins = trades.reduce((acc, t) => acc + (t.win ? 1 : 0), 0);
    const overallWr = totalWins / trades.length;

    let pool = [];
    if (rankSide === "BOTH") pool = [...comboBySide.UP.values(), ...comboBySide.DOWN.values()];
    else pool = [...comboBySide[rankSide].values()];

    const bestCombos = pool
      .filter(x => x.total >= normalized.minSamples)
      .map(x => {
        const winRate01 = x.wins / x.total;
        const winRatePct = winRate01 * 100;
        const price01 = x.cent / 100;

        const pl = plForStake(normalized.stake, price01, winRate01);
        const likelyOutcome = (winRate01 >= 0.5) ? x.side : opposite(x.side);

        const label = (rankSide === "BOTH")
          ? `${x.side} ${fmtPrice01(price01)} @ ${fmtTime(x.sec)}`
          : `${fmtPrice01(price01)} @ ${fmtTime(x.sec)}`;

        return {
          label,
          side: x.side,
          sec: x.sec,
          cent: x.cent,
          wins: x.wins,
          total: x.total,
          winRate: +winRatePct.toFixed(1),
          likelyOutcome,
          stake: pl.stake,
          shares: +pl.shares.toFixed(2),
          profitIfWin: +pl.profitIfWin.toFixed(2),
          lossIfLose: +pl.lossIfLose.toFixed(2),
          expectedPL: +pl.expectedPL.toFixed(2)
        };
      })
      .sort((a, b) => (b.winRate - a.winRate) || (b.total - a.total) || (a.sec - b.sec) || (a.cent - b.cent))
      .slice(0, normalized.topN);

    setResults({
      summary: { total: trades.length, wins: totalWins, winRate: overallWr },
      bestCombos,
      comboBySide
    });
  };

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
            <label className="text-xs text-[var(--text2)] block mb-1">Stake ($) for P/L simulation</label>
            <input type="number" min="0" step="1" value={stake}
              onChange={e => setStake(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]" />
            <p className="text-xs text-[var(--text3)] mt-1">
              Assumes $1 payout per share if correct, $0 if wrong (fees/slippage ignored).
            </p>
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

      {results && results.summary && (
        <div className="space-y-4">
          <div className="grid grid-cols-3 gap-3">
            <SCard label="Total Trades" value={results.summary.total} color="text-blue-600 dark:text-blue-400" />
            <SCard label="Wins" value={results.summary.wins} color="text-green-600 dark:text-green-400" />
            <SCard
              label="Win Rate"
              value={`${(results.summary.winRate * 100).toFixed(1)}%`}
              color={results.summary.winRate >= 0.5 ? "text-green-600 dark:text-green-400" : "text-red-600 dark:text-red-400"}
            />
          </div>

          <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm" style={{ height: chartHeight }}>
            <p className="text-sm font-bold mb-2">Best price+time combos (sorted by win rate, high to low)</p>
            <ResponsiveContainer width="100%" height="92%">
              <BarChart data={results.bestCombos} layout="vertical" margin={{ left: 20, right: 20, top: 10, bottom: 10 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis type="number" domain={[0, 100]} tickFormatter={(v) => `${v}%`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                <YAxis type="category" dataKey="label" width={260} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                <Tooltip
                  formatter={(v, n, ctx) => {
                    const p = ctx?.payload;
                    if (!p) return [v, n];
                    return [
                      `winRate=${p.winRate}%, n=${p.total}, stake=$${p.stake}, profitIfWin=$${p.profitIfWin}, lossIfLose=$${p.lossIfLose}, expectedPL=$${p.expectedPL}, likelyOutcome=${p.likelyOutcome}`,
                      "Combo"
                    ];
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

          <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm">
            <p className="text-xs text-[var(--text2)] mb-3">P/L simulation for the ranked combos</p>
            <div className="overflow-x-auto">
              <table className="w-full text-xs text-[var(--text1)]">
                <thead>
                  <tr className="text-[var(--text3)] border-b border-[var(--border)]">
                    <th className="text-left py-1 pr-4">Combo</th>
                    <th className="text-right pr-4">WinRate</th>
                    <th className="text-right pr-4">n</th>
                    <th className="text-right pr-4">Stake</th>
                    <th className="text-right pr-4">ProfitIfWin</th>
                    <th className="text-right pr-4">LossIfLose</th>
                    <th className="text-right">ExpectedPL</th>
                  </tr>
                </thead>
                <tbody>
                  {results.bestCombos.map((c, i) => (
                    <tr key={i} className="border-b border-[var(--border)] hover:bg-[var(--bg2)]">
                      <td className="py-1 pr-4">{c.label}</td>
                      <td className="text-right pr-4">{c.winRate}%</td>
                      <td className="text-right pr-4">{c.total}</td>
                      <td className="text-right pr-4">${c.stake.toFixed(0)}</td>
                      <td className="text-right pr-4">${c.profitIfWin.toFixed(2)}</td>
                      <td className="text-right pr-4">${c.lossIfLose.toFixed(2)}</td>
                      <td className={`text-right font-bold ${c.expectedPL >= 0 ? "text-green-600" : "text-red-600"}`}>
                        ${c.expectedPL.toFixed(2)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
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

# Ensure the JS we write is UTF-8 bytes
$engineBytes = [System.Text.Encoding]::UTF8.GetBytes($engineText)

foreach ($f in $engineFiles) {
  $bak = Backup-File $f.FullName
  if ($DryRun) {
    Write-Host "DRY RUN: Would overwrite $($f.FullName)"
  } else {
    Write-Utf8NoBomBytes $f.FullName $engineBytes
    Write-Host "Overwrote: $($f.FullName)"
    Write-Host "Backup   : $bak"
  }
}

# --- Verify markers ---
if (-not $DryRun) {
  foreach ($f in $engineFiles) {
    $t = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    if ($t -notmatch 'useState\(0\.01\)' -or $t -notmatch 'profitIfWin' -or $t -notmatch 'expectedPL') {
      throw "Verification failed for $($f.FullName): markers missing after write."
    }
    Write-Host "Verified: $($f.FullName)"
  }
}

Write-Host "Done. Restart dev server (Ctrl+C then npm run dev)."
