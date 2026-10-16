import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useAccount, useChainId, useConnect, useDisconnect, useSwitchChain, type Connector } from "wagmi";
import { CHAIN_ID, WALLET_ADD_CHAIN } from "./config";
import { WALLET_ICONS, iconDataUri } from "./wallet-icons";
import { OPEN_IN, isMobileBrowser } from "./open-in";
import { short } from "./format";

/**
 * The connect control and its sheet: the network's structure (EIP-6963 rows, then Coinbase; "Open in"
 * rows on phones; one close control; 48px rows) in the site's own type, colors and radius.
 */
export function ConnectSheet() {
  const mobile = isMobileBrowser();
  const { address, isConnected, connector: active } = useAccount();
  const chainId = useChainId();
  const { connectors, connect, isPending, variables, error, reset } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChainAsync, isPending: switching } = useSwitchChain();
  const [open, setOpen] = useState(false);
  const [menu, setMenu] = useState(false);
  const [switchError, setSwitchError] = useState<string | null>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const sheetRef = useRef<HTMLDivElement>(null);

  // Escape closes; focus moves into the sheet on open and back to the trigger on close.
  useEffect(() => {
    if (!open) return;
    const root = document.getElementById("root");
    root?.setAttribute("inert", "");
    const first = sheetRef.current?.querySelector<HTMLElement>("button, a");
    first?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    addEventListener("keydown", onKey);
    return () => {
      removeEventListener("keydown", onKey);
      root?.removeAttribute("inert");
      triggerRef.current?.focus();
    };
  }, [open]);
  useEffect(() => {
    if (isConnected) setOpen(false);
  }, [isConnected]);

  // EIP-6963 names each installed extension; wagmi's generic injected row is only for a browser
  // where discovery found nothing, and then it is called what it is.
  const named = connectors.some((c) => c.type === "injected" && c.id !== "injected");
  const listed = [
    ...connectors.filter((c) => c.type === "injected"),
    ...connectors.filter((c) => c.type !== "injected"),
  ].filter((c) => !(c.id === "injected" && named));
  const label = (c: Connector) =>
    c.id === "injected" ? "Browser wallet" : c.id === "coinbaseWalletSDK" && mobile ? "Coinbase Smart Wallet" : c.name;
  const icon = (c: Connector) => c.icon ?? (WALLET_ICONS[c.id] ? iconDataUri(WALLET_ICONS[c.id]!) : undefined);

  const wrongChain = isConnected && chainId !== CHAIN_ID;

  async function switchToMainnet() {
    setSwitchError(null);
    try {
      await switchChainAsync({ chainId: CHAIN_ID });
    } catch {
      // The wallet does not know the chain: add it with the network's parameters.
      try {
        const provider = (await active?.getProvider()) as
          | { request: (a: { method: string; params?: unknown[] }) => Promise<unknown> }
          | undefined;
        await provider?.request({ method: "wallet_addEthereumChain", params: [WALLET_ADD_CHAIN] });
      } catch {
        setSwitchError("Switch to Ethereum in your wallet to continue.");
      }
    }
  }

  if (isConnected && address) {
    if (wrongChain) {
      return (
        <span className="connect-wrap">
          <button className="cta" onClick={switchToMainnet} disabled={switching}>
            {switching ? "Switching…" : "Switch to Ethereum"}
          </button>
          {switchError && (
            <span role="status" className="note">
              {switchError}
            </span>
          )}
        </span>
      );
    }
    return (
      <span className="connect-wrap">
        <button
          className="cta ghost mono"
          aria-haspopup="menu"
          aria-expanded={menu}
          onClick={() => setMenu((m) => !m)}
          title={address}
        >
          {short(address)}
        </button>
        {menu && (
          <span className="menu" role="menu">
            <button
              role="menuitem"
              onClick={() => {
                setMenu(false);
                disconnect();
              }}
            >
              Disconnect
            </button>
          </span>
        )}
      </span>
    );
  }

  return (
    <>
      <button
        ref={triggerRef}
        className="cta"
        onClick={() => {
          reset();
          setOpen(true);
        }}
      >
        Connect
      </button>
      {open &&
        createPortal(
        <div className="sheet-bg" onClick={() => setOpen(false)}>
          <div
            className="sheet"
            ref={sheetRef}
            role="dialog"
            aria-modal="true"
            aria-label="Connect a wallet"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="sheet-head">
              <h2>Connect a wallet</h2>
              <button className="x" aria-label="Close" onClick={() => setOpen(false)}>
                ×
              </button>
            </div>
            {mobile &&
              OPEN_IN.map((w) => (
                <a key={w.id} className="row-link" href={w.href(location.href)}>
                  <span className="ic">
                    <img width={28} height={28} src={iconDataUri(WALLET_ICONS[w.id]!)} alt="" />
                  </span>
                  <span>Open in {w.name}</span>
                </a>
              ))}
            {listed
              .filter((c) => !mobile || c.type !== "injected")
              .map((c) => (
                <button
                  key={c.uid}
                  className="row-link"
                  onClick={() => connect({ connector: c })}
                  disabled={isPending}
                >
                  <span className="ic">
                    {icon(c) ? <img width={28} height={28} src={icon(c)} alt="" /> : <span aria-hidden="true" />}
                  </span>
                  <span>
                    {label(c)}
                    {isPending && variables?.connector === c ? " · opening…" : ""}
                  </span>
                </button>
              ))}
            <p className="note" role="status">
              {error
                ? "The wallet did not connect. Choose a wallet to try again."
                : mobile
                  ? "Open this page inside your wallet app, or create a Coinbase Smart Wallet with a passkey."
                  : "Choose an installed browser wallet, or use Coinbase Wallet."}
            </p>
          </div>
        </div>,
          document.body,
        )}
    </>
  );
}
