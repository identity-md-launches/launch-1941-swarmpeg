// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmPeg} from "src/SwarmPeg.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract TokenFailurePathsTest is Test {
    SwarmPeg private token;
    address private alice;
    address private bob;
    address private spender;

    event GlyphBatchCreated(
        address indexed holder, uint256 indexed firstId, uint256 count, address indexed previousHolder, bytes32 seed
    );
    event GlyphBalanceChanged(address indexed holder, uint256 previousCount, uint256 newCount);

    function setUp() public {
        token = new SwarmPeg();
        alice = makeAddr("edge alice");
        bob = makeAddr("edge bob");
        spender = makeAddr("edge spender");
        token.transfer(alice, 2 ether);
    }

    function test_failedApprovedSpendRestoresAllowanceAndGlyphState() public {
        vm.prank(alice);
        token.approve(spender, 3 ether);
        uint256 id = token.glyphAt(alice, 1);
        uint256 next = token.nextGlyphId();
        uint256 issuances = token.issuanceCount();
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, alice, uint256(2 ether), uint256(3 ether)
            )
        );
        token.transferFrom(alice, bob, 3 ether);
        assertEq(token.allowance(alice, spender), 3 ether, "failed transfer consumed approval");
        assertEq(token.nextGlyphId(), next);
        assertEq(token.issuanceCount(), issuances);
        assertEq(token.glyphAt(alice, 1), id);
        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(token.balanceOf(bob), 0);
        vm.prank(spender);
        token.transferFrom(alice, bob, 2 ether);
        assertEq(token.allowance(alice, spender), 1 ether);
        uint256 received = token.glyphAt(bob, 0);
        (address holder, address previous,) = token.glyphData(received);
        assertEq(holder, bob);
        assertEq(previous, alice, "spender incorrectly recorded as previous holder");
    }

    function test_zeroReceiverFailureDoesNotSpendAllowanceEvenForZeroAmount() public {
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            vm.prank(spender);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transferFrom(alice, address(0), i);
            assertEq(token.allowance(alice, spender), type(uint256).max);
            assertEq(token.balanceOf(alice), 2 ether);
        }
    }

    function test_revokeAllowancePreventsReplayAndZeroSpenderIsInvalid() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        token.approve(spender, 1 ether);
        vm.stopPrank();
        vm.prank(spender);
        token.transferFrom(alice, bob, 0.5 ether);
        vm.prank(alice);
        token.approve(spender, 0);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, uint256(0), uint256(0.5 ether)
            )
        );
        token.transferFrom(alice, bob, 0.5 ether);
        assertEq(token.balanceOf(alice), 1.5 ether);
        assertEq(token.balanceOf(bob), 0.5 ether);
    }

    function test_oneWeiCanRetireASlotWithoutCreatingARecipientSlot() public {
        uint256 kept = token.glyphAt(alice, 0);
        uint256 retired = token.glyphAt(alice, 1);
        uint256 next = token.nextGlyphId();
        vm.expectEmit(true, false, false, true, address(token));
        emit GlyphBalanceChanged(alice, 2, 1);
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.glyphCount(alice), 1);
        assertEq(token.glyphCount(bob), 0);
        assertEq(token.nextGlyphId(), next, "fractional receipt issued a glyph");
        assertEq(token.glyphAt(alice, 0), kept);
        vm.expectRevert(abi.encodeWithSelector(SwarmPeg.GlyphNotLive.selector, retired));
        token.glyphData(retired);
        vm.prank(bob);
        token.transfer(alice, 1);
        assertEq(token.glyphAt(alice, 1), next, "regrowth resurrected a retired ID");
        vm.expectRevert(abi.encodeWithSelector(SwarmPeg.GlyphNotLive.selector, retired));
        token.glyphData(retired);
    }

    function test_firstOutOfRangeGlyphAndIssuanceIndicesRevert() public {
        vm.expectRevert(SwarmPeg.GlyphIndexOutOfBounds.selector);
        token.glyphAt(alice, 2);
        vm.expectRevert(SwarmPeg.GlyphIndexOutOfBounds.selector);
        token.glyphAt(alice, type(uint256).max);
        vm.expectRevert(SwarmPeg.GlyphIndexOutOfBounds.selector);
        token.glyphAt(bob, 0);
        uint256 count = token.issuanceCount();
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x32)));
        token.issuance(count);
    }
}
