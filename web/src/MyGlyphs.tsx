import { useAccount } from "wagmi";
import { useMyGlyphs } from "./chain";
import { Glyph } from "./Glyph";
import { fmtAmount, fmtInt } from "./format";

export function MyGlyphs() {
  const { address, isConnected } = useAccount();
  const mine = useMyGlyphs(address);
  return (
    <section id="my-glyphs" className="section" aria-labelledby="mine-title">
      <h2 id="mine-title">My glyphs</h2>
      {!isConnected && (
        <p className="muted">
          Connect a wallet with the control in the header. Your whole SWARMPEG units and their glyphs appear here and
          update as your balance changes.
        </p>
      )}
      {isConnected && (
        <>
          <dl className="stats" aria-live="polite">
            <div>
              <dt>Whole units</dt>
              <dd className="mono num">{mine.wholeUnits === undefined ? "…" : fmtInt(mine.wholeUnits)}</dd>
            </div>
            <div>
              <dt>Exact balance</dt>
              <dd className="mono num">{mine.balance === undefined ? "…" : `${fmtAmount(mine.balance, 18, 6)} SWARMPEG`}</dd>
            </div>
          </dl>
          {mine.isError && <p className="error">Balance could not be read. Check your connection and reload.</p>}
          {mine.wholeUnits === 0n && (
            <p className="muted">
              No whole units yet. Fractions trade normally; the first whole SWARMPEG you hold mints a glyph of its own.{" "}
              <a href="#home">Buy SWARMPEG</a>
            </p>
          )}
          {mine.wholeUnits !== undefined && mine.wholeUnits > 0n && (
            <>
              <ul className="grid-glyphs">
                {mine.ids.map((id) => (
                  <li key={id.toString()}>
                    <Glyph id={id} caption={`Agent ${id.toString()}`} />
                  </li>
                ))}
              </ul>
              {mine.wholeUnits > BigInt(mine.shown) && (
                <p className="muted">Showing the first {mine.shown} of {fmtInt(mine.wholeUnits)} glyphs.</p>
              )}
            </>
          )}
        </>
      )}
    </section>
  );
}
