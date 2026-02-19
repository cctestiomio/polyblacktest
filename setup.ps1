# setup.ps1
# Polymarket BTC UP/DOWN 5m Backtest Website
# Run this in PowerShell: .\setup.ps1
# Then: cd polymarket-btc-backtest && npm install && npm run dev

$project = "polymarket-btc-backtest"
Write-Host "Creating project: $project" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $project | Out-Null
Set-Location $project

# ── Directory structure ──────────────────────────────────────────────────────
$dirs = @(
  "src/app/backtest",
  "src/components",
  "src/lib",
  "public"
)
foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# ── package.json ─────────────────────────────────────────────────────────────
@'
{
  "name": "polymarket-btc-backtest",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start",
    "lint": "next lint"
  },
  "dependencies": {
    "next": "14.2.5",
    "react": "^18",
    "react-dom": "^18",
    "recharts": "^2.12.7",
    "lucide-react": "^0.400.0"
  },
  "devDependencies": {
    "autoprefixer": "^10",
    "postcss": "^8",
    "tailwindcss": "^3",
    "eslint": "^8",
    "eslint-config-next": "14.2.5"
  }
}
'@ | Set-Content "package.json"

# ── next.config.js ───────────────────────────────────────────────────────────
@'
/** @type {import("next").NextConfig} */
const nextConfig = {
  async headers() {
    return [
      {
        source: "/api/:path*",
        headers: [
          { key: "Access-Control-Allow-Origin", value: "*" },
        ],
      },
    ];
  },
};
module.exports = nextConfig;
'@ | Set-Content "next.config.js"

# ── tailwind.config.js ───────────────────────────────────────────────────────
@'
/** @type {import("tailwindcss").Config} */
module.exports = {
  content: ["./src/**/*.{js,ts,jsx,tsx,mdx}"],
  theme: {
    extend: {},
  },
  plugins: [],
};
'@ | Set-Content "tailwind.config.js"

# ── postcss.config.js ────────────────────────────────────────────────────────
@'
module.exports = {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
};
'@ | Set-Content "postcss.config.js"

# ── vercel.json ──────────────────────────────────────────────────────────────
@'
{
  "framework": "nextjs",
  "buildCommand": "npm run build",
  "devCommand": "npm run dev",
  "installCommand": "npm install"
}
'@ | Set-Content "vercel.json"

# ── .gitignore ───────────────────────────────────────────────────────────────
@'
node_modules/
.next/
.env
.env.local
*.log
dist/
'@ | Set-Content ".gitignore"

# ── src/app/globals.css ──────────────────────────────────────────────────────
@'
@tailwind base;
@tailwind components;
@tailwind utilities;

body {
  background: #0a0a0f;
  color: #e2e8f0;
}
'@ | Set-Content "src/app/globals.css"

# ── src/app/layout.js ────────────────────────────────────────────────────────
@'
import "./globals.css";
export const metadata = { title: "Polymarket BTC 5m Backtest", description: "Track & backtest BTC UP/DOWN 5m markets" };
export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
'@ | Set-Content "src/app/layout.js"

# ── src/lib/polymarket.js ────────────────────────────────────────────────────
@'
// Helpers for Polymarket CLOB API

export function getCurrentMarketTimestamp() {
  const now = Math.floor(Date.now() / 1000);
  // Markets resolve on 300s boundaries
  return Math.ceil(now / 300) * 300;
}

export function getMarketSlug(ts) {
  return `btc-up-or-down-in-5-minutes-${ts}`;
}

export function getSecondsRemaining(resolutionTs) {
  return Math.max(0, resolutionTs - Math.floor(Date.now() / 1000));
}

export function getSecondsElapsed(resolutionTs) {
  const total = 300;
  const remaining = getSecondsRemaining(resolutionTs);
  return Math.min(total, total - remaining);
}

/** Fetch market details (token IDs) from Gamma API via our proxy */
export async function fetchMarketBySlug(slug) {
  const res = await fetch(`/api/market?slug=${slug}`);
  if (!res.ok) return null;
  return res.json();
}

/** Fetch current midpoint price for a token */
export async function fetchMidpoint(tokenId) {
  const res = await fetch(`/api/midpoint?token_id=${tokenId}`);
  if (!res.ok) return null;
  const data = await res.json();
  return parseFloat(data.mid ?? 0);
}
'@ | Set-Content "src/lib/polymarket.js"

# ── src/app/api/market/route.js ───────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path "src/app/api/market" | Out-Null
@'
export const runtime = "edge";
export async function GET(request) {
  const { searchParams } = new URL(request.url);
  const slug = searchParams.get("slug");
  if (!slug) return Response.json({ error: "no slug" }, { status: 400 });

  try {
    const url = `https://gamma-api.polymarket.com/markets?slug=${slug}`;
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    const data = await res.json();
    const market = Array.isArray(data) ? data[0] : data;
    if (!market) return Response.json({ error: "not found" }, { status: 404 });

    // Normalise token list
    const tokens = market.tokens ?? market.clobTokenIds ?? [];
    return Response.json({
      slug: market.slug,
      conditionId: market.conditionId,
      question: market.question,
      endDate: market.endDate,
      closed: market.closed,
      tokens,
      outcomes: market.outcomes,
    });
  } catch (e) {
    return Response.json({ error: String(e) }, { status: 500 });
  }
}
'@ | Set-Content "src/app/api/market/route.js"

# ── src/app/api/midpoint/route.js ────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path "src/app/api/midpoint" | Out-Null
@'
export const runtime = "edge";
export async function GET(request) {
  const { searchParams } = new URL(request.url);
  const tokenId = searchParams.get("token_id");
  if (!tokenId) return Response.json({ error: "no token_id" }, { status: 400 });
  try {
    const res = await fetch(
      `https://clob.polymarket.com/midpoints?token_id=${tokenId}`,
      { headers: { Accept: "application/json" } }
    );
    const data = await res.json();
    // CLOB returns { mid: "0.60" } or { [tokenId]: "0.60" }
    const mid = data?.mid ?? data?.[tokenId] ?? "0";
    return Response.json({ mid });
  } catch (e) {
    return Response.json({ error: String(e) }, { status: 500 });
  }
}
'@ | Set-Content "src/app/api/midpoint/route.js"

# ── src/components/LiveTracker.js ─────────────────────────────────────────────
@'
"use client";
import { useEffect, useRef, useState, useCallback } from "react";
import { LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, ResponsiveContainer, ReferenceLine } from "recharts";
import {
  getCurrentMarketTimestamp,
  getMarketSlug,
  fetchMarketBySlug,
  fetchMidpoint,
  getSecondsElapsed,
  getSecondsRemaining,
} from "../lib/polymarket";

const POLL_MS = 1500; // poll every 1.5 s

function pad(n) { return String(n).padStart(2, "0"); }
function fmtSeconds(s) { return `${pad(Math.floor(s / 60))}:${pad(s % 60)}`; }

export default function LiveTracker({ onSaveSession }) {
  const [status, setStatus] = useState("idle"); // idle | loading | tracking | resolved | error
  const [market, setMarket] = useState(null);
  const [priceHistory, setPriceHistory] = useState([]);
  const [elapsed, setElapsed] = useState(0);
  const [remaining, setRemaining] = useState(300);
  const [currentUp, setCurrentUp] = useState(null);
  const [errorMsg, setErrorMsg] = useState("");
  const [manualSlug, setManualSlug] = useState("");
  const [outcome, setOutcome] = useState(null); // "UP"|"DOWN"|null
  const intervalRef = useRef(null);
  const marketRef = useRef(null);
  const historyRef = useRef([]);
  const resolutionTsRef = useRef(null);

  const stopTracking = useCallback(() => {
    if (intervalRef.current) clearInterval(intervalRef.current);
    intervalRef.current = null;
  }, []);

  const tick = useCallback(async () => {
    const m = marketRef.current;
    if (!m) return;
    const rts = resolutionTsRef.current;
    const el = getSecondsElapsed(rts);
    const rem = getSecondsRemaining(rts);
    setElapsed(el);
    setRemaining(rem);

    // Find UP token id
    let upTokenId = null;
    let downTokenId = null;
    if (m.tokens && m.tokens.length > 0) {
      for (const t of m.tokens) {
        const outcome = (t.outcome ?? "").toLowerCase();
        if (outcome === "up") upTokenId = t.token_id ?? t.tokenId ?? t;
        if (outcome === "down") downTokenId = t.token_id ?? t.tokenId ?? t;
      }
      // fallback: first=UP, second=DOWN
      if (!upTokenId && m.tokens[0]) upTokenId = m.tokens[0].token_id ?? m.tokens[0].tokenId ?? m.tokens[0];
      if (!downTokenId && m.tokens[1]) downTokenId = m.tokens[1].token_id ?? m.tokens[1].tokenId ?? m.tokens[1];
    }

    if (!upTokenId) return;

    try {
      const [upPrice, downPrice] = await Promise.all([
        fetchMidpoint(String(upTokenId)),
        downTokenId ? fetchMidpoint(String(downTokenId)) : Promise.resolve(null),
      ]);

      const point = {
        t: Math.floor(Date.now() / 1000),
        elapsed: el,
        up: upPrice,
        down: downPrice ?? (upPrice != null ? 1 - upPrice : null),
      };
      historyRef.current = [...historyRef.current, point];
      setPriceHistory([...historyRef.current]);
      setCurrentUp(upPrice);

      if (rem <= 0) {
        setStatus("resolved");
        stopTracking();
      }
    } catch (e) {
      console.error("tick error", e);
    }
  }, [stopTracking]);

  const startTracking = useCallback(async (slugOverride) => {
    stopTracking();
    setStatus("loading");
    setErrorMsg("");
    setPriceHistory([]);
    historyRef.current = [];
    setOutcome(null);

    const rts = getCurrentMarketTimestamp();
    resolutionTsRef.current = rts;
    const slug = slugOverride || getMarketSlug(rts);

    const m = await fetchMarketBySlug(slug);
    if (!m || m.error) {
      setErrorMsg(`Market not found: ${slug}. Try a different timestamp or check Polymarket.`);
      setStatus("error");
      return;
    }
    marketRef.current = m;
    setMarket(m);
    setStatus("tracking");

    await tick();
    intervalRef.current = setInterval(tick, POLL_MS);
  }, [stopTracking, tick]);

  // Auto-start on mount
  useEffect(() => {
    startTracking();
    return stopTracking;
  }, []); // eslint-disable-line

  // Auto-rotate to next market when resolved
  useEffect(() => {
    if (status !== "resolved") return;
    const timer = setTimeout(() => startTracking(), 5000);
    return () => clearTimeout(timer);
  }, [status, startTracking]);

  const handleSave = () => {
    if (!market || historyRef.current.length === 0) return;
    const session = {
      slug: market.slug,
      resolutionTs: resolutionTsRef.current,
      question: market.question,
      outcome,
      priceHistory: historyRef.current,
      savedAt: Date.now(),
    };
    onSaveSession(session);
  };

  const chartData = priceHistory.map((p) => ({
    elapsed: p.elapsed,
    UP: p.up != null ? +(p.up * 100).toFixed(2) : null,
    DOWN: p.down != null ? +(p.down * 100).toFixed(2) : null,
  }));

  return (
    <div className="space-y-4">
      {/* Header bar */}
      <div className="flex flex-wrap items-center gap-3">
        <div className="flex-1 min-w-0">
          <p className="text-xs text-slate-400 truncate">{market?.slug ?? "Searching for market…"}</p>
          <p className="text-sm text-slate-300 truncate">{market?.question ?? ""}</p>
        </div>
        <div className="flex gap-2 items-center">
          <span className={`px-2 py-0.5 rounded text-xs font-bold ${
            status === "tracking" ? "bg-green-900 text-green-300" :
            status === "resolved" ? "bg-yellow-900 text-yellow-300" :
            status === "loading" ? "bg-blue-900 text-blue-300" :
            "bg-red-900 text-red-300"
          }`}>{status.toUpperCase()}</span>
          <button onClick={() => startTracking()} className="px-3 py-1 bg-indigo-700 hover:bg-indigo-600 rounded text-xs font-semibold">
            Refresh
          </button>
        </div>
      </div>

      {/* Manual slug input */}
      <div className="flex gap-2">
        <input
          value={manualSlug}
          onChange={e => setManualSlug(e.target.value)}
          placeholder="Custom slug: btc-up-or-down-in-5-minutes-1771464600"
          className="flex-1 bg-slate-800 border border-slate-600 rounded px-3 py-1.5 text-sm text-slate-200 placeholder-slate-500"
        />
        <button
          onClick={() => startTracking(manualSlug || undefined)}
          className="px-4 py-1.5 bg-slate-700 hover:bg-slate-600 rounded text-sm font-semibold"
        >
          Load
        </button>
      </div>

      {errorMsg && <p className="text-red-400 text-sm">{errorMsg}</p>}

      {/* Stats */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <StatCard label="UP Price" value={currentUp != null ? `$${currentUp.toFixed(3)}` : "—"} color="text-green-400" />
        <StatCard label="DOWN Price" value={currentUp != null ? `$${(1-currentUp).toFixed(3)}` : "—"} color="text-red-400" />
        <StatCard label="Elapsed" value={fmtSeconds(elapsed)} color="text-blue-400" />
        <StatCard label="Remaining" value={fmtSeconds(remaining)} color="text-orange-400" />
      </div>

      {/* Price chart */}
      <div className="bg-slate-900 rounded-xl p-4" style={{ height: 280 }}>
        {chartData.length === 0 ? (
          <div className="h-full flex items-center justify-center text-slate-500 text-sm">Waiting for price data…</div>
        ) : (
          <ResponsiveContainer width="100%" height="100%">
            <LineChart data={chartData}>
              <CartesianGrid strokeDasharray="3 3" stroke="#1e293b" />
              <XAxis dataKey="elapsed" tickFormatter={v => `${v}s`} stroke="#475569" tick={{ fontSize: 11 }} />
              <YAxis domain={[0, 100]} tickFormatter={v => `${v}¢`} stroke="#475569" tick={{ fontSize: 11 }} />
              <Tooltip
                formatter={(v, name) => [`${v}¢`, name]}
                labelFormatter={v => `${v}s elapsed`}
                contentStyle={{ background: "#1e293b", border: "none", borderRadius: 8 }}
              />
              <ReferenceLine y={50} stroke="#475569" strokeDasharray="4 2" />
              <Line type="monotone" dataKey="UP" stroke="#4ade80" dot={false} strokeWidth={2} />
              <Line type="monotone" dataKey="DOWN" stroke="#f87171" dot={false} strokeWidth={2} />
            </LineChart>
          </ResponsiveContainer>
        )}
      </div>

      {/* Save controls */}
      <div className="flex flex-wrap gap-3 items-center">
        <span className="text-sm text-slate-400">Mark outcome:</span>
        <button
          onClick={() => setOutcome("UP")}
          className={`px-4 py-1.5 rounded font-bold text-sm transition ${outcome === "UP" ? "bg-green-500 text-white" : "bg-slate-800 hover:bg-green-900 text-green-400"}`}
        >▲ UP</button>
        <button
          onClick={() => setOutcome("DOWN")}
          className={`px-4 py-1.5 rounded font-bold text-sm transition ${outcome === "DOWN" ? "bg-red-500 text-white" : "bg-slate-800 hover:bg-red-900 text-red-400"}`}
        >▼ DOWN</button>
        <button
          onClick={handleSave}
          disabled={priceHistory.length === 0}
          className="ml-auto px-5 py-1.5 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 rounded font-semibold text-sm"
        >
          💾 Save Session
        </button>
      </div>
    </div>
  );
}

function StatCard({ label, value, color }) {
  return (
    <div className="bg-slate-900 rounded-xl p-3 text-center">
      <p className="text-xs text-slate-500 mb-1">{label}</p>
      <p className={`text-xl font-bold font-mono ${color}`}>{value}</p>
    </div>
  );
}
'@ | Set-Content "src/components/LiveTracker.js"

# ── src/components/BacktestEngine.js ─────────────────────────────────────────
@'
"use client";
import { useState, useRef } from "react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, CartesianGrid, ResponsiveContainer,
  LineChart, Line, Legend, Cell,
} from "recharts";

export default function BacktestEngine({ sessions }) {
  const [side, setSide] = useState("UP"); // UP | DOWN | BOTH
  const [priceMin, setPriceMin] = useState(0.1);
  const [priceMax, setPriceMax] = useState(0.9);
  const [elapsedMin, setElapsedMin] = useState(0);
  const [elapsedMax, setElapsedMax] = useState(300);
  const [groupBy, setGroupBy] = useState("priceRange"); // priceRange | elapsedRange
  const [results, setResults] = useState(null);

  const runBacktest = () => {
    const trades = [];

    for (const session of sessions) {
      if (!session.outcome) continue; // skip sessions without outcome marked
      const history = session.priceHistory ?? [];

      for (const point of history) {
        const el = point.elapsed ?? 0;
        if (el < elapsedMin || el > elapsedMax) continue;

        const price = side === "DOWN" ? point.down : point.up;
        if (price == null) continue;
        if (price < priceMin || price > priceMax) continue;

        // "Buy" this side at this moment
        const win = session.outcome === (side === "DOWN" ? "DOWN" : "UP");
        trades.push({
          slug: session.slug,
          elapsed: el,
          price,
          side,
          outcome: session.outcome,
          win,
        });
      }
    }

    if (trades.length === 0) {
      setResults({ trades: [], summary: null, chart: [] });
      return;
    }

    const wins = trades.filter(t => t.win).length;
    const winRate = wins / trades.length;

    // Build chart data by group
    let chartData = [];
    if (groupBy === "priceRange") {
      const buckets = {};
      for (const t of trades) {
        const bucket = `${Math.floor(t.price * 10) * 10}¢`;
        if (!buckets[bucket]) buckets[bucket] = { wins: 0, total: 0 };
        buckets[bucket].total++;
        if (t.win) buckets[bucket].wins++;
      }
      chartData = Object.entries(buckets)
        .sort((a, b) => parseFloat(a[0]) - parseFloat(b[0]))
        .map(([price, { wins, total }]) => ({
          label: price,
          winRate: +((wins / total) * 100).toFixed(1),
          total,
          wins,
        }));
    } else {
      // Group by 30s elapsed buckets
      const buckets = {};
      for (const t of trades) {
        const bucket = `${Math.floor(t.elapsed / 30) * 30}s`;
        if (!buckets[bucket]) buckets[bucket] = { wins: 0, total: 0 };
        buckets[bucket].total++;
        if (t.win) buckets[bucket].wins++;
      }
      chartData = Object.entries(buckets)
        .sort((a, b) => parseInt(a[0]) - parseInt(b[0]))
        .map(([label, { wins, total }]) => ({
          label,
          winRate: +((wins / total) * 100).toFixed(1),
          total,
          wins,
        }));
    }

    setResults({ trades, summary: { total: trades.length, wins, winRate }, chart: chartData });
  };

  return (
    <div className="space-y-6">
      {/* Config */}
      <div className="bg-slate-900 rounded-xl p-5 space-y-4">
        <h2 className="text-lg font-bold text-slate-100">Backtest Configuration</h2>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className="text-xs text-slate-400 block mb-1">Buy Side</label>
            <div className="flex gap-2">
              {["UP","DOWN","BOTH"].map(s => (
                <button
                  key={s}
                  onClick={() => setSide(s)}
                  className={`flex-1 py-2 rounded font-bold text-sm ${side===s ? "bg-indigo-600 text-white" : "bg-slate-800 hover:bg-slate-700 text-slate-300"}`}
                >{s}</button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs text-slate-400 block mb-1">Group Results By</label>
            <div className="flex gap-2">
              {[["priceRange","Price Range"],["elapsedRange","Time Elapsed"]].map(([v,l]) => (
                <button
                  key={v}
                  onClick={() => setGroupBy(v)}
                  className={`flex-1 py-2 rounded text-sm ${groupBy===v ? "bg-indigo-600 text-white" : "bg-slate-800 hover:bg-slate-700 text-slate-300"}`}
                >{l}</button>
              ))}
            </div>
          </div>

          <div>
            <label className="text-xs text-slate-400 block mb-1">Entry Price Range (0–1)</label>
            <div className="flex gap-2 items-center">
              <input type="number" min="0" max="1" step="0.01" value={priceMin}
                onChange={e => setPriceMin(+e.target.value)}
                className="w-24 bg-slate-800 border border-slate-600 rounded px-2 py-1.5 text-sm text-slate-200" />
              <span className="text-slate-500">to</span>
              <input type="number" min="0" max="1" step="0.01" value={priceMax}
                onChange={e => setPriceMax(+e.target.value)}
                className="w-24 bg-slate-800 border border-slate-600 rounded px-2 py-1.5 text-sm text-slate-200" />
            </div>
            <p className="text-xs text-slate-500 mt-1">e.g. 0.55 to 0.65 = buy near 60¢</p>
          </div>

          <div>
            <label className="text-xs text-slate-400 block mb-1">Time Elapsed Range (seconds)</label>
            <div className="flex gap-2 items-center">
              <input type="number" min="0" max="300" step="1" value={elapsedMin}
                onChange={e => setElapsedMin(+e.target.value)}
                className="w-24 bg-slate-800 border border-slate-600 rounded px-2 py-1.5 text-sm text-slate-200" />
              <span className="text-slate-500">to</span>
              <input type="number" min="0" max="300" step="1" value={elapsedMax}
                onChange={e => setElapsedMax(+e.target.value)}
                className="w-24 bg-slate-800 border border-slate-600 rounded px-2 py-1.5 text-sm text-slate-200" />
            </div>
            <p className="text-xs text-slate-500 mt-1">300s = end of market. 0s = market open</p>
          </div>
        </div>

        <button
          onClick={runBacktest}
          disabled={sessions.length === 0}
          className="w-full py-3 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 rounded-xl font-bold text-base"
        >
          ▶ Run Backtest ({sessions.length} session{sessions.length !== 1 ? "s" : ""} loaded)
        </button>
      </div>

      {/* Results */}
      {results && (
        <div className="space-y-4">
          {results.summary ? (
            <>
              <div className="grid grid-cols-3 gap-3">
                <SummaryCard label="Total Trades" value={results.summary.total} color="text-blue-400" />
                <SummaryCard label="Wins" value={results.summary.wins} color="text-green-400" />
                <SummaryCard
                  label="Win Rate"
                  value={`${(results.summary.winRate * 100).toFixed(1)}%`}
                  color={results.summary.winRate >= 0.5 ? "text-green-400" : "text-red-400"}
                />
              </div>

              {results.chart.length > 0 && (
                <div className="bg-slate-900 rounded-xl p-4" style={{ height: 300 }}>
                  <p className="text-xs text-slate-400 mb-3">Win Rate by {groupBy === "priceRange" ? "Entry Price" : "Elapsed Time"}</p>
                  <ResponsiveContainer width="100%" height="100%">
                    <BarChart data={results.chart}>
                      <CartesianGrid strokeDasharray="3 3" stroke="#1e293b" />
                      <XAxis dataKey="label" stroke="#475569" tick={{ fontSize: 11 }} />
                      <YAxis domain={[0, 100]} tickFormatter={v => `${v}%`} stroke="#475569" tick={{ fontSize: 11 }} />
                      <Tooltip
                        formatter={(v, name) => [name === "winRate" ? `${v}%` : v, name === "winRate" ? "Win Rate" : "Trades"]}
                        contentStyle={{ background: "#1e293b", border: "none", borderRadius: 8 }}
                      />
                      <Bar dataKey="winRate" radius={[4,4,0,0]}>
                        {results.chart.map((entry, i) => (
                          <Cell key={i} fill={entry.winRate >= 50 ? "#4ade80" : "#f87171"} />
                        ))}
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              )}

              {/* Trade log */}
              <div className="bg-slate-900 rounded-xl p-4">
                <p className="text-xs text-slate-400 mb-3">Trade Log (last 50)</p>
                <div className="overflow-x-auto">
                  <table className="w-full text-xs text-slate-300">
                    <thead>
                      <tr className="text-slate-500 border-b border-slate-800">
                        <th className="text-left py-1 pr-4">Slug</th>
                        <th className="text-right pr-4">Elapsed</th>
                        <th className="text-right pr-4">Price</th>
                        <th className="text-right pr-4">Outcome</th>
                        <th className="text-right">Result</th>
                      </tr>
                    </thead>
                    <tbody>
                      {results.trades.slice(-50).reverse().map((t, i) => (
                        <tr key={i} className="border-b border-slate-800/50 hover:bg-slate-800/30">
                          <td className="py-1 pr-4 truncate max-w-xs font-mono text-slate-500">{t.slug}</td>
                          <td className="text-right pr-4">{t.elapsed}s</td>
                          <td className="text-right pr-4">{(t.price*100).toFixed(1)}¢</td>
                          <td className={`text-right pr-4 font-bold ${t.outcome==="UP"?"text-green-400":"text-red-400"}`}>{t.outcome}</td>
                          <td className={`text-right font-bold ${t.win?"text-green-400":"text-red-400"}`}>{t.win?"✓ WIN":"✗ LOSS"}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            </>
          ) : (
            <div className="bg-slate-900 rounded-xl p-6 text-center text-slate-400">
              No matching trades found. Try widening your price/time range, or make sure sessions have outcomes marked.
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function SummaryCard({ label, value, color }) {
  return (
    <div className="bg-slate-900 rounded-xl p-4 text-center">
      <p className="text-xs text-slate-500 mb-1">{label}</p>
      <p className={`text-2xl font-bold font-mono ${color}`}>{value}</p>
    </div>
  );
}
'@ | Set-Content "src/components/BacktestEngine.js"

# ── src/app/page.js ──────────────────────────────────────────────────────────
@'
"use client";
import { useState, useCallback, useRef } from "react";
import Link from "next/link";
import LiveTracker from "../components/LiveTracker";

const STORAGE_KEY = "pm_sessions";

function loadSessions() {
  if (typeof window === "undefined") return [];
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "[]"); } catch { return []; }
}

function saveSessions(sessions) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(sessions));
}

export default function Home() {
  const [sessions, setSessions] = useState(() => loadSessions());

  const onSaveSession = useCallback((session) => {
    setSessions(prev => {
      const next = [...prev.filter(s => s.slug !== session.slug), session];
      saveSessions(next);
      return next;
    });
    alert(`✅ Session saved: ${session.slug}\n${session.priceHistory.length} data points`);
  }, []);

  const downloadSessions = () => {
    if (sessions.length === 0) return;
    const blob = new Blob([JSON.stringify(sessions, null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `pm_btc5m_${Date.now()}.json`;
    a.click();
  };

  const clearSessions = () => {
    if (!confirm("Clear all saved sessions from this browser?")) return;
    setSessions([]);
    localStorage.removeItem(STORAGE_KEY);
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100">
      {/* Nav */}
      <nav className="border-b border-slate-800 bg-slate-900/80 backdrop-blur sticky top-0 z-10">
        <div className="max-w-5xl mx-auto px-4 py-3 flex items-center gap-4">
          <span className="font-bold text-lg">⚡ PM BTC 5m</span>
          <span className="text-slate-500 text-sm hidden sm:block">Polymarket Tracker & Backtest</span>
          <div className="ml-auto flex gap-3">
            <Link href="/" className="text-sm font-semibold text-indigo-400">Live</Link>
            <Link href="/backtest" className="text-sm text-slate-400 hover:text-slate-200">Backtest</Link>
          </div>
        </div>
      </nav>

      <main className="max-w-5xl mx-auto px-4 py-6 space-y-6">
        {/* Live tracker */}
        <div className="bg-slate-900/60 border border-slate-800 rounded-2xl p-5">
          <h1 className="text-lg font-bold text-slate-100 mb-4">🔴 Live Tracker</h1>
          <LiveTracker onSaveSession={onSaveSession} />
        </div>

        {/* Saved sessions */}
        <div className="bg-slate-900/60 border border-slate-800 rounded-2xl p-5">
          <div className="flex items-center gap-3 mb-4">
            <h2 className="text-lg font-bold text-slate-100">Saved Sessions ({sessions.length})</h2>
            <div className="ml-auto flex gap-2">
              <button onClick={downloadSessions} disabled={sessions.length === 0}
                className="px-4 py-1.5 bg-indigo-700 hover:bg-indigo-600 disabled:opacity-40 rounded-lg text-sm font-semibold">
                ⬇ Download JSON
              </button>
              <button onClick={clearSessions} disabled={sessions.length === 0}
                className="px-4 py-1.5 bg-red-900 hover:bg-red-800 disabled:opacity-40 rounded-lg text-sm font-semibold">
                Clear
              </button>
            </div>
          </div>
          {sessions.length === 0 ? (
            <p className="text-slate-500 text-sm">No sessions saved yet. Track a market and click "Save Session".</p>
          ) : (
            <div className="space-y-2 max-h-64 overflow-y-auto">
              {[...sessions].reverse().map((s, i) => (
                <div key={i} className="flex items-center gap-3 bg-slate-800/60 rounded-lg px-3 py-2 text-sm">
                  <span className="font-mono text-slate-400 truncate flex-1">{s.slug}</span>
                  <span className="text-slate-500">{s.priceHistory?.length ?? 0} pts</span>
                  {s.outcome ? (
                    <span className={`font-bold ${s.outcome==="UP"?"text-green-400":"text-red-400"}`}>{s.outcome}</span>
                  ) : (
                    <span className="text-slate-600">No outcome</span>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>
      </main>
    </div>
  );
}
'@ | Set-Content "src/app/page.js"

# ── src/app/backtest/page.js ──────────────────────────────────────────────────
@'
"use client";
import { useState, useCallback } from "react";
import Link from "next/link";
import BacktestEngine from "../../components/BacktestEngine";

export default function BacktestPage() {
  const [sessions, setSessions] = useState([]);
  const [dragOver, setDragOver] = useState(false);

  const processFiles = useCallback(async (files) => {
    const loaded = [];
    for (const file of Array.from(files)) {
      try {
        const text = await file.text();
        const data = JSON.parse(text);
        // data can be array of sessions or a single session
        const arr = Array.isArray(data) ? data : [data];
        loaded.push(...arr);
      } catch (e) {
        alert(`Failed to parse ${file.name}: ${e.message}`);
      }
    }
    setSessions(prev => {
      const all = [...prev, ...loaded];
      // dedupe by slug+elapsed (keep last)
      const map = new Map(all.map(s => [s.slug, s]));
      return [...map.values()];
    });
  }, []);

  const onFileInput = (e) => processFiles(e.target.files);

  const onDrop = (e) => {
    e.preventDefault();
    setDragOver(false);
    processFiles(e.dataTransfer.files);
  };

  // Also load from localStorage
  const loadFromBrowser = () => {
    try {
      const data = JSON.parse(localStorage.getItem("pm_sessions") ?? "[]");
      setSessions(prev => {
        const all = [...prev, ...data];
        const map = new Map(all.map(s => [s.slug, s]));
        return [...map.values()];
      });
    } catch { alert("No sessions in browser storage."); }
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100">
      <nav className="border-b border-slate-800 bg-slate-900/80 backdrop-blur sticky top-0 z-10">
        <div className="max-w-5xl mx-auto px-4 py-3 flex items-center gap-4">
          <span className="font-bold text-lg">⚡ PM BTC 5m</span>
          <div className="ml-auto flex gap-3">
            <Link href="/" className="text-sm text-slate-400 hover:text-slate-200">Live</Link>
            <Link href="/backtest" className="text-sm font-semibold text-indigo-400">Backtest</Link>
          </div>
        </div>
      </nav>

      <main className="max-w-5xl mx-auto px-4 py-6 space-y-6">
        {/* Upload */}
        <div className="bg-slate-900/60 border border-slate-800 rounded-2xl p-5">
          <h1 className="text-lg font-bold mb-4">📂 Load Session Data</h1>
          <div
            onDragOver={e => { e.preventDefault(); setDragOver(true); }}
            onDragLeave={() => setDragOver(false)}
            onDrop={onDrop}
            className={`border-2 border-dashed rounded-xl p-8 text-center transition ${dragOver ? "border-indigo-400 bg-indigo-900/20" : "border-slate-700 hover:border-slate-500"}`}
          >
            <p className="text-slate-400 mb-3">Drop JSON session files here, or</p>
            <label className="cursor-pointer px-5 py-2 bg-indigo-700 hover:bg-indigo-600 rounded-lg text-sm font-semibold">
              Browse Files
              <input type="file" accept=".json" multiple className="hidden" onChange={onFileInput} />
            </label>
            <p className="text-xs text-slate-600 mt-3">One file can contain multiple sessions (exported as array)</p>
          </div>

          <div className="mt-3 flex gap-3 items-center">
            <button onClick={loadFromBrowser} className="px-4 py-2 bg-slate-800 hover:bg-slate-700 rounded-lg text-sm">
              📥 Load from This Browser
            </button>
            {sessions.length > 0 && (
              <>
                <span className="text-slate-400 text-sm">{sessions.length} sessions loaded</span>
                <button onClick={() => setSessions([])} className="ml-auto text-xs text-red-400 hover:text-red-300">Clear All</button>
              </>
            )}
          </div>

          {sessions.length > 0 && (
            <div className="mt-3 grid grid-cols-1 sm:grid-cols-3 gap-2 max-h-40 overflow-y-auto">
              {sessions.map((s, i) => (
                <div key={i} className="bg-slate-800/60 rounded-lg px-3 py-1.5 flex items-center gap-2 text-xs">
                  <span className="truncate flex-1 font-mono text-slate-400">{s.slug?.replace("btc-up-or-down-in-5-minutes-","") ?? "?"}</span>
                  <span className="text-slate-500">{s.priceHistory?.length ?? 0}pts</span>
                  {s.outcome && <span className={`font-bold ${s.outcome==="UP"?"text-green-400":"text-red-400"}`}>{s.outcome[0]}</span>}
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Backtest engine */}
        <BacktestEngine sessions={sessions} />
      </main>
    </div>
  );
}
'@ | Set-Content "src/app/backtest/page.js"

# ── tracker.py ────────────────────────────────────────────────────────────────
@'
#!/usr/bin/env python3
"""
Polymarket BTC UP/DOWN 5m background tracker.
Saves price history to JSON files so you can upload to the backtest website.

Usage:
  pip install requests
  python tracker.py

Files are saved as: pm_session_<slug>.json
"""

import json, math, time, os, sys, threading
from datetime import datetime

try:
    import requests
except ImportError:
    print("Install requests first: pip install requests")
    sys.exit(1)

GAMMA_API = "https://gamma-api.polymarket.com"
CLOB_API  = "https://clob.polymarket.com"
POLL_S    = 2  # poll every 2 seconds

def current_resolution_ts():
    now = int(time.time())
    return math.ceil(now / 300) * 300

def market_slug(ts):
    return f"btc-up-or-down-in-5-minutes-{ts}"

def fetch_market(slug):
    try:
        r = requests.get(f"{GAMMA_API}/markets", params={"slug": slug}, timeout=5)
        data = r.json()
        if isinstance(data, list) and data:
            return data[0]
        if isinstance(data, dict) and data:
            return data
    except Exception as e:
        print(f"  [WARN] fetch_market error: {e}")
    return None

def find_token_ids(market):
    tokens = market.get("tokens", [])
    up_id, down_id = None, None
    for t in tokens:
        outcome = (t.get("outcome") or "").lower()
        tid = t.get("token_id") or t.get("tokenId")
        if outcome == "up": up_id = tid
        elif outcome == "down": down_id = tid
    # fallback
    if not up_id and tokens: up_id = tokens[0].get("token_id") or tokens[0].get("tokenId")
    if not down_id and len(tokens) > 1: down_id = tokens[1].get("token_id") or tokens[1].get("tokenId")
    return str(up_id) if up_id else None, str(down_id) if down_id else None

def fetch_midpoint(token_id):
    if not token_id:
        return None
    try:
        r = requests.get(f"{CLOB_API}/midpoints", params={"token_id": token_id}, timeout=5)
        data = r.json()
        mid = data.get("mid") or data.get(token_id)
        return float(mid) if mid else None
    except:
        return None

def save_session(session, output_dir="."):
    slug = session["slug"]
    filename = os.path.join(output_dir, f"pm_session_{slug}.json")
    # If file exists, load and merge (avoid duplicates by timestamp)
    if os.path.exists(filename):
        try:
            with open(filename) as f:
                existing = json.load(f)
            existing_ts = {p["t"] for p in existing.get("priceHistory", [])}
            for p in session["priceHistory"]:
                if p["t"] not in existing_ts:
                    existing["priceHistory"].append(p)
            session = existing
        except:
            pass
    with open(filename, "w") as f:
        json.dump(session, f, indent=2)
    return filename

def track_market(slug, resolution_ts, output_dir="."):
    print(f"\n{'='*60}")
    print(f"Tracking: {slug}")
    print(f"Resolution: {datetime.fromtimestamp(resolution_ts)}")
    print(f"{'='*60}")

    market = fetch_market(slug)
    if not market:
        print(f"  [ERROR] Market not found: {slug}")
        return None

    up_id, down_id = find_token_ids(market)
    print(f"  UP token:   {up_id}")
    print(f"  DOWN token: {down_id}")

    session = {
        "slug": slug,
        "resolutionTs": resolution_ts,
        "question": market.get("question", ""),
        "outcome": None,
        "priceHistory": [],
    }

    while True:
        now = int(time.time())
        elapsed = max(0, min(300, 300 - (resolution_ts - now)))
        remaining = max(0, resolution_ts - now)

        up_price = fetch_midpoint(up_id)
        down_price = fetch_midpoint(down_id)
        if up_price is None and down_price is not None:
            up_price = 1 - down_price
        if down_price is None and up_price is not None:
            down_price = 1 - up_price

        point = {
            "t": now,
            "elapsed": elapsed,
            "up": up_price,
            "down": down_price,
        }
        session["priceHistory"].append(point)

        up_str = f"{up_price:.4f}" if up_price is not None else "N/A"
        down_str = f"{down_price:.4f}" if down_price is not None else "N/A"
        print(f"  [{elapsed:>3}s elapsed | {remaining:>3}s left] UP={up_str}  DOWN={down_str}  pts={len(session['priceHistory'])}", end="\r")

        # Save every 30 data points
        if len(session["priceHistory"]) % 30 == 0:
            save_session(session, output_dir)

        if remaining <= 0:
            print()
            print(f"  Market resolved! ({len(session['priceHistory'])} points collected)")
            break

        time.sleep(POLL_S)

    # Final save
    filename = save_session(session, output_dir)
    print(f"  Saved: {filename}")

    # Ask for outcome
    print("\n  What was the outcome? (u=UP / d=DOWN / skip=Enter): ", end="", flush=True)
    try:
        answer = input().strip().lower()
        if answer in ("u", "up"):
            session["outcome"] = "UP"
        elif answer in ("d", "down"):
            session["outcome"] = "DOWN"
        if session["outcome"]:
            save_session(session, output_dir)
            print(f"  Outcome '{session['outcome']}' saved.")
    except:
        pass

    return session

def main():
    print("Polymarket BTC 5m Tracker")
    print(f"Saving files to: {os.path.abspath('.')}")
    print("Press Ctrl+C to stop.\n")

    while True:
        ts = current_resolution_ts()
        slug = market_slug(ts)

        # Wait if we're in the gap between markets
        now = int(time.time())
        if ts - now > 300:
            print(f"Waiting for market {slug} (starts in {ts - now - 300}s)...")
            time.sleep(5)
            continue

        track_market(slug, ts)

        # Small gap before next market
        time.sleep(3)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nTracker stopped.")
'@ | Set-Content "tracker.py"

# ── README.md ─────────────────────────────────────────────────────────────────
@'
# Polymarket BTC 5m Backtest

Track and backtest Polymarket's BTC UP/DOWN 5-minute markets.

## Quick Start

```bash
npm install
npm run dev
# Open http://localhost:3000
```

## Deploy to Vercel

```bash
git init && git add . && git commit -m "init"
# Push to GitHub, then import repo on vercel.com
```

## Python Background Tracker

Use this when the browser tab is not open:

```bash
pip install requests
python tracker.py
```

Files are saved as `pm_session_<slug>.json`.  
Upload them on the **Backtest** page.

## How It Works

### Live Tracker (/)
- Auto-detects the current BTC 5m market slug
- Polls Polymarket CLOB API every ~1.5 seconds
- Shows real-time price chart for UP and DOWN tokens
- Click **Save Session** to store to browser localStorage
- Mark the **Outcome** (UP/DOWN) after resolution
- Download all sessions as a JSON file

### Backtest (/backtest)
- Upload one or more JSON session files
- Or click "Load from This Browser" to use saved sessions
- Configure:
  - **Side** — are you buying UP, DOWN, or both?
  - **Price range** — only count entries where the price was in range
  - **Elapsed range** — only count entries at a certain point in the market
  - **Group by** — view win rate by price bucket or time bucket
- Results show win rate, trade count, and a bar chart

## Market Slug Format

`btc-up-or-down-in-5-minutes-{resolution_timestamp}`

Resolution timestamps are every 300 seconds:
- 1771464300, 1771464600, 1771464900, …
'@ | Set-Content "README.md"

Write-Host ""
Write-Host "✅ All files created!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  cd $project"
Write-Host "  npm install"
Write-Host "  npm run dev"
Write-Host ""
Write-Host "Deploy to Vercel:" -ForegroundColor Yellow
Write-Host "  git init && git add . && git commit -m 'init'"
Write-Host "  # Push to GitHub -> import on vercel.com"
Write-Host ""
Write-Host "Python tracker (background data collection):" -ForegroundColor Yellow
Write-Host "  pip install requests"
Write-Host "  python tracker.py"