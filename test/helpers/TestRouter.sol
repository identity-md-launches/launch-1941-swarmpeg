// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TestRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;
    bool private active;

    error Slippage();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        uint256 maxInput,
        uint256 minOutput,
        bytes memory hookData
    ) external nonReentrant returns (BalanceDelta delta) {
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        IERC20(Currency.unwrap(input)).safeTransferFrom(msg.sender, address(this), maxInput);
        active = true;
        delta = abi.decode(manager.unlock(abi.encode(key, params, hookData)), (BalanceDelta));
        active = false;
        uint256 used = uint256(-int256(params.zeroForOne ? delta.amount0() : delta.amount1()));
        uint256 received = uint256(int256(params.zeroForOne ? delta.amount1() : delta.amount0()));
        if (used > maxInput || received < minOutput) revert Slippage();
        if (maxInput > used) input.transfer(msg.sender, maxInput - used);
        if (received != 0) output.transfer(msg.sender, received);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager) && active, "callback");
        (PoolKey memory key, SwapParams memory params, bytes memory hookData) =
            abi.decode(data, (PoolKey, SwapParams, bytes));
        BalanceDelta delta = manager.swap(key, params, hookData);
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            currency.transfer(address(manager), uint256(-int256(amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(int256(amount)));
        }
    }
}
