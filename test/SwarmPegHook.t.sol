// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Fixture,
    SwarmPeg,
    SwarmPegHook,
    MaintenancePot,
    Currency,
    BalanceDelta,
    SwapParams,
    TickMath,
    IPoolManager,
    PoolKey
} from "./helpers/Fixture.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TestRouter} from "./helpers/TestRouter.sol";

abstract contract SwapChecks is Fixture {
    using TransientStateLibrary for IPoolManager;

    function _assertSwap(bool buy, bool exactInput, uint256 amount) internal {
        uint256 oldIMD = imd.balanceOf(trader);
        uint256 oldToken = token.balanceOf(trader);
        uint256 oldFees = hook.totalFees();
        uint256 oldClaims = pot.claimBalance();
        BalanceDelta delta = _swap(buy, exactInput, amount);
        uint256 fee = hook.totalFees() - oldFees;
        int128 imdDelta = _imdDelta(delta);
        int128 tokenDelta = _tokenDelta(delta);
        uint256 gross = buy ? uint256(-int256(imdDelta)) : uint256(int256(imdDelta)) + fee;
        assertEq(fee, gross / 50, "2% of gross IMD");
        assertEq(pot.claimBalance(), oldClaims + fee, "100% to pot");
        assertEq(int256(imd.balanceOf(trader)) - int256(oldIMD), imdDelta, "IMD wallet delta");
        assertEq(int256(token.balanceOf(trader)) - int256(oldToken), tokenDelta, "token wallet delta");
        if (buy && exactInput) assertEq(-int256(imdDelta), int256(amount));
        if (!buy && !exactInput) assertEq(int256(imdDelta), int256(amount));
        if (!buy && exactInput) assertEq(-int256(tokenDelta), int256(amount));
        if (buy && !exactInput) assertEq(int256(tokenDelta), int256(amount));
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(pot)), 0);
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0);
        assertEq(IPoolManager(address(manager)).currencyDelta(address(hook), Currency.wrap(IMD)), 0);
        assertFalse(IPoolManager(address(manager)).isUnlocked());
    }

    function test_allFourSwapModes() public {
        _assertSwap(true, true, 100 ether);
        _assertSwap(false, true, 100 ether);
        _assertSwap(true, false, 100 ether);
        _assertSwap(false, false, 100 ether);
        assertEq(hook.tradeCount(), 4);
        assertEq(hook.currentPulse(), 100);
    }

    function testFuzz_feeAllModes(uint80 raw, bool buy, bool exactInput) public {
        _assertSwap(buy, exactInput, bound(uint256(raw), 1000, 10_000 ether));
    }

    function test_dustRoundingHasNoMinimumTax() public {
        _assertSwap(true, true, 48);
        _assertSwap(false, false, 48);
        assertEq(hook.totalFees(), 0);
        _assertSwap(true, true, 50);
        _assertSwap(false, false, 49);
        assertEq(hook.totalFees(), 2);
    }
}

contract SwarmPegHookTest is SwapChecks {
    function setUp() public {
        _deploy(true);
        _initializeAndSeed();
    }

    function test_permissionsAddressSizeAndNoOwner() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeAddLiquidity || p.afterAddLiquidity);
        assertFalse(p.afterInitialize || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(uint160(address(hook)) & 0x3fff, hook.HOOK_FLAGS());
        assertLe(address(hook).code.length, 24_576);
        assertEq(address(pot.poolManager()), address(manager));
        assertEq(Currency.unwrap(pot.currency()), IMD);
        (bool ok,) = address(hook).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(pot).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(pot).call(abi.encodeWithSignature("withdraw(address,uint256)", trader, 1));
        assertFalse(ok);
    }

    function test_callbacksRejectUnauthorizedIncludingAfterSwap() public {
        SwapParams memory params = SwapParams(true, -1 ether, Q96 / 2);
        vm.expectRevert(SwarmPegHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(factory), key, Q96);
        vm.expectRevert(SwarmPegHook.OnlyPoolManager.selector);
        hook.beforeSwap(trader, key, params, "");
        vm.expectRevert(SwarmPegHook.OnlyPoolManager.selector);
        hook.afterSwap(trader, key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(MaintenancePot.OnlyPoolManager.selector);
        pot.unlockCallback(abi.encode(1));
        vm.prank(address(manager));
        vm.expectRevert(MaintenancePot.RedemptionNotActive.selector);
        pot.unlockCallback(abi.encode(1));
    }

    function test_foreignPoolAndInvalidAmountsRefused() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.prank(address(manager));
        vm.expectRevert(SwarmPegHook.InvalidPool.selector);
        hook.beforeSwap(trader, other, SwapParams(true, -1, Q96), "");
        vm.prank(address(manager));
        vm.expectRevert(SwarmPegHook.InvalidPool.selector);
        hook.afterSwap(trader, other, SwapParams(true, -1, Q96), BalanceDelta.wrap(0), "");
        int256[4] memory amounts = [int256(0), type(int256).min, type(int256).max, int256(type(int128).max) + 1];
        for (uint256 i; i < amounts.length; ++i) {
            vm.prank(address(manager));
            vm.expectRevert(SwarmPegHook.InvalidSwapAmount.selector);
            hook.beforeSwap(trader, key, SwapParams(true, amounts[i], Q96), "");
        }
    }

    function test_factoryCollectsLPFeesAndRemovesWithoutHookTax() public {
        _swap(true, true, 1000 ether);
        _swap(false, true, 1000 ether);
        uint256 fees = hook.totalFees();
        (BalanceDelta collected,) = factory.modify(key, -887220, 887220, 0);
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertGt(int256(collected.amount0()) + collected.amount1(), 0);
        (BalanceDelta removed,) = factory.modify(key, -887220, 887220, -1_000_000 ether);
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertEq(hook.totalFees(), fees);
    }

    function test_claimsCanBeRedeemedByAnyoneOnlyToPot() public {
        _swap(true, true, 100 ether);
        uint256 fee = hook.totalFees();
        assertEq(imd.balanceOf(address(pot)), 0);
        uint256 beforeCaller = imd.balanceOf(trader);
        vm.prank(trader);
        pot.redeem(fee / 2);
        assertEq(pot.claimBalance(), fee - fee / 2);
        assertEq(imd.balanceOf(address(pot)), fee / 2);
        assertEq(imd.balanceOf(trader), beforeCaller);
        pot.redeem(fee - fee / 2);
        assertEq(pot.reserveBalance(), fee);
        assertEq(pot.totalRedeemed(), fee);
        vm.expectRevert(MaintenancePot.InvalidAmount.selector);
        pot.redeem(1);
        vm.expectRevert(MaintenancePot.InvalidAmount.selector);
        pot.redeem(0);
    }

    function test_failedRedemptionPreservesClaimsAndReentrantRedemptionFails() public {
        _swap(true, true, 100 ether);
        uint256 fee = pot.claimBalance();
        imd.setRejectTransfers(true);
        vm.expectRevert();
        pot.redeem(fee);
        assertEq(pot.claimBalance(), fee);
        assertEq(pot.totalRedeemed(), 0);
        imd.setRejectTransfers(false);
        imd.setReentry(address(pot), abi.encodeCall(pot.redeem, (fee)));
        pot.redeem(fee);
        assertFalse(imd.reentrySucceeded());
        assertEq(pot.totalRedeemed(), fee);
        assertEq(pot.claimBalance(), 0);
    }

    function test_priceLimitPartialSpecifiedIMDRevertsWithoutTax() public {
        bool zeroForOne = Currency.unwrap(key.currency0) == IMD;
        SwapParams memory params = SwapParams(zeroForOne, -1000 ether, zeroForOne ? Q96 - 1 : Q96 + 1);
        uint256 balance = imd.balanceOf(trader);
        vm.prank(trader);
        vm.expectRevert();
        router.swap(key, params, 1000 ether, 0, "");
        assertEq(imd.balanceOf(trader), balance);
        assertEq(hook.totalFees(), 0);
        assertEq(hook.tradeCount(), 0);
        // Exact-output sell also fixes IMD before the swap and must roll back on partial fill.
        params = SwapParams(!zeroForOne, 1000 ether, !zeroForOne ? Q96 - 1 : Q96 + 1);
        vm.prank(trader);
        vm.expectRevert();
        router.swap(key, params, 2000 ether, 0, "");
        assertEq(hook.totalFees(), 0);
    }

    function test_partialUnspecifiedIMDChargesOnlyExecutedVolume() public {
        bool zeroForOne = Currency.unwrap(key.currency0) != IMD;
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-1) : int24(1));
        vm.prank(trader);
        BalanceDelta delta = router.swap(key, SwapParams(zeroForOne, -1000 ether, limit), 1000 ether, 0, "");
        assertLt(uint256(-int256(_tokenDelta(delta))), 1000 ether);
        assertGt(hook.totalFees(), 0);
        uint256 gross = uint256(int256(_imdDelta(delta))) + hook.totalFees();
        assertEq(hook.totalFees(), gross / 50);
    }

    function test_routerSlippageRollsBackPoolFeesPulseAndGlyphs() public {
        bool zeroForOne = Currency.unwrap(key.currency0) == IMD;
        uint256 next = token.nextGlyphId();
        vm.prank(trader);
        vm.expectRevert(TestRouter.Slippage.selector);
        router.swap(
            key,
            SwapParams(zeroForOne, -100 ether, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            100 ether,
            1000 ether,
            ""
        );
        assertEq(hook.totalFees(), 0);
        assertEq(hook.currentPulse(), 0);
        assertEq(token.nextGlyphId(), next);
    }

    function test_hookDataCannotAssignGlyphsToSpoofedHolder() public {
        address victim = makeAddr("victim");
        bool zeroForOne = Currency.unwrap(key.currency0) == IMD;
        vm.prank(trader);
        router.swap(
            key,
            SwapParams(zeroForOne, -100 ether, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            100 ether,
            0,
            abi.encode(victim)
        );
        assertEq(token.glyphCount(victim), 0);
        uint256 id = token.glyphAt(trader, token.glyphCount(trader) - 1);
        assertEq(token.glyphOwner(id), trader);
    }

    function test_pulseDecayCheckpointDoesNotFreezeFractionalMinutes() public {
        _swap(true, true, 100 ether);
        assertEq(hook.currentPulse(), 25);
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i = 1; i <= 60; ++i) {
            vm.warp(start + i);
            hook.checkpointPulse();
        }
        assertEq(hook.currentPulse(), 24);
        vm.warp(start + 600);
        assertEq(hook.currentPulse(), 15);
        _swap(false, true, 100 ether);
        assertEq(hook.currentPulse(), 40);
        vm.warp(block.timestamp + 1_000_000);
        assertEq(hook.currentPulse(), 0);
        hook.checkpointPulse();
        assertEq(hook.storedPulse(), 0);
    }

    function test_pulseSaturatesAndGlyphsAreUniqueAnimatedAndOnChain() public {
        uint256 first = token.glyphAt(trader, 0);
        uint256 second = token.glyphAt(trader, 1);
        bytes32 seed = hook.glyphSeed(first);
        assertNotEq(seed, hook.glyphSeed(second));
        (uint256 nodes0, uint256 duration0, uint256 lightness0) = hook.glyphTraits();
        for (uint256 i; i < 45; ++i) {
            _swap(i % 2 == 0, true, 1 ether);
        }
        assertEq(hook.currentPulse(), 1000);
        (uint256 nodes, uint256 duration, uint256 lightness) = hook.glyphTraits();
        assertGt(nodes, nodes0);
        assertLt(duration, duration0);
        assertGt(lightness, lightness0);
        assertNotEq(seed, hook.glyphSeed(first));
        string memory svg = hook.glyphSVG(first);
        assertTrue(_contains(svg, "@keyframes nodePulse"));
        assertTrue(_contains(svg, "@keyframes connect"));
        assertTrue(_contains(svg, "@keyframes breathe"));
        assertTrue(_contains(svg, "@keyframes blink"));
        assertTrue(_contains(svg, 'shape-rendering="crispEdges"'));
        assertTrue(_contains(hook.glyphURI(first), "data:application/json;base64,"));
        assertFalse(_contains(svg, "<script"));
        assertFalse(_contains(svg, "https://"));
        vm.expectRevert(abi.encodeWithSelector(SwarmPeg.GlyphNotLive.selector, 0));
        hook.glyphSVG(0);
    }

    function _contains(string memory full, string memory part) private pure returns (bool) {
        bytes memory a = bytes(full);
        bytes memory b = bytes(part);
        if (b.length > a.length) return false;
        for (uint256 i; i <= a.length - b.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }
}

contract ReverseCurrencyOrderTest is SwapChecks {
    function setUp() public {
        _deploy(false);
        _initializeAndSeed();
    }
}

contract InitializationTest is Fixture {
    function setUp() public {
        _deploy(true);
    }

    function test_factoryDeploymentAndAllocation() public {
        factory.split(token, requester, swarm);
        assertEq(token.balanceOf(requester), token.SUPPLY() * 2 / 100);
        assertEq(token.balanceOf(swarm), token.SUPPLY() * 10 / 100);
        assertEq(token.balanceOf(address(factory)), token.SUPPLY() * 88 / 100);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(pot)), 0);
        factory.initialize(key, Q96);
        assertTrue(hook.initialized());
        vm.expectRevert();
        factory.initialize(key, Q96);
    }

    function test_nonFactoryAndWrongPoolCannotInitialize() public {
        vm.expectRevert();
        manager.initialize(key, Q96);
        assertFalse(hook.initialized());
        PoolKey memory bad = key;
        bad.fee = 3000;
        vm.expectRevert();
        factory.initialize(bad, Q96);
        bad = key;
        bad.tickSpacing = 10;
        vm.expectRevert();
        factory.initialize(bad, Q96);
        assertFalse(hook.initialized());
        factory.initialize(key, Q96);
    }

    function test_swapsBeforeInitializationRefused() public {
        vm.prank(address(manager));
        vm.expectRevert(SwarmPegHook.PoolNotInitialized.selector);
        hook.beforeSwap(trader, key, SwapParams(true, -1, Q96), "");
    }

    function test_noLiquiditySwapCannotProduceUnbackedClaims() public {
        factory.initialize(key, Q96);
        imd.mint(trader, 100 ether);
        vm.prank(trader);
        imd.approve(address(router), 100 ether);
        bool zeroForOne = Currency.unwrap(key.currency0) == IMD;
        vm.prank(trader);
        vm.expectRevert();
        router.swap(
            key,
            SwapParams(zeroForOne, -100 ether, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            100 ether,
            0,
            ""
        );
        assertEq(pot.claimBalance(), 0);
        assertEq(hook.currentPulse(), 0);
    }

    function test_freshManagerTokenOnlyLiquidityBuyCanAccrueAndRedeem() public {
        // At the edge of a token-only position, the manager has zero IMD before this buy.
        bool token0 = Currency.unwrap(key.currency0) == address(token);
        int24 lower = token0 ? int24(0) : int24(-120);
        int24 upper = token0 ? int24(120) : int24(0);
        factory.initialize(key, Q96);
        factory.modify(key, lower, upper, 100_000 ether);
        assertEq(imd.balanceOf(address(manager)), 0);
        imd.mint(trader, 100 ether);
        vm.prank(trader);
        imd.approve(address(router), 100 ether);
        bool zeroForOne = !token0;
        vm.prank(trader);
        BalanceDelta delta = router.swap(
            key,
            SwapParams(zeroForOne, -100 ether, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            100 ether,
            1,
            ""
        );
        assertGt(_tokenDelta(delta), 0);
        assertEq(pot.claimBalance(), 2 ether);
        pot.redeem(2 ether);
        assertEq(imd.balanceOf(address(pot)), 2 ether);
    }
}
