#!/usr/bin/env python3
"""Offline launch consistency and opcode checks. Run after forge build."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "launch.json").read_text())
assert list(manifest)[0] == "kind" and manifest["kind"] == "univ4_hook"
assert set(manifest) == {"kind", "hook", "token", "pool", "notes"}
assert len(manifest["notes"]) <= 4000
assert manifest["hook"]["constructorArgs"] == ["$poolManager", "$token", "$factory"]
assert manifest["token"] == {"contract": "SwarmPeg", "name": "SwarmPeg", "symbol": "SWARMPEG", "decimals": 18}
assert manifest["pool"] == {
    "pairedCurrency": "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
    "fee": 12500, "tickSpacing": 60, "initialPrice": "79228162514264337593543950336",
}
flags = {"beforeInitialize": 1 << 13, "beforeSwap": 1 << 7, "afterSwap": 1 << 6,
         "beforeSwapReturnDelta": 1 << 3, "afterSwapReturnDelta": 1 << 2}
assert set(manifest["hook"]["permissions"]) == set(flags)
assert len(manifest["hook"]["permissions"]) == len(flags)
assert sum(flags.values()) == 0x20cc
for name, inputs in [("SwarmPeg", []), ("SwarmPegHook", ["address"] * 3),
                     ("MaintenancePot", ["address", "address"])]:
    artifact = json.loads((ROOT / "out" / (name + ".sol") / (name + ".json")).read_text())
    constructor = next(a for a in artifact["abi"] if a["type"] == "constructor")
    assert [a["type"] for a in constructor["inputs"]] == inputs
    assert not artifact["bytecode"]["linkReferences"]
    runtime = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
    creation = bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))
    assert 0 < len(runtime) <= 24576 and len(creation) <= 49152
    i = 0
    while i < len(runtime):
        op = runtime[i]
        assert op not in (0xF2, 0xF4, 0xFF), (name, i, op)
        i += 1 + (op - 0x5F if 0x60 <= op <= 0x7F else 0)
    print(f"{name}: constructor matches; runtime {len(runtime)} B; no links or forbidden opcodes")
print("Manifest/source consistency checks passed (not an independent network-schema attestation).")
