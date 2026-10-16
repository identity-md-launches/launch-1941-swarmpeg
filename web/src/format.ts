import { formatUnits, getAddress } from "viem";

export const short = (a: string) => {
  const c = getAddress(a);
  return `${c.slice(0, 6)}…${c.slice(-4)}`;
};

/** Human amount from 18-decimal units, trimmed to a sensible number of fraction digits. */
export function fmtAmount(value: bigint | undefined, decimals = 18, maxFraction = 4): string {
  if (value === undefined) return "…";
  const s = formatUnits(value, decimals);
  const [whole, frac = ""] = s.split(".");
  const w = Number(whole).toLocaleString("en-US");
  const f = frac.slice(0, maxFraction).replace(/0+$/, "");
  return f ? `${w}.${f}` : w;
}

export const fmtInt = (n: bigint | number | undefined) =>
  n === undefined ? "…" : Number(n).toLocaleString("en-US");

export const svgDataUri = (svg: string) => `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`;

/** Traits formula from SwarmGlyphSVG.traits(pulse), for the visualizer's what-if slider. */
export function traitsFor(pulse: number) {
  const p = Math.max(0, Math.min(1000, Math.floor(pulse)));
  return {
    nodes: 6 + Math.floor((p * 12) / 1000),
    durationMs: 6000 - Math.floor((p * 4800) / 1000),
    lightness: 42 + Math.floor((p * 30) / 1000),
  };
}
