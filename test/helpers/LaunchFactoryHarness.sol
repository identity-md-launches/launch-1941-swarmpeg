// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmPeg} from "../../src/SwarmPeg.sol";
import {SwarmPegHook} from "../../src/SwarmPegHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Local deployment/position probe, not a substitute for the network's production factory.
contract LaunchFactoryHarness is IUnlockCallback {
    IPoolManager public immutable manager;
    address public immutable controller;

    constructor(IPoolManager manager_) {
        manager = manager_;
        controller = msg.sender;
    }

    modifier onlyController() {
        require(msg.sender == controller, "controller");
        _;
    }

    function deployToken(bytes32 salt) external onlyController returns (SwarmPeg) {
        return new SwarmPeg{salt: salt}();
    }

    function deployHook(bytes32 salt, SwarmPeg token) external onlyController returns (SwarmPegHook) {
        return new SwarmPegHook{salt: salt}(manager, token, address(this));
    }

    function split(SwarmPeg token, address requester, address swarmDistributor) external onlyController {
        require(token.balanceOf(address(this)) == token.SUPPLY(), "already split");
        require(token.transfer(requester, token.SUPPLY() * 2 / 100));
        require(token.transfer(swarmDistributor, token.SUPPLY() * 10 / 100));
    }

    function send(SwarmPeg token, address recipient, uint256 amount) external onlyController {
        require(token.transfer(recipient, amount));
    }

    function initialize(PoolKey memory key, uint160 price) external onlyController {
        manager.initialize(key, price);
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 liquidity)
        external
        onlyController
        returns (BalanceDelta delta, BalanceDelta fees)
    {
        return abi.decode(manager.unlock(abi.encode(key, lower, upper, liquidity)), (BalanceDelta, BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        (PoolKey memory key, int24 lower, int24 upper, int256 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta delta, BalanceDelta fees) =
            manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidity, bytes32(0)), "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta, fees);
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
