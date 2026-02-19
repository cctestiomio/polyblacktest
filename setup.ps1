<# patch-backtest-best-combos-and-fix-text.ps1
   - Overwrites src/components/BacktestEngine.js with:
       * default price range 0.01..0.99
       * "Best price+time combos" chart sorted by win rate desc
       * "What-if" lookup (buy UP/DOWN at price+time -> win rate + likely outcome)
     Uses ASCII-only UI strings (no special symbols).

   - Also fixes mojibake / weird characters in common UI files:
       src/components/LiveTracker.js
       src/app/page.js
       src/app/backtest/page.js

   Creates timestamped .bak backups and writes UTF-8 without BOM.

   Usage:
     .\patch-backtest-best-combos-and-fix-text.ps1
     .\patch-backtest-best-combos-and-fix-text.ps1 -DryRun
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

function Fix-WeirdText([string]$Text) {
  # Mojibake -> ASCII
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
    "â—" = "*"   # ws dot mojibake
    "â—‹" = "o"
    "â–²" = "^"
    "â–¼" = "v"
  }
  foreach ($k in $map.Keys) { $Text = $Text.Replace($k, $map[$k]) }

  # Normalize remaining non-ASCII symbols to ASCII to avoid future encoding fights
  $Text = $Text.Replace("×","x").Replace("–","-").Replace("—","-")
  $Text = $Text.Replace("¢","c")
  $Text = $Text.Replace("●","*").Replace("○","o").Replace("▲","^").Replace("▼","v")
  $Text = $Text.Replace("✓","OK").Replace("✗","X")

  return $Text
}

# ---------- 1) Overwrite BacktestEngine.js ----------
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
  ResponsiveContainer, Cell,
} from "recharts";

function clamp(n, lo, hi) {
  const x = Number(n);
  if (!Number.isFinite(x)) return lo;
  return Math.min(hi, Math.max(lo, x));
}

function fmtPriceDollarsFromCent(cent) {
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

  // Ranking controls
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
      minSamples: clamp(minSamples, 1, 1000000),
    };
  }, [priceMin, priceMax, elapsedMin, elapsedMax, topN, minSamples]);

  const runBacktest = () => {
    const sides = buySide === "BOTH" ? ["UP", "DOWN"] : [buySide];

    const trades = [];
    const comboBySide = { UP: new Map(), DOWN: new Map() }; // key=sec*100+cent -> {wins,total,sec,cent,side}

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
            price: cent / 100,
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

    // Build ranked list
    let pool = [];
    if (rankSide === "BOTH") {
      pool = [
        ...Array.from(comboBySide.UP.values()),
        ...Array.from(comboBySide.DOWN.values()),
      ];
    } else {
      pool = Array.from(comboBySide[rankSide].values());
    }

    const bestCombos = pool
      .filter(x => x.total >= normalized.minSamples)
      .map(x => {
        const wr = (x.wins / x.total) * 100;
        const priceStr = fmtPriceDollarsFromCent(x.cent);
        const timeStr = fmtTime(x.sec);
        const label = rankSide === "BOTH"
          ? `${x.side} ${priceStr} @ ${timeStr}`
          : `${priceStr} @ ${timeStr}`;

        return {
          side: x.side,
          cent: x.cent,
          sec: x.sec,
          label,
          wins: x.wins,
          total: x.total,
          winRate: +wr.toFixed(1),
        };
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
      return { ok: false, msg: "Price must round to between $0.01 and $0.99." };
    }

    const key = (sec * 100) + cent;
    const cell = results.comboBySide[side].get(key);
    if (!cell || !cell.total) {
      return { ok: false, msg: "No matching samples for that exact price+time (try widening filters or pick a nearby value)." };
    }

    const wr = (cell.wins / cell.total) * 100;
    const likelyOutcome = (wr >= 50) ? side : (side === "UP" ? "DOWN" : "UP");

    return {
      ok: true,
      side,
      sec,
      cent,
      priceStr: fmtPriceDollarsFromCent(cent),
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
                    buySide===s
                      ? "bg-indigo-600 text-white"
                      : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
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
                    rankSide===s
                      ? "bg-indigo-600 text-white"
                      : "bg-[var(--bg2)] hover:bg-[var(--bg3)] text-[var(--text1)] border border-[var(--border)]"
                  }`}>{s}</button>
              ))}
            </div>
            <p className="text-xs text-[var(--text3)] mt-1">
              "Win rate" means: if you buy that token at that exact price+time, how often the final outcome matches your token.
            </p>
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
            <label className="text-xs text-[var(--text2)] block mb-1">Top N combos to show</label>
            <input type="number" min="5" max="200" step="1" value={topN}
              onChange={e => setTopN(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]" />
          </div>

          <div>
            <label className="text-xs text-[var(--text2)] block mb-1">Min samples per combo (n)</label>
            <input type="number" min="1" step="1" value={minSamples}
              onChange={e => setMinSamples(+e.target.value)}
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded px-2 py-2 text-sm text-[var(--text1)]" />
            <p className="text-xs text-[var(--text3)] mt-1">Increase to avoid 1-of-1 lucky cells.</p>
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

              {/* What-if lookup */}
              <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm space-y-3">
                <p className="text-sm font-bold">What happens if I buy at an exact price+time?</p>
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

              {/* Best combos chart */}
              <div className="bg-[var(--card)] border border-[var(--border)] rounded-2xl p-4 shadow-sm" style={{ height: 560 }}>
                <p className="text-sm font-bold mb-2">Best price+time combos (sorted highest to lowest win rate)</p>
                <p className="text-xs text-[var(--text3)] mb-3">
                  Each bar is one exact combo. Tooltip shows win rate and sample size.
                </p>

                <ResponsiveContainer width="100%" height="90%">
                  <BarChart
                    data={results.bestCombos}
                    layout="vertical"
                    margin={{ left: 20, right: 20, top: 10, bottom: 10 }}
                  >
                    <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                    <XAxis type="number" domain={[0, 100]} tickFormatter={(v) => `${v}%`} stroke="#94a3b8" tick={{ fontSize: 11 }} />
                    <YAxis type="category" dataKey="label" width={170} stroke="#94a3b8" tick={{ fontSize: 11 }} />
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

                {results.bestCombos.length === 0 && (
                  <p className="text-xs text-[var(--text3)] mt-3">
                    No combos met min samples. Lower min samples or widen filters.
                  </p>
                )}
              </div>
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

$engineNew = Fix-WeirdText $engineNew
Backup-And-Write -Path $enginePath -NewText $engineNew

# ---------- 2) Fix weird characters in other UI files ----------
$fixPaths = @(
  "src\components\LiveTracker.js",
  "src\app\page.js",
  "src\app\backtest\page.js"
) | ForEach-Object { Join-Path $RepoRoot $_ }

foreach ($p in $fixPaths) {
  if (-not (Test-Path $p)) { continue }
  $orig = Get-Content -Path $p -Raw -Encoding UTF8
  $fixed = Fix-WeirdText $orig

  # Optional: also normalize a few common labels if they exist
  $fixed = $fixed.Replace("Entry Price Range (0–1)", "Entry Price Range (0-1)")
  $fixed = $fixed.Replace("Entry Price Range (0â€“1)", "Entry Price Range (0-1)")

  if ($fixed -ne $orig) {
    Backup-And-Write -Path $p -NewText $fixed
  } elseif ($DryRun) {
    Write-Host "DRY RUN: No changes needed in $p"
  }
}
