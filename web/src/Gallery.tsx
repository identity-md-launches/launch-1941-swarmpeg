import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { formatUnits, type Address, type Hex } from "viem";
import type { RecentGlyph } from "./chain";
import { Glyph } from "./Glyph";
import { ADDRESSES, DEPLOY_BLOCK, EXPLORER } from "./config";
import { hookAbi, tokenAbi } from "./abis";
import { fmtAmount, fmtInt, short } from "./format";

type Item = { block: bigint; tx: Hex; text: string; detail?: string };

/** Recent events from the hook and token, newest first. Falls back to the last 5000 blocks when the RPC refuses the full range. */
function useActivity() {
  const client = usePublicClient();
  return useQuery({
    queryKey: ["activity"],
    enabled: !!client,
    refetchInterval: 60_000,
    queryFn: async (): Promise<Item[]> => {
      const latest = await client!.getBlockNumber();
      const fetch = async (fromBlock: bigint) => {
        const [trades, fees, batches] = await Promise.all([
          client!.getContractEvents({ address: ADDRESSES.hook, abi: hookAbi, eventName: "TradeRecorded", fromBlock, toBlock: latest }),
          client!.getContractEvents({ address: ADDRESSES.hook, abi: hookAbi, eventName: "FeeAccrued", fromBlock, toBlock: latest }),
          client!.getContractEvents({ address: ADDRESSES.token, abi: tokenAbi, eventName: "GlyphBatchCreated", fromBlock, toBlock: latest }),
        ]);
        const items: Item[] = [];
        for (const t of trades) {
          const imd = t.args.imdDelta ?? 0n;
          const tok = t.args.tokenDelta ?? 0n;
          const buy = imd < 0n;
          items.push({
            block: t.blockNumber,
            tx: t.transactionHash,
            text: `Trade ${fmtInt(t.args.trade)}: ${buy ? "buy" : "sell"} of ${fmtAmount(tok < 0n ? -tok : tok)} SWARMPEG`,
            detail: `${fmtAmount(imd < 0n ? -imd : imd)} IMD, router ${short(t.args.router as Address)}`,
          });
        }
        for (const f of fees) {
          items.push({
            block: f.blockNumber,
            tx: f.transactionHash,
            text: `Fee ${fmtAmount(f.args.feeIMD)} IMD to the maintenance pot`,
            detail: `${f.args.buy ? "Buy" : "Sell"}, gross ${fmtAmount(f.args.grossIMD)} IMD`,
          });
        }
        for (const b of batches) {
          items.push({
            block: b.blockNumber,
            tx: b.transactionHash,
            text: `${fmtInt(b.args.count)} glyph${b.args.count === 1n ? "" : "s"} issued to ${short(b.args.holder as Address)}`,
            detail: `First ID ${b.args.firstId?.toString()}, from ${short(b.args.previousHolder as Address)}`,
          });
        }
        return items.sort((a, b) => (a.block === b.block ? 0 : a.block > b.block ? -1 : 1)).slice(0, 30);
      };
      try {
        return await fetch(DEPLOY_BLOCK);
      } catch {
        return fetch(latest > 5000n ? latest - 5000n : 0n);
      }
    },
  });
}

export function Gallery({ glyphs, loading, error, issuanceCount }: { glyphs: RecentGlyph[]; loading: boolean; error: boolean; issuanceCount: bigint | undefined }) {
  const activity = useActivity();
  return (
    <section id="gallery" className="section" aria-labelledby="gallery-title">
      <h2 id="gallery-title">Gallery</h2>
      <p className="muted">
        The newest live glyphs, drawn from the latest whole-unit issuances
        {issuanceCount !== undefined ? ` (${fmtInt(issuanceCount)} so far)` : ""}. Every image is read from the hook
        at view time.
      </p>
      {error && <p className="error">Glyph list could not be read from the token. Reload to try again.</p>}
      {loading && glyphs.length === 0 && <p className="muted" role="status">Reading issuances…</p>}
      {!loading && !error && glyphs.length === 0 && <p className="muted">No live glyphs yet. The first whole-unit holder will appear here.</p>}
      <ul className="grid-glyphs">
        {glyphs.map((g) => (
          <li key={g.id.toString()}>
            <Glyph id={g.id} caption={`Agent ${g.id.toString()}`} />
            <p className="muted small">
              Held by{" "}
              <a className="mono" href={`${EXPLORER}/address/${g.holder}`} target="_blank" rel="noreferrer">
                {short(g.holder)}
              </a>
            </p>
          </li>
        ))}
      </ul>

      <h3 id="activity-title">Activity</h3>
      {activity.isLoading && <p className="muted" role="status">Reading events…</p>}
      {activity.isError && <p className="error">Events could not be read from the RPC. Reload to try again.</p>}
      {activity.data && activity.data.length === 0 && <p className="muted">No trades or issuances recorded yet.</p>}
      {activity.data && activity.data.length > 0 && (
        <ol className="feed" aria-labelledby="activity-title">
          {activity.data.map((it, i) => (
            <li key={`${it.tx}-${i}`}>
              <span>{it.text}</span>
              {it.detail && <span className="muted small">{it.detail}</span>}
              <a className="mono small" href={`${EXPLORER}/tx/${it.tx}`} target="_blank" rel="noreferrer">
                Block {fmtInt(it.block)}, view on Etherscan
              </a>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}

export const imd = (v: bigint) => formatUnits(v, 18);
