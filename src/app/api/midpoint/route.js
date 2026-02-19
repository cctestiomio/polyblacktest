export const runtime = "edge";

function validPrice(v) {
  const f = parseFloat(v);
  return (isFinite(f) && f > 0.001) ? f : null;
}

async function tryMidpoints(tokenId) {
  try {
    const res = await fetch(`https://clob.polymarket.com/midpoints?token_id=${tokenId}`, { headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    const d = await res.json();
    return validPrice(d?.mid ?? d?.[tokenId] ?? d?.midpoint);
  } catch { return null; }
}

async function tryPrice(tokenId) {
  try {
    const res = await fetch(`https://clob.polymarket.com/price?token_id=${tokenId}&side=buy`, { headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    const d = await res.json();
    return validPrice(d?.price);
  } catch { return null; }
}

async function tryBook(tokenId) {
  try {
    const res = await fetch(`https://clob.polymarket.com/book?token_id=${tokenId}`, { headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    const d = await res.json();
    const bid = d?.bids?.[0]?.price != null ? parseFloat(d.bids[0].price) : null;
    const ask = d?.asks?.[0]?.price != null ? parseFloat(d.asks[0].price) : null;
    if (bid && ask) return validPrice((bid + ask) / 2);
    return validPrice(bid ?? ask);
  } catch { return null; }
}

export async function GET(request) {
  const { searchParams } = new URL(request.url);
  const tokenId = searchParams.get("token_id");
  if (!tokenId) return Response.json({ mid: null, error: "no token_id" }, { status: 400 });
  try {
    const mid = await tryMidpoints(tokenId) ?? await tryPrice(tokenId) ?? await tryBook(tokenId);
    return Response.json({ mid: mid != null ? mid.toFixed(6) : null });
  } catch (e) {
    return Response.json({ mid: null, error: String(e) });
  }
}
