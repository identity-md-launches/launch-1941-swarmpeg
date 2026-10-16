// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    Fixture,
    SwarmPegHook,
    SwarmPeg,
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
import {LaunchFactoryHarness} from "./helpers/LaunchFactoryHarness.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev Backed, unsolicited ERC-6909 claim donations exercise the pot's public accounting.
contract ReserveClaimDonor is IUnlockCallback {
    IPoolManager private immutable manager;
    MockIMD private immutable imd;
    address private immutable pot;

    constructor(IPoolManager manager_, MockIMD imd_, address pot_) {
        manager = manager_;
        imd = imd_;
        pot = pot_;
    }

    function donate(uint256 amount) external {
        require(imd.transferFrom(msg.sender, address(this), amount));
        manager.unlock(abi.encode(amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        uint256 amount = abi.decode(data, (uint256));
        manager.mint(pot, Currency.wrap(address(imd)).toId(), amount);
        manager.sync(Currency.wrap(address(imd)));
        require(imd.transfer(address(manager), amount));
        manager.settle();
        return "";
    }
}

contract ReserveSequenceHandler is Test {
    SwarmPegHook public immutable hook;
    MaintenancePot public immutable pot;
    SwarmPeg public immutable token;
    MockIMD public immutable imd;
    TestRouter public immutable router;
    LaunchFactoryHarness public immutable factory;
    ReserveClaimDonor public immutable donor;
    PoolKey private key;
    address[3] public actors;

    uint256 public fees;
    uint256 public donatedTokens;
    uint256 public donatedClaims;
    uint256 public redeemed;
    uint256 public trades;
    uint256 public rejectedRedemptions;
    uint256 public positionLiquidity = 1_000_000 ether;
    uint256 private pulseAtLastTrade;
    uint256 private lastTradeTime;

    constructor(SwarmPegHook hook_, TestRouter router_, LaunchFactoryHarness factory_, address[3] memory actors_) {
        hook = hook_;
        pot = hook_.maintenancePot();
        token = hook_.token();
        imd = MockIMD(hook_.IMD());
        router = router_;
        factory = factory_;
        key = hook_.poolKey();
        actors = actors_;
        donor = new ReserveClaimDonor(hook_.poolManager(), imd, address(pot));
        lastTradeTime = block.timestamp;
        for (uint256 i; i < actors.length; ++i) {
            vm.startPrank(actors[i]);
            imd.approve(address(router), type(uint256).max);
            token.approve(address(router), type(uint256).max);
            imd.approve(address(donor), type(uint256).max);
            vm.stopPrank();
        }
    }

    function trade(uint256 actorRaw, uint256 raw, bool buy, bool exactInput) external {
        _trade(actors[actorRaw % 3], bound(raw, 1000, 10 ether), buy, exactInput);
    }

    function roundTrip(uint256 actorRaw, uint256 raw) external {
        address actor = actors[actorRaw % 3];
        uint256 beforeIMD = imd.balanceOf(actor);
        uint256 beforeTokens = token.balanceOf(actor);
        BalanceDelta bought = _trade(actor, bound(raw, 1 ether, 10 ether), true, true);
        int128 tokenDelta = Currency.unwrap(key.currency0) == address(token) ? bought.amount0() : bought.amount1();
        _trade(actor, uint256(int256(tokenDelta)), false, true);
        assertEq(token.balanceOf(actor), beforeTokens, "round trip changed token principal");
        assertLt(imd.balanceOf(actor), beforeIMD, "round trip created free IMD");
    }

    function donate(uint256 actorRaw, uint256 raw, bool claims) external {
        address actor = actors[actorRaw % 3];
        uint256 amount = bound(raw, 0, 5 ether);
        vm.prank(actor);
        if (claims) {
            donor.donate(amount);
            donatedClaims += amount;
        } else {
            imd.transfer(address(pot), amount);
            donatedTokens += amount;
        }
    }

    function redeem(uint256 actorRaw, uint256 raw, bool all) public {
        uint256 available = fees + donatedClaims - redeemed;
        if (available == 0) {
            vm.expectRevert(MaintenancePot.InvalidAmount.selector);
            pot.redeem(1);
            ++rejectedRedemptions;
            return;
        }
        uint256 amount = all ? available : bound(raw, 1, available);
        address actor = actors[actorRaw % 3];
        uint256 beforeBalance = imd.balanceOf(actor);
        vm.prank(actor);
        pot.redeem(amount);
        redeemed += amount;
        assertEq(imd.balanceOf(actor), beforeBalance, "redemption paid its caller");
    }

    function rejectRedemption(uint256 raw, bool excess) external {
        uint256 claims = fees + donatedClaims - redeemed;
        uint256 amount = excess ? claims + bound(raw, 1, 1 ether) : 0;
        bytes32 beforeState = _financialState();
        vm.expectRevert(MaintenancePot.InvalidAmount.selector);
        pot.redeem(amount);
        assertEq(_financialState(), beforeState, "invalid redemption changed state");
        ++rejectedRedemptions;
    }

    function failedTransferThenRetry(uint256 raw) external {
        uint256 available = fees + donatedClaims - redeemed;
        if (available == 0) return;
        uint256 amount = bound(raw, 1, available);
        bytes32 beforeState = _financialState();
        imd.setRejectTransfers(true);
        vm.expectRevert(); // v4 wraps the token's failure in its transfer error.
        pot.redeem(amount);
        imd.setRejectTransfers(false);
        assertEq(_financialState(), beforeState, "failed transfer burned claims or retained the lock");
        ++rejectedRedemptions;
        pot.redeem(amount);
        redeemed += amount;
    }

    function advance(uint256 raw, bool checkpoint) external {
        vm.warp(vm.getBlockTimestamp() + bound(raw, 0, 7200));
        vm.roll(vm.getBlockNumber() + 1);
        if (checkpoint) {
            uint256 expected = expectedPulse();
            assertEq(hook.checkpointPulse(), expected);
            assertEq(hook.checkpointPulse(), expected, "checkpoint is not idempotent");
        }
    }

    function liquidity(uint256 raw, uint8 operation) external {
        bytes32 beforeState = _financialState();
        int256 change;
        if (operation % 3 == 0) {
            change = int256(bound(raw, 1, 1000 ether));
            positionLiquidity += uint256(change);
        } else if (operation % 3 == 1) {
            change = -int256(bound(raw, 1, 1000 ether));
            positionLiquidity -= uint256(-change);
        }
        vm.prank(factory.controller());
        (BalanceDelta delta,) = factory.modify(key, -887220, 887220, change);
        if (change == 0) {
            assertGe(delta.amount0(), 0, "factory's fee collect was charged");
            assertGe(delta.amount1(), 0, "factory's fee collect was charged");
        }
        assertEq(_financialState(), beforeState, "liquidity action changed hook fees or pulse");
    }

    function expectedPulse() public view returns (uint256) {
        uint256 elapsed = (block.timestamp - lastTradeTime) / 60;
        return elapsed >= pulseAtLastTrade ? 0 : pulseAtLastTrade - elapsed;
    }

    function _trade(address actor, uint256 amount, bool buy, bool exactInput) private returns (BalanceDelta delta) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        uint256 beforeIMD = imd.balanceOf(actor);
        uint256 beforeToken = token.balanceOf(actor);
        vm.recordLogs();
        vm.prank(actor);
        delta = router.swap(
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
        Vm.Log[] memory logs = vm.getRecordedLogs();
        int128 coreIMD;
        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook.poolManager())
                    && logs[i].topics[0]
                        == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
            ) {
                (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                coreIMD = Currency.unwrap(key.currency0) == address(imd) ? a0 : a1;
                ++swaps;
            }
        }
        assertEq(swaps, 1, "missing pool execution evidence");
        int128 imdDelta = Currency.unwrap(key.currency0) == address(imd) ? delta.amount0() : delta.amount1();
        int128 tokenDelta = Currency.unwrap(key.currency0) == address(token) ? delta.amount0() : delta.amount1();
        int256 charged = int256(coreIMD) - int256(imdDelta);
        assertGe(charged, 0);
        uint256 gross = buy ? uint256(-int256(imdDelta)) : uint256(int256(coreIMD));
        assertEq(uint256(charged), gross * 2 / 100, "wrong tax on independently observed IMD leg");
        assertEq(int256(imd.balanceOf(actor)) - int256(beforeIMD), imdDelta);
        assertEq(int256(token.balanceOf(actor)) - int256(beforeToken), tokenDelta);
        assertTrue(imdDelta != 0 && tokenDelta != 0, "bounded trade did not execute");
        fees += uint256(charged);
        ++trades;
        pulseAtLastTrade = expectedPulse() + 25;
        if (pulseAtLastTrade > 1000) pulseAtLastTrade = 1000;
        lastTradeTime = block.timestamp;
    }

    function _financialState() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                hook.totalFees(),
                hook.tradeCount(),
                hook.tradeEntropy(),
                hook.storedPulse(),
                hook.pulseUpdatedAt(),
                pot.claimBalance(),
                pot.reserveBalance(),
                pot.totalRedeemed()
            )
        );
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract ReserveSequenceInvariantTest is Fixture {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    ReserveSequenceHandler private handler;
    uint256 private initialIMD;

    function setUp() public {
        _deploy(true);
        _initializeAndSeed();
        imd.mint(address(factory), 1_000_000 ether);
        address[3] memory actors = [trader, makeAddr("second reserve trader"), makeAddr("third reserve trader")];
        for (uint256 i = 1; i < actors.length; ++i) {
            imd.mint(actors[i], 1_000_000 ether);
            factory.send(token, actors[i], 1_000_000 ether);
        }
        initialIMD = imd.totalSupply();
        handler = new ReserveSequenceHandler(hook, router, factory, actors);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.roundTrip.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.rejectRedemption.selector;
        selectors[5] = handler.failedTransferThenRetry.selector;
        selectors[6] = handler.advance.selector;
        selectors[7] = handler.liquidity.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        // Every campaign starts with a backed claim, so even an immediate redeem exercises value.
        handler.trade(0, 1 ether, true, true);
    }

    function invariant_reserveSupplySettlementAndPulse() public view {
        uint256 claims = handler.fees() + handler.donatedClaims() - handler.redeemed();
        assertEq(pot.claimBalance(), claims);
        assertEq(pot.totalRedeemed(), handler.redeemed());
        assertEq(imd.balanceOf(address(pot)), handler.redeemed() + handler.donatedTokens());
        assertEq(pot.reserveBalance(), handler.fees() + handler.donatedTokens() + handler.donatedClaims());
        assertEq(hook.totalFees(), handler.fees());
        assertEq(hook.tradeCount(), handler.trades());
        assertEq(hook.currentPulse(), handler.expectedPulse());
        assertLe(hook.currentPulse(), 1000);
        assertGe(imd.balanceOf(address(manager)), claims, "claims lack backing");

        IPoolManager pm = IPoolManager(address(manager));
        assertFalse(pm.isUnlocked());
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(address(token))), 0);
        assertEq(pm.balanceOf(address(hook), Currency.wrap(IMD).toId()), 0);
        assertEq(pm.getLiquidity(key.toId()), handler.positionLiquidity());

        uint256 sumIMD = imd.balanceOf(address(manager)) + imd.balanceOf(address(factory)) + imd.balanceOf(address(pot));
        uint256 sumToken = token.balanceOf(address(manager)) + token.balanceOf(address(factory));
        for (uint256 i; i < 3; ++i) {
            sumIMD += imd.balanceOf(handler.actors(i));
            sumToken += token.balanceOf(handler.actors(i));
        }
        assertEq(sumIMD, initialIMD, "IMD escaped the closed actor set");
        assertEq(sumToken, 1_000_000_000 ether, "SWARMPEG supply changed or escaped");
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        address[4] memory empty = [address(router), address(hook), address(handler), address(handler.donor())];
        for (uint256 i; i < empty.length; ++i) {
            assertEq(imd.balanceOf(empty[i]), 0, "intermediary retained IMD");
            assertEq(token.balanceOf(empty[i]), 0, "intermediary retained SWARMPEG");
        }
    }

    function afterInvariant() public {
        handler.redeem(1, 0, true);
        assertEq(pot.claimBalance(), 0, "reserve cannot fully redeem after a random sequence");
        invariant_reserveSupplySettlementAndPulse();
    }

    function test_donationsFailuresAndFullRedemptionAfterLiquidityChanges() public {
        handler.donate(1, 1 ether, false);
        handler.donate(2, 2 ether, true);
        handler.advance(61, true);
        handler.roundTrip(2, 3 ether);
        handler.liquidity(10 ether, 0);
        handler.liquidity(10 ether, 1);
        handler.liquidity(0, 2);
        handler.rejectRedemption(1, true);
        handler.failedTransferThenRetry(1);
        handler.redeem(2, 0, true);
        invariant_reserveSupplySettlementAndPulse();
        assertEq(pot.claimBalance(), 0);
        assertEq(handler.rejectedRedemptions(), 2);
    }
}
