// Helpers for Polymarket CLOB API

export function getCurrentMarketTimestamp() {
  const now = Math.floor(Date.now() / 1000);
  // Markets resolve on 300s boundaries; next one is the active one
  return Math.ceil(now / 300) * 300;
}

// Correct slug format: btc-updown-5m-{ts}
export function getMarketSlug(ts) {
  return `btc-updown-5m-${ts}`;
}

export function getSecondsRemaining(resolutionTs) {
  return Math.max(0, resolutionTs - Math.floor(Date.now() / 1000));
}

export function getSecondsElapsed(resolutionTs) {
  const total = 300;
  const remaining = getSecondsRemaining(resolutionTs);
  return Math.min(total, total - remaining);
}

export async function fetchMarketBySlug(slug) {
  const res = await fetch(`/api/market?slug=${encodeURIComponent(slug)}`);
  if (!res.ok) return null;
  return res.json();
}

export async function fetchMidpoint(tokenId) {
  const res = await fetch(`/api/midpoint?token_id=${tokenId}`);
  if (!res.ok) return null;
  const data = await res.json();
  return parseFloat(data.mid ?? 0);
}

/**
 * Determine outcome from final prices.
 * Whichever token resolves at >= 0.95 is the winner.
 */
export function detectOutcome(upPrice, downPrice) {
  if (upPrice != null && upPrice >= 0.95) return "UP";
  if (downPrice != null && downPrice >= 0.95) return "DOWN";
  // fallback: whichever is higher
  if (upPrice != null && downPrice != null) {
    return upPrice > downPrice ? "UP" : "DOWN";
  }
  return null;
}
