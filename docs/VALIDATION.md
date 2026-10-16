# Local validation record

All results below are contributor checks, not independent acceptance or an external audit.

| Check | Result |
| --- | --- |
| `forge build`, Solidity 0.8.26 | Pass |
| Default `forge test` | 39 passed, 0 failed, 0 skipped |
| Fuzz seed | `0x5c9e50d4536d3857e26910e56dd149ff53d36cc20afa9ba4cf829b878581f520` |
| Stateless fuzzing | 256 runs per fuzz test |
| Stateful invariants | 64 runs × 64 calls each, fail-on-revert enabled |
| Pinned `Token.protected.t.sol` | All 7 tests pass, unchanged source in scratch |
| Pinned `Hook.protected.t.sol` | All 4 tests pass, unchanged source in scratch |
| Pinned `Owners.protected.t.sol` | Read; its unavailable `OwnerChecks` support was not recreated. Equivalent ownerless/factory-collection behavior is exercised by the delivered suites. |
| Optional real-IMD mainnet fork | Pass at block 26,203,520: all four modes, pot redemption, factory zero-liquidity collect |
| `forge fmt --check` | Pass |
| Artifact/manifest consistency | Pass via `tools/check_artifacts.py` |
| Library SHA-256 checks | Pass via `sha256sum --check DEPENDENCIES.sha256` |
| Gas profiling | `forge test --match-test test_allFourSwapModes --gas-report` passed in both currency orders |
| SVG generation | Solidity-generated pulse 0/500/1000 samples parse as XML and have 6/12/18 nodes respectively |

The protected tests were copied without edits into temporary scratch scaffolding and supplied their documented probe inputs outside the tests. They were not weakened to fit the project. Their temporary environment-driven files are excluded from the delivered default suite. `HookFlags` exposes the exact names their imports require. Vendored forge-std v1.12.0 includes the `fail(string)` overload used by the pinned hook check.

| Production artifact | Runtime bytes | EIP-170 limit |
| --- | ---: | ---: |
| SwarmPeg | 3,940 | 24,576 |
| SwarmPegHook | 10,997 | 24,576 |
| MaintenancePot | 1,730 | 24,576 |

All three runtime scans contain no executable SELFDESTRUCT, DELEGATECALL or CALLCODE after skipping PUSH data. All creation bytecodes are below the EIP-3860 limit, and no linked-library placeholders remain.

No production factory transaction, deployment receipt, explorer verification, independent audit, Slither, Mythril, or formal verification is claimed. The network's attesting deployer is responsible for the real factory launch and publishing its actual addresses.
