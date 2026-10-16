/**
 * Typed ABI fragments for the calls this site makes. The full compiled ABIs built from the pinned
 * source commit sit in ./abi/*.json (their sorted-key keccak matches deployment.json's abiHash);
 * these fragments are copied from them so wagmi can infer argument and return types.
 */

export const hookAbi = [
  { type: "function", name: "currentPulse", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "tradeCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalFees", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "maintenancePot", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  {
    type: "function",
    name: "glyphSVG",
    stateMutability: "view",
    inputs: [{ name: "id", type: "uint256" }],
    outputs: [{ type: "string" }],
  },
  {
    type: "function",
    name: "glyphURI",
    stateMutability: "view",
    inputs: [{ name: "id", type: "uint256" }],
    outputs: [{ type: "string" }],
  },
  {
    type: "function",
    name: "glyphTraits",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "nodes", type: "uint256" },
      { name: "durationMs", type: "uint256" },
      { name: "lightness", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "poolKey",
    stateMutability: "view",
    inputs: [],
    outputs: [
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
  },
  {
    type: "event",
    name: "TradeRecorded",
    inputs: [
      { name: "trade", type: "uint256", indexed: true },
      { name: "router", type: "address", indexed: true },
      { name: "entropy", type: "bytes32", indexed: false },
      { name: "imdDelta", type: "int128", indexed: false },
      { name: "tokenDelta", type: "int128", indexed: false },
    ],
  },
  {
    type: "event",
    name: "FeeAccrued",
    inputs: [
      { name: "trade", type: "uint256", indexed: true },
      { name: "buy", type: "bool", indexed: true },
      { name: "grossIMD", type: "uint256", indexed: false },
      { name: "feeIMD", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "PulseUpdated",
    inputs: [
      { name: "pulse", type: "uint256", indexed: false },
      { name: "timestamp", type: "uint256", indexed: false },
      { name: "trade", type: "uint256", indexed: true },
    ],
  },
] as const;

export const tokenAbi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "glyphCount",
    stateMutability: "view",
    inputs: [{ name: "holder", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "glyphAt",
    stateMutability: "view",
    inputs: [
      { name: "holder", type: "address" },
      { name: "index", type: "uint256" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "glyphOwner",
    stateMutability: "view",
    inputs: [{ name: "id", type: "uint256" }],
    outputs: [{ name: "holder", type: "address" }],
  },
  { type: "function", name: "issuanceCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "nextGlyphId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "issuance",
    stateMutability: "view",
    inputs: [{ name: "index", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "firstId", type: "uint256" },
          { name: "count", type: "uint256" },
          { name: "startSlot", type: "uint256" },
          { name: "holder", type: "address" },
          { name: "previousHolder", type: "address" },
          { name: "seed", type: "bytes32" },
        ],
      },
    ],
  },
  {
    type: "event",
    name: "GlyphBatchCreated",
    inputs: [
      { name: "holder", type: "address", indexed: true },
      { name: "firstId", type: "uint256", indexed: true },
      { name: "count", type: "uint256", indexed: false },
      { name: "previousHolder", type: "address", indexed: true },
      { name: "seed", type: "bytes32", indexed: false },
    ],
  },
] as const;

export const potAbi = [
  { type: "function", name: "reserveBalance", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "claimBalance", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalRedeemed", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
] as const;

/** Uniswap Permit2 AllowanceTransfer: the Universal Router pulls input tokens through it. */
export const permit2Abi = [
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "user", type: "address" },
      { name: "token", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
      { name: "nonce", type: "uint48" },
    ],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "spender", type: "address" },
      { name: "amount", type: "uint160" },
      { name: "expiration", type: "uint48" },
    ],
    outputs: [],
  },
] as const;

export const universalRouterAbi = [
  {
    type: "function",
    name: "execute",
    stateMutability: "payable",
    inputs: [
      { name: "commands", type: "bytes" },
      { name: "inputs", type: "bytes[]" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

/**
 * Uniswap V4Quoter. On chain the function is nonpayable (it reverts internally to read the result);
 * it is declared view here so it is called with eth_call, which is how the Quoter is meant to be used.
 */
export const quoterAbi = [
  {
    type: "function",
    name: "quoteExactInputSingle",
    stateMutability: "view",
    inputs: [
      {
        name: "params",
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
          { name: "exactAmount", type: "uint128" },
          { name: "hookData", type: "bytes" },
        ],
      },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "gasEstimate", type: "uint256" },
    ],
  },
] as const;

export const stateViewAbi = [
  {
    type: "function",
    name: "getSlot0",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "tick", type: "int24" },
      { name: "protocolFee", type: "uint24" },
      { name: "lpFee", type: "uint24" },
    ],
  },
  {
    type: "function",
    name: "getLiquidity",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ name: "liquidity", type: "uint128" }],
  },
] as const;
