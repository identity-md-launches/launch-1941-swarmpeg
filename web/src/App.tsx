import { ConnectSheet } from "./ConnectSheet";
import { useRecentGlyphs } from "./chain";
import { Hero } from "./Hero";
import { MyGlyphs } from "./MyGlyphs";
import { Gallery } from "./Gallery";
import { Pulse } from "./Pulse";
import { HowItWorks } from "./HowItWorks";
import { LINKS } from "./config";

const NAV = [
  { href: "#my-glyphs", label: "My glyphs" },
  { href: "#gallery", label: "Gallery" },
  { href: "#pulse", label: "Pulse" },
  { href: "#how", label: "How it works" },
];

export function App() {
  const recent = useRecentGlyphs();
  return (
    <>
      <a className="skip" href="#main">
        Skip to content
      </a>
      <header className="top">
        <a className="brand" href="#home" aria-label="SwarmPeg, home">
          <svg width="28" height="28" viewBox="0 0 28 28" aria-hidden="true">
            <rect width="28" height="28" rx="7" fill="#101c2e" />
            <circle cx="8" cy="9" r="2.2" fill="#37c7f0" />
            <circle cx="20" cy="8" r="1.8" fill="#37c7f0" />
            <circle cx="19" cy="20" r="2.4" fill="#37c7f0" />
            <circle cx="8" cy="20" r="1.6" fill="#37c7f0" />
            <path d="M8 9L20 8L19 20L8 20Z M8 9L19 20 M20 8L8 20" stroke="#37c7f0" strokeWidth="1" fill="none" opacity=".7" />
          </svg>
          <span>SwarmPeg</span>
        </a>
        <nav aria-label="Sections">
          {NAV.map((n) => (
            <a key={n.href} href={n.href}>
              {n.label}
            </a>
          ))}
        </nav>
        <ConnectSheet />
      </header>
      <main id="main">
        <Hero featured={recent.glyphs[0]} loading={recent.isLoading} />
        <MyGlyphs />
        <Gallery glyphs={recent.glyphs} loading={recent.isLoading} error={recent.isError} issuanceCount={recent.issuanceCount} />
        <Pulse />
        <HowItWorks />
      </main>
      <footer className="foot">
        <span>SwarmPeg on Ethereum mainnet. Glyphs are cosmetic and carry no financial rights.</span>
        <span>
          <a href={LINKS.token} target="_blank" rel="noreferrer">Token</a> ·{" "}
          <a href={LINKS.hook} target="_blank" rel="noreferrer">Hook</a> ·{" "}
          <a href={LINKS.uniswap} target="_blank" rel="noreferrer">Uniswap pool</a> ·{" "}
          <a href={LINKS.repo} target="_blank" rel="noreferrer">GitHub</a>
        </span>
      </footer>
    </>
  );
}
