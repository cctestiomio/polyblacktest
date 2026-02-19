import "./globals.css";
export const metadata = { title: "Polymarket BTC 5m Backtest", description: "Track & backtest BTC UP/DOWN 5m markets" };
export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
