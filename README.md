# SwarmPeg

SwarmPeg (`SWARMPEG`) is a fixed-supply Ethereum ERC-20 with an immutable Uniswap v4 hook, an ownerless IMD fee reserve, and fully on-chain animated glyphs tied to whole-token balances.

The deliverable includes `launch.json`, the token and hook, vendored dependencies, factory deployment preparation, deterministic tests, an optional mainnet fork rehearsal, and generated [SVG previews](docs/art/index.html). No mainnet transaction has been broadcast. The IdentityMD network's attesting deployer performs the production factory launch after acceptance.

## Build and verify

Foundry with Solidity **0.8.26** is required. Cancun, optimizer 200, `via_ir = true`, and `bytecode_hash = "none"` are pinned in `foundry.toml`. All Solidity dependencies are ordinary files under `lib/`; there are no submodules, npm dependencies, runtime downloads, FFI, or filesystem cheatcode permissions. The default suite requires no network or environment configuration.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x5c9e50d4536d3857e26910e56dd149ff53d36cc20afa9ba4cf829b878581f520 forge test
forge fmt --check
python3 tools/check_artifacts.py
```

The same fuzz seed is pinned in Foundry. Tests cover real PoolManager settlement, both currency orderings, all four swap modes, dust, partial fills, slippage rollback, factory initialization and LP-fee collection, empty IMD inventory, claim redemption and reentrancy, whole-balance glyph ownership, and stateful accounting invariants. Tests use a local factory probe, not the production network factory's implementation.

An explicit network rehearsal uses **real IMD bytecode and storage** at Ethereum block **26,203,520**, with a freshly deployed PoolManager and a local factory probe. Funding changes only local fork storage. It passed buys and sells in both modes, fee redemption, and factory LP-fee collection:

```sh
FOUNDRY_PROFILE=rehearsal forge test -vv
```

That profile alone needs the public RPC URL embedded in `rehearsal/Mainnet.t.sol`. The offline acceptance suite does not run it. This is not a rehearsal of the network's production attestation or factory ABI.

## Contracts and launch parameters

| Item | Value |
| --- | --- |
| Network | Ethereum mainnet, chain ID 1 |
| Token artifact | `src/SwarmPeg.sol:SwarmPeg` |
| Token constructor | No arguments |
| Name / symbol / decimals | SwarmPeg / SWARMPEG / 18 |
| Supply | `1_000_000_000e18` = `1000000000000000000000000000` minor units |
| Initial holder | Factory (`msg.sender`), entire supply minted once |
| Pool / requester / swarm allocation | 88% / 2% / 10%, performed by factory policy |
| Hook artifact | `src/SwarmPegHook.sol:SwarmPegHook` |
| Hook constructor, in order | `IPoolManager $poolManager`, `SwarmPeg $token`, `address $factory` |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals |
| LP fee / tick spacing | `12500` (1.25%) / `60` |
| Manifest initial price | `79228162514264337593543950336`, policy sentinel |
| Actual opening price | Network deployer derives from 2,500 IMD fully diluted value and currency sort order |
| Hook address permission mask | `8396` / `0x20cc`, low 14 address bits |
| Maintenance reserve | New `MaintenancePot` deployed inside the hook constructor; `maintenancePot()` getter |

The factory allocates 880 million tokens to seeding, 20 million to the requester paying for the launch (or the chain treasury under the stated fallback policy), and 100 million to the network's MerkleDistributor. These are factory obligations: the token does not guess recipient addresses, create a substitute distributor, or make an additional allocation to the hook or pot. The task's `$owner` is not used because these contracts have no admin role.

The token has no public mint, burn, owner, pause, fee, blocklist, upgrade, or external callback. Glyph bookkeeping changes no ERC-20 amounts. The hook and pot also have no owner, pausing, upgrades, withdrawal authority, arbitrary-call ability, or tunable fees. Constructors do not call external tokens or managers or require their code to exist; only the hook's own pot is deployed internally.

## Deployment handoff

`launch.json` is included because this assignment explicitly requests it. It names exactly two launch artifacts and uses only the supplied deployment placeholders. The pot is an internal child, not a third manifest deployment. The manifest checker included here checks consistency with compiled artifacts; it does not purport to replace the network's independent manifest validator.

1. The network deployer resolves the actual Ethereum factory and PoolManager, checks the chain and policy, and deploys the token from the factory.
2. Resolve `$token` and form hook init code from the pinned build plus `abi.encode($poolManager, $token, $factory)`.
3. Mine CREATE2 against **the actual factory address** for low 14 bits `0x20cc`. Changing any constructor argument, compiler setting, dependency, or source changes the salt search.
4. Deploy the hook and initialize its exact pool in one factory transaction. The hook requires the factory as initialization `sender`, the supplied PoolManager as callback caller, and the token/IMD key at fee 12500 and spacing 60. The required `beforeInitialize` callback also prevents pool initialization while the predicted hook has no code.
5. The factory seeds its liquidity position and distributes the 88/2/10 allocations according to policy. It owns the LP position and remains able to collect with a zero liquidity change and to remove liquidity; neither operation incurs this hook's fee.
6. Publish the deployed token, hook, `maintenancePot()`, PoolId, creation/runtime hashes, transaction receipt, and verified sources in the network deployment record. No guessed production addresses are supplied here.

`script/PrepareLaunch.s.sol` is a pure salt/init-code-hash preparation tool. Its `run(factory, manager, token, start, attempts)` takes explicit addresses, searches at most one million salts per call, and never reads keys or broadcasts. The network can use the result in its own authorized deployment path. The local `LaunchFactoryHarness` tests the same CREATE2 and constructor sequence and checks the preparation tool against actual deployed bytecode; it is test scaffolding, not a proposed mainnet factory.

## Hook fee accounting

The fixed 2% hook fee is **in IMD**, as requested, and is additional to the 1.25% pool LP fee. It is not converted into ETH. A buy inputs IMD and outputs SWARMPEG. A sell inputs SWARMPEG and outputs IMD. The fee is `floor(gross IMD / 50)`; dust below 50 IMD minor units can round to zero. There is no minimum fee or privileged trader exemption.

| Swap mode | Fee calculation | Callback carrying IMD fee |
| --- | --- | --- |
| Exact-input buy, total IMD budget `G` | `floor(G / 50)`; pool receives budget `G - fee` | `beforeSwap` specified delta |
| Exact-output buy, core IMD cost `C` | `floor(C / 49)`; trader pays `C + fee` | `afterSwap` unspecified delta |
| Exact-input sell, gross core IMD output `G` | `floor(G / 50)`; trader receives `G - fee` | `afterSwap` unspecified delta |
| Exact-output sell, requested net IMD `N` | `floor(N / 49)`; core must output `N + fee` | `beforeSwap` specified delta |

For the two gross-up formulas, `floor((C + floor(C/49))/50) = floor(C/49)`, so all four modes use the same gross-IMD definition. Routers must quote and enforce user limits on the **final** deltas including this fee.

Exact-input buys and exact-output sells **revert with `PartialFillUnsupported`** if the core cannot completely fill their adjusted IMD leg at the supplied price limit. Their specified-currency fee is committed before execution and cannot be corrected by the unspecified-only `afterSwap` return. This avoids charging unfilled volume, including no-liquidity swaps. In the other two modes, partial execution is supported and taxed only on actual executed IMD. All rollback paths preserve funds, claims, pulse and glyph state. Inputs and adjusted specified amounts must fit positive `int128` magnitude.

The added permissions are `beforeInitialize`, `beforeSwap`, and `beforeSwapReturnDelta`, alongside the requested `afterSwap` and `afterSwapReturnDelta`. All other flags are false. There is no liquidity-return delta, dynamic LP fee override, NoOp trade implementation, or internal swap that could skip the hook. Every implemented callback checks the caller and exact bound pool. `sender` is treated as a router, not a wallet; `hookData` cannot assign ownership.

The fee applies to this launch pool. A standard ERC-20 cannot force a hook fee onto transfers, other pools, or off-pool trades.

## Ownerless maintenance reserve

Every fee accrues directly to the pot as an IMD ERC-6909 claim on the PoolManager. `poolManager.mint(pot, IMD-id, fee)` debits the hook by exactly the positive IMD return delta, leaving its transient balance zero. This works before the router supplies its IMD, including a fresh manager seeded with SWARMPEG only. The hook retains no fee tokens or claims.

Anyone can call `MaintenancePot.redeem(amount)` when the manager is locked (outside another unlock) to burn claims and take IMD **to the pot itself**. It has no recipient argument. `claimBalance()`, `reserveBalance()` and `totalRedeemed()` expose the reserve; `FeesRedeemed` records materialization. If IMD cannot transfer or inventory is insufficient, redemption reverts and preserves all claims. The guarded callback accepts only an active redemption from the immutable manager.

**Deliberate assumption:** the brief specifies an ownerless maintenance pot but no permitted expenditures, keeper payment rate, or recipient. Therefore the pot is an **irreversible reserve with no spending or withdrawal mechanism**. No person, factory, hook, or future governance can distribute it. Permissionless redemption and pulse checkpoints receive no bounty; their callers pay gas. This is a material economic choice, not a hidden admin backdoor or a promise of future configurability.

## Integer glyph model

Every address owns exactly `floor(balanceOf(address) / 1e18)` live glyph slots, including contracts and pool custody addresses. This is a fungible token with an art mirror, **not ERC-721 or a separately transferable NFT collection**. No wrapping, claims, registration, router allowlist, or manual sync is required.

- A whole-balance increase appends fresh globally unique IDs in a single lazy batch. Even the initial billion-token mint has one issuance record.
- A decrease retires the holder's last slots first. Retired IDs never revive. Receiving tokens later appends new IDs. Remaining slots keep their IDs and birth seed.
- Fractional amounts do not own an extra glyph. For example, 2.4 tokens owns two; sending 0.5 leaves one. A recipient moving from 0.8 to 1.3 gains one.
- Transfers through intermediate routers and refunds follow the same rule at each ERC-20 transfer; temporary custodians may create and retire IDs. IDs do not follow individual fungible units through a transfer.
- Self-transfers, zero transfers, and balance changes that stay within the same whole-token interval do not reroll existing IDs.

Birth seeds include transfer amount, the previous ERC-20 holder, both addresses, ID, chain, token contract, block number, timestamp, `prevrandao`, and preceding block hash. The hook combines that seed, previous holder, current owner, ID, rolling trade entropy, and current swarm pulse. Trade entropy includes actual trade deltas and parameters, router, block data, trade sequence and pulse. No trusted end-user assertion is extracted from a router's arbitrary bytes.

This is **cosmetic, predictable and manipulable entropy**, as requested by the trade/block seed model. A holder can grind new artwork by transferring and a validator can influence it. It is not secure randomness and determines no payout, rarity reward, claim amount, privilege, or price guarantee. Live composition evolves on trades and pulse decay; identity remains the live ID until retirement.

Balances, append and truncation use constant work or binary searches over batches. They never loop over the number of whole tokens. Issuance history grows with whole-balance-acquiring transfers and remains publicly readable after retirement.

| View / event | Purpose |
| --- | --- |
| Token `glyphCount(holder)` | Current whole-balance slot count |
| Token `glyphAt(holder, index)` | Live ID at a zero-based index; rejects out-of-range reads |
| Token `glyphOwner(id)`, `glyphData(id)` | Live owner, previous holder and birth seed; retired IDs revert |
| Token `issuanceCount()`, `issuance(index)` | Historical issuance batches; not proof of current ownership |
| `GlyphBatchCreated`, `GlyphBalanceChanged` | Indexable creation and integer-balance changes |
| Hook `glyphSeed(id)`, `glyphSVG(id)`, `glyphURI(id)` | Live seed, raw SVG, base64 JSON data URI |
| Hook `currentPulse()`, `glyphTraits()` | Current decayed pulse and rendering characteristics |
| `PoolBound`, `TradeRecorded`, `PulseUpdated`, `FeeAccrued` | Pool, router/trade, pulse and IMD accounting events |

## Pulse and artwork

Each nonzero trade with movement in both currencies adds **25** pulse, capped at **1000**. Pulse decays by **1 per 60 seconds**, reaching zero at most 1000 minutes after the last trade at maximum pulse. `currentPulse()` calculates decay without a transaction. Anyone may materialize it with `checkpointPulse()`; repeated calls preserve fractional-minute time and cannot postpone decay. A new trade starts a fresh decay interval.

Rendering uses **6–18 network nodes**, palette lightness **42–72%**, and animation duration **6000–1200 ms**, all monotonic with pulse. SVG contains CSS keyframes for pulsing nodes, drawing/fading connections, color breathing, and status blinks around original pixel agents inspired by the pixel-portrait genre. All geometry, colors, text, CSS, JSON and base64 data are generated on-chain; there are no external images, fonts, scripts or HTTP fetches. A reduced-motion media query disables animation when requested by the viewer.

The bounded renderer runs only in view functions. SVG previews at pulse 0, 500 and 1000 are generated from the Solidity renderer with a clearly labeled demonstration seed. Renderers/wallets may sanitize or disable CSS animation; opening raw SVG in a browser shows the intended animation.

## After launch

There are **no owner setters or activation steps**. Operations are public:

- Network deployer: resolve placeholders, mine and attest the exact build, deploy/initialize atomically, fund/seed, perform policy allocations, and publish verified addresses and receipt.
- Factory/policy: retain custody of LP liquidity and handle LP-fee claims and the swarm distributor. This hook cannot prevent its zero-liquidity fee collection.
- Integrators: use final swap deltas for slippage, handle the documented full-fill requirement, index glyph batch events, query live ownership before displaying a glyph, and refresh live artwork when pulse/trades change.
- Any interested caller: redeem pot claims when manager inventory permits; optionally checkpoint pulse. Both functions are permissionless and unpaid.
- Independent network reviewer: review the accepted contracts and manifest, simulate the actual factory launch, verify source and runtime hashes, and check current mainnet state. This contributor's checks are not an independent security audit.

See [security review](docs/SECURITY.md), [validation record](docs/VALIDATION.md), and [dependency provenance](dependencies.json) for evidence, limits, pinned commits and licenses. Verify the vendored files with `sha256sum --check DEPENDENCIES.sha256`.
