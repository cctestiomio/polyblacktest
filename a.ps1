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

# --- 0) Normalize common mojibake under src\ (byte-level; PS1 stays ASCII) ---
# Includes: "0â€“1", "1Â¢", "Price Ã— Time", the WS dot, etc.
$patterns = @(
  @{ Find = (HexToBytes "C382C2A0"); Repl = [byte[]](0x20) }                          # NBSP -> space
  @{ Find = (HexToBytes "C382C2A2"); Repl = [byte[]](0x63) }                          # "Â¢" -> "c"
  @{ Find = (HexToBytes "C3A2C280C293"); Repl = [byte[]](0x2D) }                      # "â€“" -> "-"
  @{ Find = (HexToBytes "C3A2C280C294"); Repl = [byte[]](0x2D) }                      # "â€”" -> "-"
  @{ Find = (HexToBytes "C383C297"); Repl = [byte[]](0x78) }                          # "Ã" + 0x97 -> "x"
  @{ Find = (HexToBytes "C3A2C297C28F"); Repl = [byte[]](0x2A) }                      # "â—" -> "*"
  @{ Find = (HexToBytes "C3A2C296C2B6"); Repl = [byte[]](0x3E) }                      # "â–¶" -> ">"
  @{ Find = (HexToBytes "C3A2C29CC293"); Repl = [byte[]](0x4F,0x4B) }                 # "âœ“" -> "OK"
  @{ Find = (HexToBytes "C3A2C29CC297"); Repl = [byte[]](0x58) }                      # "âœ—" -> "X"
  @{ Find = (HexToBytes "C3A2E2809DE282AC"); Repl = [byte[]](0x2D) }                  # "â”€" -> "-"
)

$srcDir = Join-Path $RepoRoot "src"
if (Test-Path $srcDir) {
  $files = Get-ChildItem -Path $srcDir -Recurse -File -Include *.js,*.jsx,*.ts,*.tsx -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    try { Normalize-FileBytes $f.FullName $patterns } catch {}
  }
} else {
  Write-Host "WARNING: src\ not found; skipping normalization."
}

# --- 1) Patch track page: add Download All (separate files) button ---
$pageCandidates = Get-ChildItem -Path $RepoRoot -Recurse -File -Filter "page.js" -ErrorAction SilentlyContinue
$pageFiles = @()
foreach ($f in $pageCandidates) {
  try {
    $t = Read-TextUtf8 $f.FullName
    if ($t -match 'STORAGE_KEY\s*=\s*"pm_sessions"' -and $t -match 'const\s+downloadSessions\s*=\s*\(\)\s*=>') {
      $pageFiles += $f
    }
  } catch {}
}

foreach ($f in $pageFiles) {
  $t = Read-TextUtf8 $f.FullName
  $orig = $t

  if ($t -notmatch 'downloadSessionsSeparate') {
    $insertFn = @'
const downloadSessionsSeparate = () => {
  if (!sessions.length) return;

  // One JSON file per session (browser may prompt; this is expected).
  sessions.forEach((s, i) => {
    const safeSlug = String(s.slug ?? `session_${i}`)
      .replace(/[^a-zA-Z0-9._-]+/g, "_")
      .slice(0, 180);

    const ts = s.savedAt ?? Date.now();
    const filename = `${safeSlug}_${ts}.json`;

    const blob = new Blob([JSON.stringify(s, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = filename;

    setTimeout(() => {
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 2000);
    }, i * 200);
  });
};
'@

    $t = [regex]::Replace(
      $t,
      '(const\s+downloadSessions\s*=\s*\(\)\s*=>\s*\{[\s\S]*?\};)',
      "`$1`n`n$insertFn",
      "Singleline"
    )
  }

  # Insert a new button next to the existing Download JSON button
  if ($t -notmatch 'Download All JSON') {
    $t = [regex]::Replace(
      $t,
      '(<button[^>]*onClick=\{downloadSessions\}[\s\S]*?>\s*Download JSON\s*</button>)',
      "`$1`n<button onClick={downloadSessionsSeparate} disabled={!sessions.length} className=`"px-4 py-1.5 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 text-white rounded-lg text-sm font-semibold`">Download All JSON (separate)</button>",
      "Singleline"
    )
  }

  if ($t -ne $orig) {
    $bak = Backup-File $f.FullName
    Write-TextUtf8NoBom $f.FullName $t
    Write-Host "Patched track page: $($f.FullName)"
    Write-Host "Backup            : $bak"
  }
}

# --- 2) Patch LiveTracker WS indicator to plain ASCII ---
$liveCandidates = Get-ChildItem -Path $RepoRoot -Recurse -File -Filter "LiveTracker.js" -ErrorAction SilentlyContinue
foreach ($f in $liveCandidates) {
  $t = Read-TextUtf8 $f.FullName
  $orig = $t

  # Replace the exact ternary block (after normalization it often becomes "* WS" variants).
  $t = [regex]::Replace(
    $t,
    '\{wsState\s*===\s*"connected"\s*\?\s*"[^"]*WS[^"]*"\s*:\s*wsState\s*===\s*"error"\s*\?\s*"[^"]*WS\s*ERR[^"]*"\s*:\s*"[^"]*WS[^"]*"\s*\}',
    '{wsState === "connected" ? "WS" : wsState === "error" ? "WS ERR" : "WS"}',
    "Singleline"
  )

  # Extra safety: remove any lingering "* WS" text fragments
  $t = $t.Replace('* WS ERR', 'WS ERR').Replace('* WS', 'WS')

  if ($t -ne $orig) {
    $bak = Backup-File $f.FullName
    Write-TextUtf8NoBom $f.FullName $t
    Write-Host "Patched LiveTracker: $($f.FullName)"
    Write-Host "Backup            : $bak"
  }
}

# --- 3) Overwrite ALL BacktestEngine.js with grouped step config + best-combos table ---
$engineFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -Filter "BacktestEngine.js" -ErrorAction SilentlyContinue
if (-not $engineFiles -or $engineFiles.Count -eq 0) { throw "No BacktestEngine.js found in repo." }

$engineText = @'
"use client";
import { useMemo, useState } from "react";

function clamp(n, lo, hi) {
  const x = Number(n);
  if (!Number.isFinite(x)) return lo;
  return Math.min(hi, Math.max(lo, x));
}

function fmtTime(sec) {
  const s = clamp(Math.round(sec), 0, 300);
  const m = Math.floor(s / 60);
  const r = String(s % 60).padStart(2, "0");
  return `${m}m${r}s`;
}

function fmtPriceRange(centStart, centEnd) {
  const a = (centStart / 100).toFixed(2);
  const b = (centEnd / 100).toFixed(2);
  return centStart === centEnd ? `$${a}` : `$${a}-$${b}`;
}

function opposite(side) {
  return side === "UP" ? "DOWN" : "UP";
}

export default function BacktestEngine({ sessions }) {
  const [buySide, setBuySide] = useState("BOTH"); // UP, DOWN, BOTH
  const [priceMin, setPriceMin] = useState(0.01);
  const [priceMax, setPriceMax] = useState(0.99);
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);

  // New: group by increments (and/or)
  const [priceStepCents, setPriceStepCents] = useState(1); // 1 or 5
  const [timeStepSecs, setTimeStepSecs] = useState(1);     // 1 or 5

  const [topN, setTopN] = useState(50);
  const [minSamples, setMinSamples] = useState(1);

  const [results, setResults] = useState(null);

  const normalized = useMemo(() => {
    const pMin = clamp(Math.min(priceMin, priceMax), 0, 1);
    const pMax = clamp(Math.max(priceMin, priceMax), 0, 1);
    const eMin = clamp(Math.min(elapsedMin, elapsedMax), 0, 300);
    const eMax = clamp(Math.max(elapsedMin, elapsedMax), 0, 300);

    const ps = (Number(priceStepCents) === 5) ? 5 : 1;
    const ts = (Number(timeStepSecs) === 5) ? 5 : 1;

    return {
      pMin, pMax, eMin, eMax,
      ps, ts,
      topN: clamp(topN, 1, 500),
      minSamples: clamp(minSamples, 1, 1000000),
    };
  }, [priceMin, priceMax, elapsedMin, elapsedMax, priceStepCents, timeStepSecs, topN, minSamples]);

  const runBacktest = () => {
    const sides = buySide === "BOTH" ? ["UP", "DOWN"] : [buySide];

    let tradesCount = 0;
    let winsCount = 0;

    // Key includes side + grouped buckets
    const m = new Map(); // key = side|secStart|centStart

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

          // Grouping (and/or): if step is 1, buckets are exact; if 5, buckets are ranges.
          const secStart = Math.floor(sec / normalized.ts) * normalized.ts;
          const secEnd = Math.min(300, secStart + normalized.ts - 1);

          const centStart = (Math.floor((cent - 1) / normalized.ps) * normalized.ps) + 1;
          const centEnd = Math.min(99, centStart + normalized.ps - 1);

          const win = outcome === s;

          tradesCount++;
          if (win) winsCount++;

          const key = `${s}|${secStart}|${centStart}`;
          const cur = m.get(key) ?? { side: s, secStart, secEnd, centStart, centEnd, wins: 0, total: 0 };
          cur.total++;
          if (win) cur.wins++;
          m.set(key, cur);
        }
      }
    }

    if (tradesCount === 0) {
      setResults({ summary: null, rows: [], debug: { trades: 0, cells: 0 } });
      return;
    }

    const rows = [...m.values()]
      .filter(x => x.total >= normalized.minSamples)
      .map(x => {
        const wr01 = x.wins / x.total;
        const wr = +(wr01 * 100).toFixed(1);
        const likelyOutcome = (wr01 >= 0.5) ? x.side : opposite(x.side);
        return {
          ...x,
          winRate: wr,
          likelyOutcome,
          priceLabel: fmtPriceRange(x.centStart, x.centEnd),
          timeLabel: (x.secStart === x.secEnd) ? fmtTime(x.secStart) : `${fmtTime(x.secStart)}-${fmtTime(x.secEnd)}`
        };
      })
      .sort((a, b) => (b.winRate - a.winRate) || (b.total - a.total) || (a.secStart - b.secStart) || (a.centStart - b.centStart))
      .slice(0, normalized.topN);

    setResults({
      summary: { total: tradesCount, wins: winsCount, winRate: winsCount / tradesCount },
      rows,
      debug: { trades: tradesCount, cells: m.size, ps: normalized.ps, ts: normalized.ts }
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
            <label className="text-xs text-[var(--text2)] block mb-1">Group Price By</label>
            <select value={priceStepCents} onChange={e => setPriceStepCents(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]">
              <option value={1}>1 cent</option>
              <option value={5}>5 cents</option>
            </select>
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Group Time By</label>
            <select value={timeStepSecs} onChange={e => setTimeStepSecs(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]">
              <option value={1}>1 second</option>
              <option value={5}>5 seconds</option>
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

              <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm">
                <p className="text-sm font-bold mb-2">Best price + time combos (sorted by win rate)</p>

                {results.rows.length === 0 ? (
                  <div className="text-sm text-[var(--text3)]">
                    No rows. Lower Min samples, or widen filters, and confirm sessions have outcomes.
                  </div>
                ) : (
                  <div className="overflow-x-auto">
                    <table className="w-full text-xs text-[var(--text1)]">
                      <thead>
                        <tr className="text-[var(--text3)] border-b border-[var(--border)]">
                          <th className="text-left py-1 pr-4">Side</th>
                          <th className="text-right pr-4">Price</th>
                          <th className="text-right pr-4">Elapsed</th>
                          <th className="text-right pr-4">WinRate</th>
                          <th className="text-right pr-4">Wins</th>
                          <th className="text-right pr-4">N</th>
                          <th className="text-right">Likely outcome</th>
                        </tr>
                      </thead>
                      <tbody>
                        {results.rows.map((r, i) => (
                          <tr key={i} className="border-b border-[var(--border)] hover:bg-[var(--bg2)]">
                            <td className={`py-1 pr-4 font-bold ${r.side === "UP" ? "text-green-600" : "text-red-600"}`}>{r.side}</td>
                            <td className="text-right pr-4">{r.priceLabel}</td>
                            <td className="text-right pr-4">{r.timeLabel}</td>
                            <td className="text-right pr-4">{r.winRate}%</td>
                            <td className="text-right pr-4">{r.wins}</td>
                            <td className="text-right pr-4">{r.total}</td>
                            <td className="text-right font-bold">{r.likelyOutcome}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}

                <div className="text-xs text-[var(--text3)] mt-3">
                  Debug: trades={results.debug?.trades ?? 0}, cells={results.debug?.cells ?? 0}, priceStep={results.debug?.ps ?? "?"}c, timeStep={results.debug?.ts ?? "?"}s
                </div>
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

# Guard: keep ASCII-only JS to avoid encoding/parser issues
foreach ($ch in $engineText.ToCharArray()) { if ([int][char]$ch -gt 127) { throw "BacktestEngine.js text not ASCII-only; aborting." } }

foreach ($f in $engineFiles) {
  $bak = Backup-File $f.FullName
  if ($DryRun) {
    Write-Host "DRY RUN: Would overwrite $($f.FullName)"
  } else {
    Write-TextUtf8NoBom $f.FullName $engineText
    Write-Host "Overwrote BacktestEngine: $($f.FullName)"
    Write-Host "Backup                : $bak"
  }
}

# --- Verify key markers ---
if (-not $DryRun) {
  foreach ($f in $engineFiles) {
    $t = Read-TextUtf8 $f.FullName
    if ($t -notmatch 'priceStepCents' -or $t -notmatch 'timeStepSecs' -or $t -notmatch 'Best price \+ time combos') {
      throw "Verification failed for $($f.FullName): markers missing."
    }
  }
  foreach ($f in $pageFiles) {
    $t = Read-TextUtf8 $f.FullName
    if ($t -notmatch 'downloadSessionsSeparate' -or $t -notmatch 'Download All JSON') {
      throw "Verification failed for $($f.FullName): download-all button missing."
    }
  }
}

Write-Host "Done. Restart dev server (Ctrl+C then npm run dev). If UI is still stale, delete .next\ and restart."
