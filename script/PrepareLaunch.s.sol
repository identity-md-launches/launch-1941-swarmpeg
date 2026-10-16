// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmPeg} from "../src/SwarmPeg.sol";
import {SwarmPegHook} from "../src/SwarmPegHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Pure CREATE2 preparation for the actual network factory. Never broadcasts or reads keys.
contract PrepareLaunch {
    error InvalidParameters();
    error SaltNotFound();

    function run(address factory, IPoolManager manager, SwarmPeg token, uint256 start, uint256 attempts)
        external
        pure
        returns (bytes32 salt, address predictedHook, bytes32 initCodeHash)
    {
        if (
            factory == address(0) || address(manager) == address(0) || address(token) == address(0) || attempts == 0
                || attempts > 1_000_000
        ) revert InvalidParameters();
        initCodeHash = keccak256(abi.encodePacked(type(SwarmPegHook).creationCode, abi.encode(manager, token, factory)));
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predictedHook =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash)))));
            if (HookFlags.matches(predictedHook, 0x20cc)) return (salt, predictedHook, initCodeHash);
        }
        revert SaltNotFound();
    }
}
