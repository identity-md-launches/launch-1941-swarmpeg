import { useGlyphSvg } from "./chain";
import { svgDataUri } from "./format";

/**
 * One on-chain glyph, read from hook.glyphSVG(id) and shown as an <img> so the SVG's own styles and
 * keyframes stay inside its document. The art re-reads once a minute because it depends on the pulse.
 */
export function Glyph({ id, size, caption }: { id: bigint | undefined; size?: number; caption?: string }) {
  const { data, isLoading, isError } = useGlyphSvg(id);
  const style = size ? { width: size, height: size } : undefined;
  return (
    <figure className="glyph" style={style}>
      {data ? (
        <img src={svgDataUri(data)} alt={`SwarmPeg glyph ${id?.toString() ?? ""}, animated node network`} />
      ) : (
        <div className="glyph-empty" role="status" aria-live="polite">
          {isError ? "Glyph could not be read from the hook." : isLoading || id === undefined ? "Reading glyph…" : ""}
        </div>
      )}
      {caption && <figcaption className="mono">{caption}</figcaption>}
    </figure>
  );
}
