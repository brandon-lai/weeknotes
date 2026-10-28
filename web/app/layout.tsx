import type { Metadata, Viewport } from "next";
import "./globals.css";

const site = process.env.NEXT_PUBLIC_SITE_URL ?? "https://weeknotes-app.vercel.app";

export const metadata: Metadata = {
  metadataBase: new URL(site),
  title: "Weeknotes",
  description: "Once a week, write down how it went. Type, dictate or record a voice memo; no account needed. Share a week with the circles you choose.",
  applicationName: "Weeknotes",
  openGraph: {
    title: "Weeknotes",
    description: "Once a week, write down how it went.",
    siteName: "Weeknotes",
    type: "website",
  },
  twitter: { card: "summary_large_image" },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#f7f3ea" },
    { media: "(prefers-color-scheme: dark)", color: "#171513" },
  ],
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
