import { usePulse } from "./chain";
import type { RecentGlyph } from "./chain";
import { Glyph } from "./Glyph";
import { fmtInt } from "./format";
import { Swap } from "./Swap";

export function Hero({ featured, loading }: { featured: RecentGlyph | undefined; loading: boolean }) {
  const pulse = usePulse();
  return (
    <section className="hero" id="home" aria-labelledby="hero-title">
      <div className="hero-copy">
        <h1 id="hero-title">Whole tokens become living glyphs.</h1>
        <p className="lede">
          SwarmPeg (SWARMPEG) is a fixed-supply Ethereum token. Each whole unit you hold owns a unique animated
          glyph drawn entirely on chain.
        </p>
      </div>
      <div className="hero-grid">
        <div className="hero-art">
          <Glyph
            id={featured?.id}
            caption={featured ? `Agent ${featured.id.toString()}, live from the hook` : loading ? "Finding a live glyph…" : "No live glyph found"}
          />
          <dl className="pulse-chip" aria-live="polite">
            <dt>Swarm pulse</dt>
            <dd className="mono num">
              {pulse.isError ? "unavailable" : pulse.data === undefined ? "…" : `${fmtInt(pulse.data)} / 1000`}
            </dd>
          </dl>
        </div>
        <Swap />
      </div>
    </section>
  );
}
