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
