# Additional adversarial tests

These tests extend the existing suite without changing the implementation, manifest, dependencies, or configuration. They run offline using the vendored real Uniswap v4 PoolManager. The IMD token is the existing local ERC-20 double; these tests do not attest mainnet state or the network's production factory implementation.

| File | Property checked |
| --- | --- |
| `AtomicLaunch.t.sol` | Token, hook, constructor-created pot, initialization and 88/2/10 allocation in one factory call, in both currency orders. An address without hook code cannot be preinitialized. A failed launch leaves no deployments, and the same salts can be retried. |
| `HookDifferential.t.sol` | Compare all four swap modes with an independently executed unhooked pool at the same price, liquidity and LP fee. Only the IMD delta differs, by 2% of gross IMD. Check price, LP fee growth, wallet balances, claims and emitted fee/trade/pulse data. Explicit dust boundaries complement 1,000 fuzz runs per currency order. |
| `HookFailurePaths.t.sol` | Reject mutations of every PoolKey field, invalid signed amounts, impossible delta signs and overflowing exact-output gross-ups. Verify the exact wrapped partial-fill error, rollback after settlement failure, and recovery after nested redemption. Before-swap deltas cannot consume the entire input. |
| `TokenFailurePaths.t.sol` | Failed approved spends restore allowances and glyph state; revoked approvals cannot be replayed. Check zero receivers/spenders, out-of-range views, previous-holder attribution, and one-wei retirement/regrowth. |
| `GlyphMetadata.t.sol` | Decode base64 JSON and the embedded SVG, then compare with live views and an independent encoder. Validate attributes, actual node/connection counts, animation styles and pulse monotonicity. Retired IDs fail all hook views; checkpoints preserve artwork; block context affects birth seeds. |
| `GlyphModelInvariant.t.sol` | Explicit stacks model the lazy glyph batches for four actors, independently tracking balances, allowances and future IDs. Mix direct/delegated/self/zero transfers, complete drains, approvals and rejected operations. Check surviving birth data and a rolling sample of retired IDs after every action. |
| `ReserveSequenceInvariant.t.sol` | Three traders mix swaps, round trips, direct token/claim donations, partial/full redemption, invalid redemption, failed transfers, time passage and liquidity changes. Independent ghost totals account separately for fees, donations and redemptions. Check supply conservation, zero transient debts, claim backing, no intermediary balances, exact pulse evolution and full redemption after each sequence. |

Both new invariant campaigns use 256 runs of depth 96, with `fail-on-revert = true`. Expected failures are asserted inside handlers; unexpected reverts fail the campaign. Swap-fee ghosts use the real manager's core swap event and the final wallet delta, rather than taking the hook's fee counter as an oracle. The glyph model uses at most twelve circulating whole tokens so every live slot can be checked without supply-sized loops; the original suite retains its billion-token transfer test.

The atomic launch probe retains the 88% seed allocation at the factory; actual pool seeding, swaps and LP-fee collection are exercised by the existing fixture and the other integration suites. This probe is not a replacement production factory. Test actors and mocks are local fixtures, not deployment recipients or parameters.

Run the entire suite with the assignment seed:

```sh
forge build --offline
FOUNDRY_FUZZ_SEED=0x5c9e50d4536d3857e26910e56dd149ff53d36cc20afa9ba4cf829b878581f520 forge test --offline
```

To keep generated build artifacts inside the disposable test area, prefix either command with `FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache`. Nothing delivered imports `test/scratch/`, uses a fork or FFI, or reads/writes environment variables through cheatcodes.

The supplied Pashov fizz and Trail of Bits references informed conservation, state-transition, independent-oracle and non-vacuity checks. The Solidity tests are new project-specific code, not copied templates. No confirmed implementation defect was found by these tests; passing bounded campaigns is not a proof of all possible behavior.
