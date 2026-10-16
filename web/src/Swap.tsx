import { useEffect, useId, useMemo, useState } from "react";
import { useAccount, useBlockNumber, useChainId, useConfig, useReadContract, useReadContracts } from "wagmi";
import { readContract, waitForTransactionReceipt, writeContract } from "wagmi/actions";
import { BaseError, encodeAbiParameters, maxUint160, maxUint256, parseUnits, type Address, type Hex } from "viem";
import { ADDRESSES, CHAIN_ID, EXPLORER, LINKS } from "./config";
import { erc20Abi, permit2Abi, quoterAbi, universalRouterAbi } from "./abis";
import { POOL_KEY, priceFromSqrt, usePoolState } from "./chain";
import { fmtAmount } from "./format";

type Side = "buy" | "sell";
type Step =
  | { kind: "idle" }
  | { kind: "approve" | "permit" | "swap"; hash?: Hex }
  | { kind: "done"; hash: Hex }
  | { kind: "error"; message: string };

const SWAP_EXACT_IN_SINGLE = "06";
const SETTLE_ALL = "0c";
const TAKE_ALL = "0f";
const V4_SWAP = "0x10";
const PRESETS = ["0.5", "1", "3"];

const exactInputSingleAbi = [
  {
    type: "tuple",
    components: [
      {
        name: "poolKey",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
      { name: "zeroForOne", type: "bool" },
      { name: "amountIn", type: "uint128" },
      { name: "amountOutMinimum", type: "uint128" },
      { name: "hookData", type: "bytes" },
    ],
  },
] as const;

function useDebounced<T>(value: T, ms: number) {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}

function errorText(e: unknown): string {
  if (e instanceof BaseError) {
    const m = e.shortMessage || e.message;
    if (/rejected|denied/i.test(m)) return "The wallet rejected the request. Nothing was sent.";
    if (/PartialFillUnsupported/.test(m)) return "The pool cannot fill this amount at once. Try a smaller amount.";
    if (/Too little received|V4TooLittleReceived|slippage/i.test(m))
      return "Price moved past your slippage limit. Raise slippage or try again.";
    return m;
  }
  return e instanceof Error ? e.message : "Unable to send the transaction.";
}

export function Swap() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const config = useConfig();
  const [side, setSide] = useState<Side>("buy");
  const [amount, setAmount] = useState("");
  const [slippage, setSlippage] = useState("1");
  const [step, setStep] = useState<Step>({ kind: "idle" });
  const amountId = useId();
  const slipId = useId();

  const tokenIn: Address = side === "buy" ? ADDRESSES.imd : ADDRESSES.token;
  const tokenOut: Address = side === "buy" ? ADDRESSES.token : ADDRESSES.imd;
  const symIn = side === "buy" ? "IMD" : "SWARMPEG";
  const symOut = side === "buy" ? "SWARMPEG" : "IMD";
  const zeroForOne = tokenIn.toLowerCase() === POOL_KEY.currency0.toLowerCase();

  const amountIn = useMemo(() => {
    try {
      if (!amount || !/^\d*\.?\d*$/.test(amount)) return 0n;
      return parseUnits(amount, 18);
    } catch {
      return 0n;
    }
  }, [amount]);
  const debouncedIn = useDebounced(amountIn, 350);
  const slipBps = useMemo(() => {
    const n = Number(slippage);
    if (!Number.isFinite(n) || n < 0 || n > 50) return null;
    return BigInt(Math.round(n * 100));
  }, [slippage]);

  const quote = useReadContract({
    address: ADDRESSES.quoter,
    abi: quoterAbi,
    functionName: "quoteExactInputSingle",
    args: [{ poolKey: POOL_KEY, zeroForOne, exactAmount: debouncedIn, hookData: "0x" }],
    query: { enabled: debouncedIn > 0n && debouncedIn < maxUint160, refetchInterval: 20_000 },
  });
  const amountOut = quote.data?.[0];
  const minOut = amountOut !== undefined && slipBps !== null ? (amountOut * (10_000n - slipBps)) / 10_000n : undefined;

  const { data: block } = useBlockNumber({ watch: true, query: { enabled: isConnected } });
  const balances = useReadContracts({
    contracts: [
      { address: ADDRESSES.imd, abi: erc20Abi, functionName: "balanceOf", args: [address!] },
      { address: ADDRESSES.token, abi: erc20Abi, functionName: "balanceOf", args: [address!] },
    ],
    blockNumber: block,
    query: { enabled: !!address },
  });
  const balIMD = balances.data?.[0]?.result;
  const balTOK = balances.data?.[1]?.result;
  const balIn = side === "buy" ? balIMD : balTOK;

  const pool = usePoolState();
  const slot0 = pool.data?.[0]?.result;
  const price = slot0 ? priceFromSqrt(slot0[0]) : undefined;

  const wrongChain = isConnected && chainId !== CHAIN_ID;
  const busy = step.kind === "approve" || step.kind === "permit" || step.kind === "swap";
  const insufficient = balIn !== undefined && amountIn > balIn;

  let buttonLabel = side === "buy" ? "Buy SWARMPEG" : "Sell SWARMPEG";
  let disabled = false;
  if (!isConnected) {
    buttonLabel = "Connect a wallet to swap";
    disabled = true;
  } else if (wrongChain) {
    buttonLabel = "Switch to Ethereum to swap";
    disabled = true;
  } else if (amountIn === 0n) {
    buttonLabel = "Enter an amount";
    disabled = true;
  } else if (insufficient) {
    buttonLabel = `Not enough ${symIn}`;
    disabled = true;
  } else if (slipBps === null) {
    buttonLabel = "Set slippage between 0 and 50%";
    disabled = true;
  } else if (minOut === undefined) {
    buttonLabel = quote.isError ? "No quote for this amount" : "Getting a quote…";
    disabled = true;
  } else if (step.kind === "approve") buttonLabel = step.hash ? "Approving…" : "Confirm approval in wallet…";
  else if (step.kind === "permit") buttonLabel = step.hash ? "Allowing router…" : "Confirm allowance in wallet…";
  else if (step.kind === "swap") buttonLabel = step.hash ? "Swapping…" : "Confirm swap in wallet…";

  async function run() {
    if (!address || minOut === undefined || busy) return;
    try {
      // 1. Let Permit2 move the input token (one-time per token).
      const erc20Allowance = await readContract(config, {
        address: tokenIn,
        abi: erc20Abi,
        functionName: "allowance",
        args: [address, ADDRESSES.permit2],
      });
      if (erc20Allowance < amountIn) {
        setStep({ kind: "approve" });
        const hash = await writeContract(config, {
          address: tokenIn,
          abi: erc20Abi,
          functionName: "approve",
          args: [ADDRESSES.permit2, maxUint256],
        });
        setStep({ kind: "approve", hash });
        await waitForTransactionReceipt(config, { hash });
      }
      // 2. Let the Universal Router pull through Permit2 (expires after 30 days).
      const now = Math.floor(Date.now() / 1000);
      const [p2Amount, p2Expiration] = await readContract(config, {
        address: ADDRESSES.permit2,
        abi: permit2Abi,
        functionName: "allowance",
        args: [address, tokenIn, ADDRESSES.universalRouter],
      });
      if (p2Amount < amountIn || p2Expiration <= now) {
        setStep({ kind: "permit" });
        const hash = await writeContract(config, {
          address: ADDRESSES.permit2,
          abi: permit2Abi,
          functionName: "approve",
          args: [tokenIn, ADDRESSES.universalRouter, maxUint160, now + 30 * 24 * 3600],
        });
        setStep({ kind: "permit", hash });
        await waitForTransactionReceipt(config, { hash });
      }
      // 3. The swap itself: V4_SWAP with SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL.
      const actions: Hex = `0x${SWAP_EXACT_IN_SINGLE}${SETTLE_ALL}${TAKE_ALL}`;
      const swapParams = encodeAbiParameters(exactInputSingleAbi, [
        { poolKey: POOL_KEY, zeroForOne, amountIn, amountOutMinimum: minOut, hookData: "0x" },
      ]);
      const settle = encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [tokenIn, amountIn]);
      const take = encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [tokenOut, minOut]);
      const input = encodeAbiParameters([{ type: "bytes" }, { type: "bytes[]" }], [actions, [swapParams, settle, take]]);
      setStep({ kind: "swap" });
      const hash = await writeContract(config, {
        address: ADDRESSES.universalRouter,
        abi: universalRouterAbi,
        functionName: "execute",
        args: [V4_SWAP, [input], BigInt(now + 20 * 60)],
      });
      setStep({ kind: "swap", hash });
      await waitForTransactionReceipt(config, { hash });
      setStep({ kind: "done", hash });
      setAmount("");
    } catch (e) {
      setStep({ kind: "error", message: errorText(e) });
    }
  }

  return (
    <form
      className="card swap"
      aria-labelledby="swap-title"
      onSubmit={(e) => {
        e.preventDefault();
        void run();
      }}
    >
      <div className="swap-head">
        <h2 id="swap-title">Swap</h2>
        <div className="seg" role="group" aria-label="Direction">
          <button type="button" aria-pressed={side === "buy"} onClick={() => { setSide("buy"); setStep({ kind: "idle" }); }}>
            Buy
          </button>
          <button type="button" aria-pressed={side === "sell"} onClick={() => { setSide("sell"); setStep({ kind: "idle" }); }}>
            Sell
          </button>
        </div>
      </div>

      <label className="field" htmlFor={amountId}>
        <span className="field-label">
          <span>You pay ({symIn})</span>
          {balIn !== undefined && (
            <button type="button" className="link-btn" onClick={() => setAmount(fmtAmount(balIn, 18, 6).replace(/,/g, ""))}>
              Balance {fmtAmount(balIn)}
            </button>
          )}
        </span>
        <input
          id={amountId}
          className="mono"
          inputMode="decimal"
          autoComplete="off"
          placeholder="0.0"
          value={amount}
          onChange={(e) => {
            setAmount(e.target.value.replace(/,/g, ""));
            if (step.kind === "done" || step.kind === "error") setStep({ kind: "idle" });
          }}
          aria-invalid={amount !== "" && amountIn === 0n ? true : undefined}
          aria-describedby={`${amountId}-hint`}
        />
        <span id={`${amountId}-hint`} className="hint">
          {amount !== "" && amountIn === 0n ? "Use digits and one decimal point, for example 12.5" : `Amount of ${symIn} to spend`}
        </span>
      </label>

      <div className="field">
        <span className="field-label">
          <span>You receive ({symOut}), estimated</span>
        </span>
        <output className="mono readout" aria-live="polite">
          {amountIn === 0n ? "0" : quote.isFetching && amountOut === undefined ? "…" : quote.isError ? "no quote" : fmtAmount(amountOut)}
        </output>
      </div>

      <fieldset className="slip">
        <legend>Slippage</legend>
        <div className="seg" role="group" aria-label="Slippage presets">
          {PRESETS.map((p) => (
            <button key={p} type="button" aria-pressed={slippage === p} onClick={() => setSlippage(p)}>
              {p}%
            </button>
          ))}
        </div>
        <label htmlFor={slipId} className="slip-custom">
          <span>Custom %</span>
          <input
            id={slipId}
            className="mono"
            inputMode="decimal"
            autoComplete="off"
            value={slippage}
            onChange={(e) => setSlippage(e.target.value)}
            aria-invalid={slipBps === null ? true : undefined}
          />
        </label>
      </fieldset>

      <dl className="facts">
        <div>
          <dt>Minimum received</dt>
          <dd className="mono">{minOut === undefined ? "…" : `${fmtAmount(minOut)} ${symOut}`}</dd>
        </div>
        <div>
          <dt>Pool price</dt>
          <dd className="mono">{price === undefined ? "…" : `${price.toLocaleString("en-US", { maximumSignificantDigits: 6 })} IMD per SWARMPEG`}</dd>
        </div>
        <div>
          <dt>Fees in quote</dt>
          <dd>2% hook fee in IMD to the maintenance pot, 1.25% LP fee</dd>
        </div>
      </dl>

      <button type="submit" className="cta wide" disabled={disabled || busy} aria-busy={busy || undefined}>
        {buttonLabel}
      </button>

      <p className="status" role="status" aria-live="polite">
        {step.kind === "approve" && step.hash && <TxLink hash={step.hash} text="Approval sent" />}
        {step.kind === "permit" && step.hash && <TxLink hash={step.hash} text="Allowance sent" />}
        {step.kind === "swap" && step.hash && <TxLink hash={step.hash} text="Swap sent" />}
        {step.kind === "done" && <TxLink hash={step.hash} text="Swap confirmed" />}
        {step.kind === "error" && <span className="error">{step.message}</span>}
        {step.kind === "idle" && isConnected && !wrongChain && (
          <span className="muted">
            Up to three wallet prompts: approve {symIn} for Permit2 once, allow the router once, then swap.{" "}
            <a href={LINKS.uniswap} target="_blank" rel="noreferrer">
              Open the pool on Uniswap
            </a>
          </span>
        )}
      </p>
    </form>
  );
}

function TxLink({ hash, text }: { hash: Hex; text: string }) {
  return (
    <a href={`${EXPLORER}/tx/${hash}`} target="_blank" rel="noreferrer">
      {text}: view transaction on Etherscan
    </a>
  );
}
