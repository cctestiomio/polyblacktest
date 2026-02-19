export function getCurrentMarketTimestamp() {
  const now = Math.floor(Date.now() / 1000);
  const adjusted = (now % 300 === 0) ? now + 1 : now;
  return Math.ceil(adjusted / 300) * 300;
}
export function getMarketSlug(ts) { return `btc-updown-5m-${ts}`; }
export function getSecondsRemaining(ts) { return Math.max(0, ts - Math.floor(Date.now() / 1000)); }
export function getSecondsElapsed(ts)   { return Math.min(300, 300 - getSecondsRemaining(ts)); }

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
    const f = parseFloat(data.mid);
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

/**
 * Detect outcome with confidence level.
 * Returns { outcome: "UP"|"DOWN"|null, confident: boolean }
 * 
 * "Confident" = one side is >= 0.90 (approaching resolution price).
 * If neither side is confident, outcome is a guess and should be flagged.
 */
export function detectOutcome(up, down) {
  const CONFIDENT_THRESHOLD = 0.90;
  if (up   != null && up   >= CONFIDENT_THRESHOLD) return { outcome: "UP",   confident: true };
  if (down != null && down >= CONFIDENT_THRESHOLD) return { outcome: "DOWN", confident: true };
  // Low confidence — prices haven't settled yet (market resolved on-chain but CLOB not updated)
  if (up != null && down != null) {
    return { outcome: up > down ? "UP" : "DOWN", confident: false };
  }
  return { outcome: null, confident: false };
}

/**
 * Poll for resolved outcome — after resolution, retry until one side hits 0.90+
 * or until maxAttempts is reached. Returns "UP", "DOWN", or null.
 */
export async function pollForOutcome(upId, downId, maxAttempts = 20, intervalMs = 3000) {
  for (let i = 0; i < maxAttempts; i++) {
    if (i > 0) await new Promise(r => setTimeout(r, intervalMs));
    const [up, down] = await Promise.all([
      fetchMidpoint(upId),
      downId ? fetchMidpoint(downId) : Promise.resolve(null),
    ]);
    const upP   = up;
    const downP = down ?? (up != null ? parseFloat((1 - up).toFixed(6)) : null);
    const { outcome, confident } = detectOutcome(upP, downP);
    if (confident) return outcome;
  }
  return null; // could not determine
}
