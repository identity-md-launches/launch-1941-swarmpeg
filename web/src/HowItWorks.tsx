import { useHookStats } from "./chain";
import { ADDRESSES, EXPLORER, LINKS } from "./config";
import { fmtAmount, fmtInt, short } from "./format";

export function HowItWorks() {
  const stats = useHookStats();
  return (
    <section id="how" className="section" aria-labelledby="how-title">
      <h2 id="how-title">How it works</h2>
      <div className="cols">
        <div>
          <h3>Fractions trade, whole units own art</h3>
          <p>
            SWARMPEG is an ordinary 18-decimal ERC-20 with a fixed supply of one billion. Any fraction trades normally.
            Your glyph count is simply your balance rounded down to whole units: hold 2.7 SWARMPEG and you own two
            glyphs.
          </p>
          <p>
            When whole units arrive, the token issues fresh globally unique glyph IDs to you. When whole units leave,
            your newest glyphs retire first. Each glyph is an animated SVG the hook renders on demand from your
            address, the issuance seed, recent trade entropy and the current pulse. Nothing is stored off chain.
          </p>
        </div>
        <div>
          <h3>A 2% fee feeds an ownerless pot</h3>
          <p>
            Every buy and sell through the SWARMPEG/IMD pool pays 2% of its IMD leg to a maintenance pot the hook
            deployed in its own constructor. Nobody owns the pot: it has no withdraw, approve or upgrade function, and
            anyone may call redeem to turn fee claims into IMD held by the pot.
          </p>
          <dl className="facts">
            <div>
              <dt>Pot reserve</dt>
              <dd className="mono">{stats.potBalance === undefined ? "…" : `${fmtAmount(stats.potBalance)} IMD`}</dd>
            </div>
            <div>
              <dt>Fees accrued</dt>
              <dd className="mono">{stats.totalFees === undefined ? "…" : `${fmtAmount(stats.totalFees)} IMD`}</dd>
            </div>
            <div>
              <dt>Trades</dt>
              <dd className="mono">{fmtInt(stats.tradeCount)}</dd>
            </div>
          </dl>
        </div>
      </div>

      <h3>Contracts</h3>
      <ul className="links">
        <li>
          <span>Token SwarmPeg</span>
          <a className="mono" href={LINKS.token} target="_blank" rel="noreferrer">{ADDRESSES.token}</a>
        </li>
        <li>
          <span>Hook SwarmPegHook</span>
          <a className="mono" href={LINKS.hook} target="_blank" rel="noreferrer">{ADDRESSES.hook}</a>
        </li>
        <li>
          <span>Maintenance pot</span>
          {stats.potAddress ? (
            <a className="mono" href={`${EXPLORER}/address/${stats.potAddress}`} target="_blank" rel="noreferrer">{stats.potAddress}</a>
          ) : (
            <span className="mono">read from hook.maintenancePot()…</span>
          )}
        </li>
        <li>
          <span>Paired token IMD</span>
          <a className="mono" href={LINKS.imd} target="_blank" rel="noreferrer">{short(ADDRESSES.imd)}</a>
        </li>
        <li>
          <span>Pool</span>
          <a href={LINKS.uniswap} target="_blank" rel="noreferrer">SWARMPEG/IMD on Uniswap v4</a>
        </li>
        <li>
          <span>Source</span>
          <a href={LINKS.repo} target="_blank" rel="noreferrer">GitHub repository</a>
        </li>
      </ul>
    </section>
  );
}
