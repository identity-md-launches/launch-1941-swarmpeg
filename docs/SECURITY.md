# Security review and validation scope

This is the implementer's review, not an independent audit. The provided Ethereum and v4 security references and admission test definitions were read before implementation. Source, constructors, permission dispatch, delta arithmetic, storage transitions, external calls and failure rollback were reviewed against them after implementation.

## Financial and authority invariants

1. SwarmPeg supply stays exactly `10^27` minor units. Only the constructor calls `_mint`; no external mint/burn/admin/proxy/upgrade/destruct path exists.
2. No hook, pot or token ownership is assigned to a deployer, `msg.sender`, `tx.origin`, or IMD operator. The token's constructor recipient is an initial balance, not an admin.
3. Only the immutable PoolManager invokes callbacks. Only the supplied factory initializes the one immutable token/IMD pool at the policy fee/spacing. Runtime address bits agree with `getHookPermissions()`.
4. Each fee is `floor(gross IMD / 50)`. In a successful swap the pot receives exactly that fee in claims and the hook has zero currency delta. No fee is assessed in SWARMPEG.
5. Claims are minted to the pot, never to an operator. The hook holds no IMD, SWARMPEG, or fee claims. Successful unlocks end with all manager debts settled.
6. Pot redemption has fixed currency and recipient, only burns its own claims, gates the unlock callback, and uses reentrancy protection. Effects precede interaction. Transfer failure reverses the burn and counters. Claims plus materialized IMD account for all fees (and unsolicited donations, if any).
7. LP additions/removals and factory zero-liquidity fee collection have no hook gate or return delta. The factory's existing liquidity powers are outside this hook's control.
8. No production entry point pulls a third party's tokens. Test routers pull only `msg.sender` before unlock, then settle their own balance using sync → transfer → settle.
9. Every live glyph slot corresponds to a whole balance unit. Historical/retired IDs grant no live ownership. IDs are globally monotonic and never reused. ERC-20 transfer outcomes do not depend on any renderer or external hook call.
10. Pulse and cosmetic entropy confer no financial rights. Routers cannot spoof glyph recipients through hookData, and `tx.origin` is not used.

## Return-delta review

The address exposes `beforeSwapReturnDelta` because IMD is specified in two of the four modes. In an exact-input buy it returns only `floor(input/50)` and leaves at least 98% of any non-dust input to the core. It never claims to execute the entire swap. Exact-output sells increase the core output by `floor(net/49)` and retain only that difference. The after callback verifies these legs filled, preventing a fee-only no-liquidity or price-bound execution. The other modes use actual IMD core deltas in `afterSwap`. Amount and conversion bounds are explicit and checked casts are used.

All fees are credited by `mint(pot, IMD-id, fee)`. This creates a hook debit offset exactly by its returned positive IMD delta. There is no dependence on unsettled input inventory, transfer to a callback-bearing fee recipient, nested swap, token-to-ETH conversion, ERC-6909 operator approval, or mutable fee destination. The pot cannot change settings or call the hook as a router to exploit v4's self-call hook bypass.

## Adversarial tests

- Both currency orderings; exact input/output buys and sells; fuzzed amounts and directions with the assignment's seed.
- Fresh manager with token-only liquidity and zero IMD inventory before a buy, followed by claim redemption.
- No liquidity, partial fills in specified and unspecified IMD modes, dust rounding, bad amount bounds, foreign pool keys, unauthorized/duplicate initialization and callbacks.
- Slippage revert rolls back pool effects, fees, pulse and glyph metadata.
- Invalid/duplicate claim redemption, simulated IMD transfer rejection, and a malicious-token callback attempting reentrant redemption.
- Factory allocation, mined CREATE2 address, constructor compatibility without external code, wrong permission address, LP fee collection and full withdrawal.
- Allowance/balance/zero-recipient failures; fractional crossings; self/zero transfer behavior; retirement across many batches; bulk billion-token transfer with bounded gas.
- Stateful transfer sequences check all small-holder slots for exact counts, unique/live ownership, and supply conservation.
- Stateful swap/redeem/time sequences check fee conservation, reserve composition, manager settlement, token conservation, no router dust and pulse bounds.
- Runtime disassembly scans step over PUSH immediates and reject SELFDESTRUCT, CALLCODE and DELEGATECALL; deployed sizes and lack of linked library placeholders are checked by `tools/check_artifacts.py`.

## Accepted limits and assumptions

- **No reserve spending:** all 2% fees are permanently reserved. There is no administrative recovery or future spending switch. This is the explicit interpretation chosen for an ownerless pot with no expenditure policy.
- **Two modes require full fills:** partial exact-input IMD buys and partial exact-output IMD sells revert. Quotes and frontend limits must account for this.
- **Pool-local fee:** other venues and ERC-20 transfers are untaxed. A fee on every possible venue is incompatible with the standard unrestricted token required by this launch.
- **Predictable cosmetic entropy:** transfers and trade/block values can be manipulated; this does not determine economic outcomes. Wash trades can raise pulse, subject to swap fees. Dust rounding can produce zero hook fees. There is no claim that pulse measures unique people or honest trading activity.
- **Glyph semantics:** these are integer balance slots with retirement/new issuance, not independently transferable NFTs or permanent identities following individual ERC-20 units. Intermediate router transfers and refunds affect their own and recipients' slots.
- **No token-generalization claim:** SwarmPeg is a standard ERC-20 with internal metadata tracking; IMD at the specified address is the only accepted pair. Arbitrary rebasing, fee-on-transfer or callback tokens are not supported. The optional fork exercise verified real IMD transfer behavior at block 26,203,520. Future external IMD or manager behavior remains an external dependency.
- **Gas/storage:** transfer bookkeeping is O(1) append and O(log batches) truncation; live ownership uses O(log issuances + log holder batches). Storage grows by issuance history. Rendering loops are bounded at 18 network nodes and 80 potential pixels and occur only on reads. There is no supply-sized loop.
- **Read-only art changes:** animation parameters and SVG/URI bytes change as pulse decays or new trades arrive. Wallets that cache metadata or sanitize SVG animations may show stale/static art.
- **Irreversibility:** an unupgradeable system has no emergency pause or repair authority. The factory's liquidity custody, independent production review and accurate deployment parameter resolution matter.

## Tooling evidence

The required Foundry build, test and formatter checks and the artifact checker are the local verification commands in README.md. Default tests are deterministic and offline; no test reads or writes environment variables. The separately selected rehearsal profile uses a public RPC, real IMD, and a fresh local PoolManager/factory probe. It does not exercise the production IMD factory, its attestation system, swarm distribution contract, or launch wallet.

Foundry lint notices about block-derived entropy and timestamps correspond to the explicitly cosmetic seed and pulse decay. Whole-minute rounding is intentional. Concatenating strings constructs SVG/JSON and is not used as an ambiguous signature/hash encoding; hashed input tuples use `abi.encode`. Checked signed/unsigned conversions are bounded by core deltas and explicit amount limits. Reentrancy into the pot is covered by its guard, active-callback gate and failure tests.

Slither, Mythril, formal verification and an independent external audit were not performed in this contribution. Mainnet deployment, source verification, actual-factory simulation and independent approval remain responsibilities of the network's deployment/review pipeline.
