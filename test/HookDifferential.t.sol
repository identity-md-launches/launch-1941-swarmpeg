// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, BalanceDelta, SwapParams, TickMath, Currency, IPoolManager, PoolKey} from "./helpers/Fixture.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev The oracle is a second real v4 pool with identical price, liquidity and LP fee, without a hook.
/// Comparing execution isolates the hook's tax from AMM price impact and LP fees.
abstract contract DifferentialChecks is Fixture {
    using StateLibrary for IPoolManager;
    PoolKey private referenceKey;

    function _setupDifferential(bool below) internal {
        _deploy(below);
        _initializeAndSeed();
        referenceKey = key;
        referenceKey.hooks = IHooks(address(0));
        factory.initialize(referenceKey, Q96);
        imd.mint(address(factory), 1_000_000 ether);
        factory.modify(referenceKey, -887220, 887220, 1_000_000 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_swapMatchesUnhookedExecution(uint256 raw, bool buy, bool exactInput) public {
        _compare(buy, exactInput, bound(raw, 1, 10_000 ether));
    }

    function test_fourModesRemainEquivalentAcrossChangingPrices() public {
        _compare(true, true, 2000 ether);
        _compare(false, false, 100 ether);
        _compare(false, true, 800 ether);
        _compare(true, false, 13 ether);
        _compare(true, true, 50);
        _compare(false, false, 49);
    }

    function test_roundingBoundariesInEveryMode() public {
        uint256[9] memory amounts = [uint256(1), 2, 48, 49, 50, 51, 97, 98, 99];
        for (uint256 i; i < amounts.length; ++i) {
            _compare(true, true, amounts[i]);
            _compare(true, false, amounts[i]);
            _compare(false, true, amounts[i]);
            _compare(false, false, amounts[i]);
        }
    }

    function _compare(bool buy, bool exactInput, uint256 amount) private {
        uint256 referenceAmount = amount;
        if (buy && exactInput) referenceAmount -= amount * 2 / 100;
        if (!buy && !exactInput) referenceAmount += amount * 2 / 98;
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == IMD);
        vm.prank(trader);
        BalanceDelta referenceDelta = router.swap(
            referenceKey,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(referenceAmount) : int256(referenceAmount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            amount * 4 + 100,
            0,
            ""
        );
        uint256 oldIMD = imd.balanceOf(trader);
        uint256 oldTokens = token.balanceOf(trader);
        uint256 oldFees = hook.totalFees();
        uint256 oldClaims = pot.claimBalance();
        uint256 oldTrades = hook.tradeCount();
        bytes32 oldEntropy = hook.tradeEntropy();
        vm.recordLogs();
        BalanceDelta actual = _swap(buy, exactInput, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Fee is the difference between independently executed pool deltas, not the hook's counter.
        int256 paid = int256(_imdDelta(referenceDelta)) - int256(_imdDelta(actual));
        assertGe(paid, 0, "hook must never subsidize a trade");
        uint256 fee = uint256(paid);
        uint256 gross = buy ? uint256(-int256(_imdDelta(actual))) : uint256(int256(_imdDelta(referenceDelta)));
        assertEq(fee, gross * 200 / 10_000, "fee must be 2% of gross IMD");
        assertEq(_tokenDelta(actual), _tokenDelta(referenceDelta), "hook taxed the launch token");
        assertEq(int256(imd.balanceOf(trader)) - int256(oldIMD), _imdDelta(actual));
        assertEq(int256(token.balanceOf(trader)) - int256(oldTokens), _tokenDelta(actual));
        assertEq(pot.claimBalance() - oldClaims, fee, "pot did not receive the entire fee");
        assertEq(hook.totalFees() - oldFees, fee, "fee counter disagrees with execution");

        bool traded = _imdDelta(referenceDelta) != 0 && _tokenDelta(referenceDelta) != 0;
        assertEq(hook.tradeCount(), oldTrades + (traded ? 1 : 0));
        if (traded) assertNotEq(hook.tradeEntropy(), oldEntropy);
        else assertEq(hook.tradeEntropy(), oldEntropy);
        if (exactInput) {
            assertEq(-int256(buy ? _imdDelta(actual) : _tokenDelta(actual)), int256(amount));
        } else {
            assertEq(int256(buy ? _tokenDelta(actual) : _imdDelta(actual)), int256(amount));
        }
        _assertEquivalentPoolState();
        _assertFeeAndTradeEvents(logs, buy, gross, fee, referenceDelta, traded);
    }

    function _assertEquivalentPoolState() private view {
        IPoolManager pm = IPoolManager(address(manager));
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(key.toId());
        (uint160 refPrice, int24 refTick, uint24 refProtocolFee, uint24 refLPFee) = pm.getSlot0(referenceKey.toId());
        assertEq(price, refPrice, "hook changed core execution price");
        assertEq(tick, refTick);
        assertEq(protocolFee, refProtocolFee);
        assertEq(lpFee, refLPFee);
        (uint256 growth0, uint256 growth1) = pm.getFeeGrowthGlobals(key.toId());
        (uint256 refGrowth0, uint256 refGrowth1) = pm.getFeeGrowthGlobals(referenceKey.toId());
        assertEq(growth0, refGrowth0, "LP fees changed");
        assertEq(growth1, refGrowth1, "LP fees changed");
        assertEq(pm.getLiquidity(key.toId()), pm.getLiquidity(referenceKey.toId()));
    }

    function _assertFeeAndTradeEvents(
        Vm.Log[] memory logs,
        bool buy,
        uint256 gross,
        uint256 fee,
        BalanceDelta core,
        bool traded
    ) private view {
        uint256 feeEvents;
        uint256 tradeEvents;
        uint256 pulseEvents;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(hook)) continue;
            if (entry.topics[0] == keccak256("FeeAccrued(uint256,bool,uint256,uint256)")) {
                ++feeEvents;
                assertEq(uint256(entry.topics[1]), hook.tradeCount());
                assertEq(uint256(entry.topics[2]), buy ? 1 : 0);
                (uint256 eventGross, uint256 eventFee) = abi.decode(entry.data, (uint256, uint256));
                assertEq(eventGross, gross);
                assertEq(eventFee, fee);
            } else if (entry.topics[0] == keccak256("TradeRecorded(uint256,address,bytes32,int128,int128)")) {
                ++tradeEvents;
                assertEq(uint256(entry.topics[1]), hook.tradeCount());
                assertEq(address(uint160(uint256(entry.topics[2]))), address(router));
                (bytes32 entropy, int128 imdDelta, int128 tokenDelta) =
                    abi.decode(entry.data, (bytes32, int128, int128));
                assertEq(entropy, hook.tradeEntropy());
                assertEq(imdDelta, _imdDelta(core));
                assertEq(tokenDelta, _tokenDelta(core));
            } else if (entry.topics[0] == keccak256("PulseUpdated(uint256,uint256,uint256)")) {
                ++pulseEvents;
                assertEq(uint256(entry.topics[1]), hook.tradeCount());
                (uint256 pulse, uint256 timestamp) = abi.decode(entry.data, (uint256, uint256));
                assertEq(pulse, hook.currentPulse());
                assertEq(timestamp, block.timestamp);
            }
        }
        assertEq(feeEvents, 1, "missing or duplicate fee event");
        assertEq(tradeEvents, traded ? 1 : 0, "trade event count");
        assertEq(pulseEvents, traded ? 1 : 0, "pulse event count");
    }
}

/// forge-config: default.fuzz.runs = 1000
contract HookDifferentialTokenBelowTest is DifferentialChecks {
    function setUp() public {
        _setupDifferential(true);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract HookDifferentialTokenAboveTest is DifferentialChecks {
    function setUp() public {
        _setupDifferential(false);
    }
}
