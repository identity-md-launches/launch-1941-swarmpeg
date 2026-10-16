import { useId, useState } from "react";
import { useHookStats, usePulse } from "./chain";
import { fmtInt, traitsFor } from "./format";

export function Pulse() {
  const pulse = usePulse();
  const stats = useHookStats();
  const id = useId();
  const live = pulse.data === undefined ? undefined : Number(pulse.data);
  const [preview, setPreview] = useState<number | null>(null);
  const shown = preview ?? live ?? 0;
  const t = traitsFor(shown);
  const liveTraits = stats.traits;

  return (
    <section id="pulse" className="section" aria-labelledby="pulse-title">
      <h2 id="pulse-title">Pulse</h2>
      <p className="muted">
        Every two-sided trade raises the swarm pulse by 25, up to 1000. It decays by 1 each minute. Every live glyph
        reads the pulse when drawn, so the whole swarm thickens, brightens and speeds up together.
      </p>
      <div className="pulse-live" aria-live="polite">
        <div className="meter" role="meter" aria-valuemin={0} aria-valuemax={1000} aria-valuenow={live ?? 0} aria-label="Current swarm pulse">
          <div className="meter-fill" style={{ width: `${((live ?? 0) / 1000) * 100}%` }} />
        </div>
        <p className="mono num">
          {pulse.isError ? "Pulse unavailable" : live === undefined ? "Reading pulse…" : `Current pulse ${fmtInt(live)} / 1000`}
          {stats.tradeCount !== undefined && `, ${fmtInt(stats.tradeCount)} trades recorded`}
        </p>
      </div>

      <div className="card">
        <label htmlFor={id} className="field-label">
          <span>Preview a pulse value</span>
          <span className="mono">{fmtInt(shown)}</span>
        </label>
        <input
          id={id}
          type="range"
          min={0}
          max={1000}
          step={1}
          value={shown}
          onChange={(e) => setPreview(Number(e.target.value))}
          aria-describedby={`${id}-hint`}
        />
        <p id={`${id}-hint`} className="hint">
          Drag to see the traits the hook would render at that pulse. The formula is the contract's own.{" "}
          {preview !== null && (
            <button type="button" className="link-btn" onClick={() => setPreview(null)}>
              Back to live pulse
            </button>
          )}
        </p>
        <dl className="traits">
          <div>
            <dt>Density</dt>
            <dd className="mono num">{t.nodes} nodes</dd>
            <dd className="muted small">6 at pulse 0, 18 at pulse 1000</dd>
          </div>
          <div>
            <dt>Brightness</dt>
            <dd className="mono num">{t.lightness}% lightness</dd>
            <dd className="muted small">42% at pulse 0, 72% at pulse 1000</dd>
          </div>
          <div>
            <dt>Animation speed</dt>
            <dd className="mono num">{(t.durationMs / 1000).toFixed(2)} s per cycle</dd>
            <dd className="muted small">6 s at pulse 0, 1.2 s at pulse 1000</dd>
          </div>
        </dl>
        {liveTraits && (
          <p className="muted small">
            Live from hook.glyphTraits(): {fmtInt(liveTraits[0])} nodes, {fmtInt(liveTraits[1])} ms, {fmtInt(liveTraits[2])}% lightness.
          </p>
        )}
      </div>
    </section>
  );
}
