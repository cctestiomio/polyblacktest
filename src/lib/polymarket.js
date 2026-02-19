export function getCurrentMarketTimestamp() {
  const now = Math.floor(Date.now() / 1000);
  // Guard: if exactly on boundary, step 1s forward so ceil stays in this window
  const adjusted = (now % 300 === 0) ? now + 1 : now;
  return Math.ceil(adjusted / 300) * 300;
}

export function getMarketSlug(ts) {
  return `btc-updown-5m-${ts}`;
}

export function getSecondsRemaining(resolutionTs) {
  return Math.max(0, resolutionTs - Math.floor(Date.now() / 1000));
}

export function getSecondsElapsed(resolutionTs) {
  return Math.min(300, 300 - getSecondsRemaining(resolutionTs));
}

export async function fetchMarketBySlug(slug) {
  try {
    const res = await fetch(`/api/market?slug=${encodeURIComponent(slug)}`);
    if (!res.ok) return null;
    return res.json();
  } catch { return null; }
}

export async function fetchMidpoint(tokenId) {
  if (!tokenId) return null;
  try {
    const res = await fetch(`/api/midpoint?token_id=${encodeURIComponent(tokenId)}`);
    if (!res.ok) return null;
    const data = await res.json();
    const raw = data.mid;
    if (raw == null) return null;
    const f = parseFloat(raw);
    return (isFinite(f) && f > 0.001) ? f : null;
  } catch { return null; }
}

export function resolveTokenIds(market) {
  let upId = null, downId = null;
  const tokens = market.tokens ?? [];
  for (const t of tokens) {
    const o  = (t.outcome ?? "").toLowerCase();
    const id = t.token_id ?? t.tokenId;
    if (!id) continue;
    if (o === "up")   upId   = String(id);
    if (o === "down") downId = String(id);
  }
  if (!upId   && tokens[0]) upId   = String(tokens[0].token_id ?? tokens[0].tokenId ?? tokens[0]);
  if (!downId && tokens[1]) downId = String(tokens[1].token_id ?? tokens[1].tokenId ?? tokens[1]);
  return { upId, downId };
}

export function detectOutcome(up, down) {
  if (up   != null && up   >= 0.95) return "UP";
  if (down != null && down >= 0.95) return "DOWN";
  if (up   != null && down != null) return up > down ? "UP" : "DOWN";
  return null;
}
