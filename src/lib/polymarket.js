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
