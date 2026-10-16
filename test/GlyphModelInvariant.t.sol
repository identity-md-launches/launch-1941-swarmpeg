// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmPeg} from "src/SwarmPeg.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev A small, explicit stack per holder is the oracle for the production lazy batches.
/// Balances, allowances and the next ID are updated from inputs, never copied back from the token.
contract GlyphModelHandler is Test {
    SwarmPeg public immutable token;
    address[4] public actors;
    uint256[4] public balances;
    uint256[4][4] public allowances;
    uint256[][4] private slots;
    mapping(uint256 => address) private previousHolders;
    mapping(uint256 => bytes32) private birthSeeds;
    uint256[16] private retiredSamples;
    uint256 public retirementCount;
    uint256 public nextId;
    uint256 public successfulTransfers;
    uint256 public rejectedTransfers;
    uint256 public immutable reserve;

    constructor() {
        token = new SwarmPeg();
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("model actor ", vm.toString(i)));
            balances[i] = 3 ether;
            token.transfer(actors[i], balances[i]);
            for (uint256 j; j < 3; ++j) {
                uint256 id = token.glyphAt(actors[i], j);
                slots[i].push(id);
                previousHolders[id] = address(this);
                (,, birthSeeds[id]) = token.glyphData(id);
            }
        }
        reserve = token.SUPPLY() - 12 ether;
        nextId = token.nextGlyphId();
    }

    function transfer(uint256 fromRaw, uint256 toRaw, uint256 raw) external {
        uint256 from = fromRaw % 4;
        uint256 to = toRaw % 4;
        uint256 amount = bound(raw, 0, balances[from]);
        vm.prank(actors[from]);
        assertTrue(token.transfer(actors[to], amount));
        _move(from, to, amount);
    }

    function emptyHolder(uint256 fromRaw, uint256 toRaw) external {
        uint256 from = fromRaw % 4;
        uint256 to = (from + 1 + toRaw % 3) % 4;
        uint256 amount = balances[from];
        vm.prank(actors[from]);
        token.transfer(actors[to], amount);
        _move(from, to, amount);
        assertEq(token.batchCount(actors[from]), 0, "empty holder retains batches");
    }

    function approve(uint256 ownerRaw, uint256 spenderRaw, uint256 raw, bool unlimited) external {
        uint256 owner = ownerRaw % 4;
        uint256 spender = spenderRaw % 4;
        uint256 amount = unlimited ? type(uint256).max : bound(raw, 0, 12 ether);
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        allowances[owner][spender] = amount;
    }

    function transferFrom(uint256 fromRaw, uint256 toRaw, uint256 spenderRaw, uint256 raw) external {
        uint256 from = fromRaw % 4;
        uint256 to = toRaw % 4;
        uint256 spender = spenderRaw % 4;
        uint256 allowed = allowances[from][spender];
        uint256 limit = balances[from] < allowed ? balances[from] : allowed;
        uint256 amount = bound(raw, 0, limit);
        vm.prank(actors[spender]);
        assertTrue(token.transferFrom(actors[from], actors[to], amount));
        if (allowed != type(uint256).max) allowances[from][spender] -= amount;
        _move(from, to, amount);
    }

    function rejectOverdraft(uint256 fromRaw, uint256 toRaw) external {
        uint256 from = fromRaw % 4;
        uint256 to = toRaw % 4;
        uint256 amount = balances[from] + 1;
        uint256 issuanceCount = token.issuanceCount();
        vm.prank(actors[from]);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, actors[from], balances[from], amount)
        );
        token.transfer(actors[to], amount);
        assertEq(token.issuanceCount(), issuanceCount, "failed transfer issued art");
        ++rejectedTransfers;
    }

    function rejectZeroRecipient(uint256 fromRaw, uint256 raw) external {
        uint256 from = fromRaw % 4;
        uint256 amount = bound(raw, 0, balances[from]);
        vm.prank(actors[from]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        ++rejectedTransfers;
    }

    function rejectUnapprovedSpend(uint256 fromRaw, uint256 spenderRaw) external {
        uint256 from = fromRaw % 4;
        uint256 spender = spenderRaw % 4;
        vm.prank(actors[from]);
        token.approve(actors[spender], 0);
        allowances[from][spender] = 0;
        vm.prank(actors[spender]);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, actors[spender], uint256(0), uint256(1)
            )
        );
        token.transferFrom(actors[from], actors[(from + 1) % 4], 1);
        ++rejectedTransfers;
    }

    function _move(uint256 from, uint256 to, uint256 amount) private {
        ++successfulTransfers;
        if (from == to || amount == 0) return;
        balances[from] -= amount;
        balances[to] += amount;
        while (slots[from].length > balances[from] / 1 ether) {
            uint256 retired = slots[from][slots[from].length - 1];
            slots[from].pop();
            retiredSamples[retirementCount++ % retiredSamples.length] = retired;
            _assertRetired(retired);
        }
        while (slots[to].length < balances[to] / 1 ether) {
            uint256 id = nextId++;
            slots[to].push(id);
            previousHolders[id] = actors[from];
            (address holder, address previous, bytes32 seed) = token.glyphData(id);
            assertEq(holder, actors[to]);
            assertEq(previous, actors[from]);
            assertNotEq(seed, bytes32(0));
            birthSeeds[id] = seed;
        }
    }

    function assertModel() external view {
        uint256 total = reserve;
        assertEq(token.balanceOf(address(this)), reserve);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.nextGlyphId(), nextId, "IDs skipped or reused");
        assertEq(token.balanceOf(address(0)), 0);
        for (uint256 i; i < 4; ++i) {
            total += balances[i];
            assertEq(token.balanceOf(actors[i]), balances[i], "balance differs from transfer model");
            assertEq(token.glyphCount(actors[i]), slots[i].length, "whole balance mirror");
            for (uint256 j; j < slots[i].length; ++j) {
                uint256 id = slots[i][j];
                assertEq(token.glyphAt(actors[i], j), id, "LIFO slot identity");
                (address holder, address previous, bytes32 seed) = token.glyphData(id);
                assertEq(holder, actors[i]);
                assertEq(previous, previousHolders[id]);
                assertEq(seed, birthSeeds[id], "surviving glyph birth seed changed");
            }
            for (uint256 j; j < 4; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), allowances[i][j], "allowance model");
            }
        }
        assertEq(total, token.totalSupply(), "closed actor set conserves supply");
        for (uint256 i; i < retiredSamples.length; ++i) {
            if (retiredSamples[i] != 0) _assertRetired(retiredSamples[i]);
        }
    }

    function _assertRetired(uint256 id) private view {
        (bool ok, bytes memory reason) = address(token).staticcall(abi.encodeCall(token.glyphOwner, (id)));
        assertFalse(ok, "retired ID became live again");
        assertEq(reason, abi.encodeWithSelector(SwarmPeg.GlyphNotLive.selector, id));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract GlyphModelInvariantTest is Test {
    GlyphModelHandler private handler;

    function setUp() public {
        handler = new GlyphModelHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.emptyHolder.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.transferFrom.selector;
        selectors[4] = handler.rejectOverdraft.selector;
        selectors[5] = handler.rejectZeroRecipient.selector;
        selectors[6] = handler.rejectUnapprovedSpend.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_balancesAllowancesAndGlyphHistoryMatchModel() public view {
        handler.assertModel();
    }

    function test_fragmentDrainRefillAndDelegatedSelfTransfer() public {
        handler.transfer(0, 1, 1 ether - 1);
        handler.transfer(0, 1, 1);
        handler.transfer(1, 0, 1 ether + 1);
        handler.emptyHolder(0, 1);
        handler.transfer(1, 0, 2 ether);
        handler.approve(0, 2, 2 ether, false);
        handler.transferFrom(0, 0, 2, 1 ether);
        handler.approve(1, 3, 0, true);
        handler.transferFrom(1, 0, 3, 1 ether);
        handler.rejectOverdraft(0, 1);
        handler.rejectUnapprovedSpend(1, 3);
        handler.assertModel();
        assertGt(handler.retirementCount(), 0);
        assertEq(handler.rejectedTransfers(), 2);
    }
}
