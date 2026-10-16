// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Fixture,
    SwarmPegHook,
    MaintenancePot,
    IPoolManager,
    PoolKey,
    Currency,
    SwapParams,
    BalanceDelta,
    TickMath
} from "./helpers/Fixture.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

contract NestedRedemptionProbe is IUnlockCallback {
    IPoolManager private immutable manager;
    MaintenancePot private immutable pot;

    constructor(IPoolManager manager_, MaintenancePot pot_) {
        manager = manager_;
        pot = pot_;
    }

    function attempt(uint256 amount) external {
        manager.unlock(abi.encode(amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        pot.redeem(abi.decode(data, (uint256)));
        return "";
    }
}

contract HookFailurePathsTest is Fixture {
    using StateLibrary for IPoolManager;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    function setUp() public {
        _deploy(true);
        _initializeAndSeed();
    }

    function test_eachPoolKeyFieldIsBoundForBothSwapCallbacks() public {
        for (uint256 i; i < 6; ++i) {
            PoolKey memory wrong = hook.poolKey();
            if (i == 0) wrong.currency0 = Currency.wrap(address(0));
            if (i == 1) wrong.currency1 = Currency.wrap(address(0));
            if (i == 2) wrong.fee = 0x800000;
            if (i == 3) wrong.tickSpacing = 1;
            if (i == 4) wrong.hooks = IHooks(address(this));
            if (i == 5) (wrong.currency0, wrong.currency1) = (wrong.currency1, wrong.currency0);
            SwapParams memory params = _params(true, -100);
            vm.prank(address(manager));
            vm.expectRevert(SwarmPegHook.InvalidPool.selector);
            hook.beforeSwap(trader, wrong, params, "");
            vm.prank(address(manager));
            vm.expectRevert(SwarmPegHook.InvalidPool.selector);
            hook.afterSwap(trader, wrong, params, BalanceDelta.wrap(0), "");
        }
    }

    function test_signedAmountBoundariesAreRejectedInBothCallbacks() public {
        int256[5] memory invalid = [
            int256(0), type(int256).min, type(int256).max, int256(type(int128).max) + 1, -int256(type(int128).max) - 1
        ];
        for (uint256 i; i < invalid.length; ++i) {
            SwapParams memory params = _params(true, invalid[i]);
            vm.prank(address(manager));
            vm.expectRevert(SwarmPegHook.InvalidSwapAmount.selector);
            hook.beforeSwap(trader, key, params, "");
            vm.prank(address(manager));
            vm.expectRevert(SwarmPegHook.InvalidSwapAmount.selector);
            hook.afterSwap(trader, key, params, BalanceDelta.wrap(0), "");
        }
    }

    function test_exactOutputGrossUpCannotOverflowInt128() public {
        SwapParams memory sell = _params(false, int256(type(int128).max));
        vm.prank(address(manager));
        vm.expectRevert(SwarmPegHook.InvalidSwapAmount.selector);
        hook.beforeSwap(trader, key, sell, "");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_beforeSwapCannotConsumeWholeInput(uint256 raw) public {
        uint256 amount = bound(raw, 1, uint256(uint128(type(int128).max)) / 2);
        SwapParams memory params = _params(true, -int256(amount));
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 overrideFee) = hook.beforeSwap(trader, key, params, "");
        assertEq(selector, IHooks.beforeSwap.selector);
        int128 fee = delta.getSpecifiedDelta();
        assertGe(fee, 0);
        assertLt(uint256(uint128(fee)), amount, "NoOp: entire input consumed by hook");
        assertEq(uint256(uint128(fee)), amount * 200 / 10_000);
        assertEq(delta.getUnspecifiedDelta(), 0);
        assertEq(overrideFee, 0, "unexpected LP fee override");
    }

    function test_wrongSignedDeltasRefusedBeforeAccruingFees() public {
        bytes32 beforeState = _state();
        for (uint256 i; i < 4; ++i) {
            bool buy = i < 2;
            int128 imdDelta = buy ? int128(-100) : int128(100);
            int128 tokenDelta = buy ? int128(100) : int128(-100);
            if (i % 2 == 0) imdDelta = -imdDelta;
            else tokenDelta = -tokenDelta;
            BalanceDelta delta = Currency.unwrap(key.currency0) == IMD
                ? toBalanceDelta(imdDelta, tokenDelta)
                : toBalanceDelta(tokenDelta, imdDelta);
            SwapParams memory params = _params(buy, -100);
            vm.prank(address(manager));
            vm.expectRevert(SwarmPegHook.InvalidSwapDelta.selector);
            hook.afterSwap(trader, key, params, delta, "");
        }
        assertEq(_state(), beforeState);
    }

    function test_partialSpecifiedTradesBubbleExactReasonAndRollBackEverything() public {
        _swap(true, true, 100 ether); // failure must preserve an already-live state too.
        for (uint256 i; i < 2; ++i) {
            bool buy = i == 0;
            (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
            SwapParams memory params = _params(buy, buy ? -int256(1000 ether) : int256(1000 ether));
            params.sqrtPriceLimitX96 = params.zeroForOne ? price - 1 : price + 1;
            bytes32 beforeState = _state();
            vm.prank(trader);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.afterSwap.selector,
                    abi.encodeWithSelector(SwarmPegHook.PartialFillUnsupported.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            router.swap(key, params, 4000 ether, 0, "");
            assertEq(_state(), beforeState, "partial fill leaked state");
        }
        _swap(false, true, 1 ether);
        assertEq(hook.tradeCount(), 2, "failed swaps counted as trades");
    }

    function test_settlementFailureRollsBackClaimsEntropyAndGlyphIssuances() public {
        bytes32 beforeState = _state();
        SwapParams memory params = _params(true, -int256(100 ether));
        vm.prank(trader);
        vm.expectRevert(); // router has one wei but the manager needs the executed input.
        router.swap(key, params, 1, 0, "");
        assertEq(_state(), beforeState);
        _swap(true, true, 100 ether);
        assertEq(pot.claimBalance(), 2 ether, "failed swap leaked a claim");
    }

    function test_nestedUnlockCannotLeavePotRedemptionActive() public {
        _swap(true, true, 100 ether);
        NestedRedemptionProbe probe = new NestedRedemptionProbe(manager, pot);
        bytes32 beforeState = _state();
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        probe.attempt(1 ether);
        assertEq(_state(), beforeState);
        vm.prank(address(manager));
        vm.expectRevert(MaintenancePot.RedemptionNotActive.selector);
        pot.unlockCallback(abi.encode(1 ether));
        pot.redeem(2 ether);
        assertEq(pot.claimBalance(), 0);
        assertEq(imd.balanceOf(address(pot)), 2 ether);
    }

    function _params(bool buy, int256 amount) private view returns (SwapParams memory) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == IMD);
        return SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _state() private view returns (bytes32) {
        IPoolManager pm = IPoolManager(address(manager));
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = pm.getFeeGrowthGlobals(key.toId());
        bytes32 poolState = keccak256(abi.encode(price, tick, protocolFee, lpFee, growth0, growth1));
        bytes32 hookState = keccak256(
            abi.encode(
                hook.totalFees(),
                hook.tradeCount(),
                hook.tradeEntropy(),
                hook.storedPulse(),
                hook.pulseUpdatedAt(),
                pot.claimBalance(),
                pot.totalRedeemed(),
                pot.reserveBalance()
            )
        );
        bytes32 balances = keccak256(
            abi.encode(
                imd.balanceOf(trader),
                token.balanceOf(trader),
                imd.balanceOf(address(manager)),
                token.balanceOf(address(manager)),
                imd.balanceOf(address(router)),
                token.balanceOf(address(router)),
                token.nextGlyphId(),
                token.issuanceCount()
            )
        );
        return keccak256(abi.encode(poolState, hookState, balances));
    }
}
