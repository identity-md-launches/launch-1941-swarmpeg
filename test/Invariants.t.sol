// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {
    Fixture,
    SwarmPeg,
    SwarmPegHook,
    MaintenancePot,
    IPoolManager,
    PoolKey,
    Currency,
    SwapParams,
    TickMath,
    BalanceDelta
} from "./helpers/Fixture.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract BalanceHandler is Test {
    SwarmPeg public immutable token;
    address[6] public actors;

    constructor(SwarmPeg token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("holder", bytes1(uint8(i)))));
        }
    }

    function move(uint256 fromRaw, uint256 toRaw, uint256 amountRaw) external {
        address from = actors[fromRaw % actors.length];
        address to = actors[toRaw % actors.length];
        uint256 amount = bound(amountRaw, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }
}

contract GlyphInvariantTest is StdInvariant, Test {
    SwarmPeg token;
    BalanceHandler handler;

    function setUp() public {
        token = new SwarmPeg();
        handler = new BalanceHandler(token);
        for (uint256 i; i < 6; ++i) {
            token.transfer(handler.actors(i), 10 ether);
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.move.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_supplyAndWholeBalanceOwnership() public view {
        uint256 total = token.balanceOf(address(this));
        uint256 glyphs = token.glyphCount(address(this));
        for (uint256 i; i < 6; ++i) {
            address actor = handler.actors(i);
            uint256 count = token.glyphCount(actor);
            uint256 balance = token.balanceOf(actor);
            total += balance;
            glyphs += count;
            assertEq(count, balance / 1 ether);
            uint256 previousId;
            for (uint256 j; j < count; ++j) {
                uint256 id = token.glyphAt(actor, j);
                assertGt(id, previousId);
                assertEq(token.glyphOwner(id), actor);
                previousId = id;
            }
        }
        assertEq(total, token.SUPPLY());
        assertEq(token.totalSupply(), token.SUPPLY());
        assertLe(glyphs, 1_000_000_000);
    }
}

contract SwapHandler is Test {
    SwarmPegHook public immutable hook;
    MaintenancePot public immutable pot;
    TestRouter public immutable router;
    MockIMD public immutable imd;
    address public immutable trader;
    PoolKey private key;
    uint256 public expectedFees;
    uint256 public successfulTrades;

    constructor(SwarmPegHook hook_, TestRouter router_, address trader_) {
        hook = hook_;
        pot = hook_.maintenancePot();
        router = router_;
        key = hook_.poolKey();
        imd = MockIMD(hook_.IMD());
        trader = trader_;
    }

    function trade(uint64 raw, bool buy, bool exactInput) external {
        uint256 amount = bound(uint256(raw), 1000, 10 ether);
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        uint256 beforeFees = hook.totalFees();
        vm.prank(trader);
        BalanceDelta delta = router.swap(
            key,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            amount * 4 + 100,
            0,
            ""
        );
        int128 imdDelta = Currency.unwrap(key.currency0) == address(imd) ? delta.amount0() : delta.amount1();
        uint256 fee = hook.totalFees() - beforeFees;
        uint256 gross = buy ? uint256(-int256(imdDelta)) : uint256(int256(imdDelta)) + fee;
        assertEq(fee, gross / 50);
        expectedFees += gross / 50;
        ++successfulTrades;
    }

    function redeem(uint256 raw) external {
        uint256 claims = pot.claimBalance();
        if (claims != 0) pot.redeem(bound(raw, 1, claims));
    }

    function advance(uint32 secondsRaw) external {
        vm.warp(block.timestamp + bound(uint256(secondsRaw), 0, 3600));
        hook.checkpointPulse();
    }
}

contract AccountingInvariantTest is Fixture {
    using TransientStateLibrary for IPoolManager;
    SwapHandler handler;
    uint256 initialIMD;

    function setUp() public {
        _deploy(true);
        _initializeAndSeed();
        initialIMD = imd.totalSupply();
        handler = new SwapHandler(hook, router, trader);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_feesConservedAndManagerSettled() public view {
        assertEq(hook.totalFees(), handler.expectedFees());
        assertEq(pot.reserveBalance(), handler.expectedFees());
        assertEq(pot.totalRedeemed() + pot.claimBalance(), hook.totalFees());
        assertEq(hook.tradeCount(), handler.successfulTrades());
        assertLe(hook.currentPulse(), hook.MAX_PULSE());
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0);
        assertFalse(IPoolManager(address(manager)).isUnlocked());
        assertEq(
            imd.balanceOf(address(manager)) + imd.balanceOf(address(factory)) + imd.balanceOf(trader)
                + imd.balanceOf(address(pot)),
            initialIMD
        );
        assertEq(
            token.balanceOf(address(manager)) + token.balanceOf(address(factory)) + token.balanceOf(trader),
            token.SUPPLY()
        );
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
    }
}
