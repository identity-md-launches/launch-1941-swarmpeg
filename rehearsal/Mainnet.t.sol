// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, BalanceDelta, Currency, SwapParams, TickMath, IPoolManager} from "../test/helpers/Fixture.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice Explicit network-only rehearsal against real IMD bytecode/storage, at a fixed block.
/// @dev Run with FOUNDRY_PROFILE=rehearsal. No environment, keys, broadcasts or mainnet state writes.
contract MainnetRehearsalTest is Fixture {
    using TransientStateLibrary for IPoolManager;
    uint256 constant FORK_BLOCK = 26_203_520;

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com", FORK_BLOCK);
        assertEq(block.chainid, 1);
        assertEq(block.number, FORK_BLOCK);
        _deployWithPair(true, false);
        assertEq(imd.symbol(), "IMD");
        assertEq(imd.decimals(), 18);
        factory.initialize(key, Q96);
        // Supply funding only in local fork storage; real IMD implementation remains untouched.
        deal(IMD, address(factory), 1_000_000 ether);
        deal(IMD, trader, 1_000_000 ether);
        factory.modify(key, -887220, 887220, 1_000_000 ether);
        factory.send(token, trader, 1_000_000 ether);
        vm.startPrank(trader);
        imd.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_realIMDAllModesRedeemAndFactoryCollect() public {
        for (uint256 i; i < 4; ++i) {
            bool buy = i % 2 == 0;
            bool exactInput = i < 2;
            uint256 feesBefore = hook.totalFees();
            uint256 imdBefore = imd.balanceOf(trader);
            BalanceDelta delta = _swap(buy, exactInput, 100 ether);
            uint256 fee = hook.totalFees() - feesBefore;
            int256 change = _imdDelta(delta);
            uint256 gross = buy ? uint256(-change) : uint256(change) + fee;
            assertEq(fee, gross / 50);
            assertEq(int256(imd.balanceOf(trader)) - int256(imdBefore), change);
        }
        uint256 fees = hook.totalFees();
        pot.redeem(fees);
        assertEq(imd.balanceOf(address(pot)), fees);
        assertEq(pot.claimBalance(), 0);
        (BalanceDelta collected,) = factory.modify(key, -887220, 887220, 0);
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertGt(int256(collected.amount0()) + collected.amount1(), 0);
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0);
    }
}
