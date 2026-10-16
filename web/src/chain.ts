/** Hooks that read the deployed contracts. Everything the site shows as art or state comes from here. */
import { useMemo } from "react";
import { useBlockNumber, useReadContract, useReadContracts } from "wagmi";
import { encodeAbiParameters, keccak256, type Address } from "viem";
import { ADDRESSES, POOL } from "./config";
import { hookAbi, potAbi, tokenAbi, stateViewAbi } from "./abis";

export const POOL_KEY = (() => {
  const [currency0, currency1] =
    ADDRESSES.token.toLowerCase() < ADDRESSES.imd.toLowerCase()
      ? [ADDRESSES.token, ADDRESSES.imd]
      : [ADDRESSES.imd, ADDRESSES.token];
  return { currency0, currency1, fee: POOL.lpFee, tickSpacing: POOL.tickSpacing, hooks: ADDRESSES.hook } as const;
})();

/** SWARMPEG is currency0 when its address sorts below IMD's. */
export const TOKEN_IS_CURRENCY0 = POOL_KEY.currency0 === ADDRESSES.token;

export const POOL_ID = keccak256(
  encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
    ],
    [POOL_KEY],
  ),
);

const hook = { address: ADDRESSES.hook, abi: hookAbi } as const;
const token = { address: ADDRESSES.token, abi: tokenAbi } as const;

/** Pulse decays once a minute, so a 30s refetch keeps it within one step of the chain. */
export function usePulse() {
  return useReadContract({ ...hook, functionName: "currentPulse", query: { refetchInterval: 30_000 } });
}

export function useHookStats() {
  const stats = useReadContracts({
    contracts: [
      { ...hook, functionName: "tradeCount" },
      { ...hook, functionName: "totalFees" },
      { ...hook, functionName: "maintenancePot" },
      { ...hook, functionName: "glyphTraits" },
      { ...token, functionName: "issuanceCount" },
      { ...token, functionName: "nextGlyphId" },
    ],
    query: { refetchInterval: 60_000 },
  });
  const potAddress = stats.data?.[2]?.result as Address | undefined;
  const pot = useReadContract({
    address: potAddress,
    abi: potAbi,
    functionName: "reserveBalance",
    query: { enabled: !!potAddress, refetchInterval: 60_000 },
  });
  return {
    isLoading: stats.isLoading,
    isError: stats.isError,
    tradeCount: stats.data?.[0]?.result as bigint | undefined,
    totalFees: stats.data?.[1]?.result as bigint | undefined,
    potAddress,
    traits: stats.data?.[3]?.result as readonly [bigint, bigint, bigint] | undefined,
    issuanceCount: stats.data?.[4]?.result as bigint | undefined,
    nextGlyphId: stats.data?.[5]?.result as bigint | undefined,
    potBalance: pot.data as bigint | undefined,
  };
}

export function usePoolState() {
  return useReadContracts({
    contracts: [
      { address: ADDRESSES.stateView, abi: stateViewAbi, functionName: "getSlot0", args: [POOL_ID] },
      { address: ADDRESSES.stateView, abi: stateViewAbi, functionName: "getLiquidity", args: [POOL_ID] },
    ],
    query: { refetchInterval: 30_000 },
  });
}

/** IMD per SWARMPEG from sqrtPriceX96 (price of currency1 in currency0 terms is inverted as needed). */
export function priceFromSqrt(sqrtPriceX96: bigint): number {
  const ratio = Number(sqrtPriceX96) / 2 ** 96;
  const p1per0 = ratio * ratio; // currency1 per currency0
  return TOKEN_IS_CURRENCY0 ? p1per0 : 1 / p1per0;
}

export function useGlyphSvg(id: bigint | undefined) {
  return useReadContract({
    ...hook,
    functionName: "glyphSVG",
    args: id === undefined ? undefined : [id],
    query: { enabled: id !== undefined, refetchInterval: 60_000, staleTime: 30_000 },
  });
}

export type RecentGlyph = { id: bigint; holder: Address; previousHolder: Address; issuance: number };

/**
 * Glyph IDs are allocated per issuance (a whole-unit inflow), so "recent" glyphs come from the newest
 * issuances. Each candidate is checked for liveness with glyphOwner, which reverts for retired IDs.
 */
export function useRecentGlyphs(maxIssuances = 8, perIssuance = 2) {
  const count = useReadContract({ ...token, functionName: "issuanceCount", query: { refetchInterval: 60_000 } });
  const n = count.data === undefined ? 0 : Number(count.data);
  const indexes = useMemo(() => {
    const out: bigint[] = [];
    for (let i = n - 1; i >= 0 && out.length < maxIssuances; i--) out.push(BigInt(i));
    return out;
  }, [n, maxIssuances]);
  const issuances = useReadContracts({
    contracts: indexes.map((i) => ({ ...token, functionName: "issuance", args: [i] }) as const),
    query: { enabled: indexes.length > 0 },
  });
  const candidates = useMemo(() => {
    const out: RecentGlyph[] = [];
    issuances.data?.forEach((r, k) => {
      const iss = r.result as
        | { firstId: bigint; count: bigint; holder: Address; previousHolder: Address }
        | undefined;
      if (!iss) return;
      const take = Number(iss.count < BigInt(perIssuance) ? iss.count : BigInt(perIssuance));
      for (let j = 0; j < take; j++) {
        out.push({
          id: iss.firstId + BigInt(j),
          holder: iss.holder,
          previousHolder: iss.previousHolder,
          issuance: Number(indexes[k]),
        });
      }
    });
    return out;
  }, [issuances.data, indexes, perIssuance]);
  const owners = useReadContracts({
    contracts: candidates.map((c) => ({ ...token, functionName: "glyphOwner", args: [c.id] }) as const),
    allowFailure: true,
    query: { enabled: candidates.length > 0, refetchInterval: 60_000 },
  });
  const live = useMemo(
    () => candidates.filter((_, i) => owners.data?.[i]?.status === "success"),
    [candidates, owners.data],
  );
  return {
    glyphs: live,
    isLoading: count.isLoading || issuances.isLoading || owners.isLoading,
    isError: count.isError || issuances.isError || owners.isError,
    issuanceCount: count.data as bigint | undefined,
  };
}

/** The connected wallet's whole-unit glyphs, refreshed every block so transfers show up live. */
export function useMyGlyphs(address: Address | undefined, max = 24) {
  const { data: block } = useBlockNumber({ watch: true, query: { enabled: !!address } });
  const balance = useReadContract({
    ...token,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    blockNumber: block,
    query: { enabled: !!address },
  });
  const wholeUnits = balance.data === undefined ? undefined : balance.data / 10n ** 18n;
  const shown = wholeUnits === undefined ? 0 : Number(wholeUnits < BigInt(max) ? wholeUnits : BigInt(max));
  const ids = useReadContracts({
    contracts: Array.from({ length: shown }, (_, i) => ({
      ...token,
      functionName: "glyphAt",
      args: [address!, BigInt(i)],
    }) as const),
    blockNumber: block,
    query: { enabled: !!address && shown > 0 },
  });
  return {
    balance: balance.data as bigint | undefined,
    wholeUnits,
    ids: (ids.data?.map((r) => r.result as bigint | undefined).filter((x): x is bigint => x !== undefined) ?? []),
    isLoading: balance.isLoading || ids.isLoading,
    isError: balance.isError || ids.isError,
    shown,
  };
}
