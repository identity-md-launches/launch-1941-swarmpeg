// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmPeg} from "../../src/SwarmPeg.sol";
import {SwarmPegHook} from "../../src/SwarmPegHook.sol";
import {MaintenancePot} from "../../src/MaintenancePot.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LaunchFactoryHarness} from "./LaunchFactoryHarness.sol";
import {TestRouter} from "./TestRouter.sol";
import {MockIMD} from "./MockIMD.sol";

abstract contract Fixture is Test {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint160 internal constant Q96 = 79228162514264337593543950336;
    PoolManager internal manager;
    LaunchFactoryHarness internal factory;
    SwarmPeg internal token;
    SwarmPegHook internal hook;
    MaintenancePot internal pot;
    MockIMD internal imd;
    TestRouter internal router;
    PoolKey internal key;
    address internal trader;
    address internal requester;
    address internal swarm;

    function _deploy(bool tokenBelow) internal {
        _deployWithPair(tokenBelow, true);
    }

    function _deployWithPair(bool tokenBelow, bool mockPair) internal {
        if (mockPair) {
            vm.chainId(1);
            vm.warp(1_800_000_000);
            vm.roll(1000);
            vm.etch(IMD, address(new MockIMD()).code);
        }
        imd = MockIMD(IMD);
        manager = new PoolManager(address(this));
        factory = new LaunchFactoryHarness(manager);
        bytes32 tokenHash = keccak256(type(SwarmPeg).creationCode);
        for (uint256 i;; ++i) {
            address predicted = _predict(address(factory), bytes32(i), tokenHash);
            if ((predicted < IMD) == tokenBelow) {
                token = factory.deployToken(bytes32(i));
                break;
            }
        }
        bytes32 hash =
            keccak256(abi.encodePacked(type(SwarmPegHook).creationCode, abi.encode(manager, token, address(factory))));
        for (uint256 i; i < 500_000; ++i) {
            address predicted = _predict(address(factory), bytes32(i), hash);
            if (uint160(predicted) & 0x3fff == 0x20cc) {
                hook = factory.deployHook(bytes32(i), token);
                break;
            }
        }
        require(address(hook) != address(0), "salt search exhausted");
        pot = hook.maintenancePot();
        key = hook.poolKey();
        router = new TestRouter(manager);
        trader = makeAddr("trader");
        requester = makeAddr("requester");
        swarm = makeAddr("swarm distributor");
    }

    function _initializeAndSeed() internal {
        factory.initialize(key, Q96);
        imd.mint(address(factory), 1_000_000 ether);
        factory.modify(key, -887220, 887220, 1_000_000 ether);
        imd.mint(trader, 1_000_000 ether);
        factory.send(token, trader, 1_000_000 ether);
        vm.startPrank(trader);
        imd.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bool buy, bool exactInput, uint256 amount) internal returns (BalanceDelta) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == IMD);
        SwapParams memory params = SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.prank(trader);
        return router.swap(key, params, amount * 4 + 100, 0, "");
    }

    function _imdDelta(BalanceDelta delta) internal view returns (int128) {
        return Currency.unwrap(key.currency0) == IMD ? delta.amount0() : delta.amount1();
    }

    function _tokenDelta(BalanceDelta delta) internal view returns (int128) {
        return Currency.unwrap(key.currency0) == IMD ? delta.amount1() : delta.amount0();
    }

    function _predict(address deployer, bytes32 salt, bytes32 hash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, hash)))));
    }
}
