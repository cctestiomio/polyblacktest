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
