export function getCurrentSlugTimestamp() {
  return Math.floor(Date.now() / 1000 / 300) * 300;
}
export function getResolutionTs(slugTs) { return slugTs + 300; }
export function getMarketSlug(slugTs)   { return `btc-updown-5m-${slugTs}`; }
export function getSecondsRemaining(slugTs) {
  return Math.max(0, getResolutionTs(slugTs) - Math.floor(Date.now() / 1000));
}
export function getSecondsElapsed(slugTs) {
  return Math.min(300, 300 - getSecondsRemaining(slugTs));
}

export async function fetchMarketBySlug(slug) {
  try {
    const res = await fetch(`/api/market?slug=${encodeURIComponent(slug)}`);
    if (!res.ok) return null;
    return res.json();
  } catch { return null; }
}

export function resolveTokenIds(market) {
  let upId = null, downId = null;
  for (const t of market.tokens ?? []) {
    const o  = (t.outcome ?? "").toLowerCase();
    const id = t.token_id ?? t.tokenId;
    if (!id) continue;
    if (o === "up")   upId   = String(id);
    if (o === "down") downId = String(id);
  }
  const tokens = market.tokens ?? [];
  if (!upId   && tokens[0]) upId   = String(tokens[0].token_id ?? tokens[0]);
  if (!downId && tokens[1]) downId = String(tokens[1].token_id ?? tokens[1]);
  return { upId, downId };
}

/**
 * Poll Gamma API until market shows closed=true and a winner.
 * Returns "UP" | "DOWN" | null.
 */
export async function pollGammaOutcome(slug, maxAttempts = 20, intervalMs = 3000) {
  for (let i = 0; i < maxAttempts; i++) {
    if (i > 0) await new Promise(r => setTimeout(r, intervalMs));
    try {
      const m = await fetchMarketBySlug(slug);
      if (m?.closed && m?.winner) {
        const w = m.winner.toLowerCase();
        if (w === "up")   return "UP";
        if (w === "down") return "DOWN";
      }
    } catch { /* keep trying */ }
  }
  return null;
}
