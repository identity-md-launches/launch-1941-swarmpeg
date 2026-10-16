// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmPeg} from "../src/SwarmPeg.sol";

contract SwarmPegTest is Test {
    SwarmPeg token;
    address alice;
    address bob;
    address spender;

    function setUp() public {
        token = new SwarmPeg();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
    }

    function test_fixedSupplySingleMintAndMetadata() public view {
        assertEq(token.name(), "SwarmPeg");
        assertEq(token.symbol(), "SWARMPEG");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.glyphCount(address(this)), 1_000_000_000);
        assertEq(token.issuanceCount(), 1);
        assertEq(token.glyphAt(address(this), 999_999_999), 1_000_000_000);
    }

    function test_transferAndAllowanceNoTax() public {
        token.approve(spender, 20 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 20 ether));
        assertEq(token.balanceOf(alice), 20 ether);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.totalSupply(), token.SUPPLY());
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(this), bob, 1);
    }

    function test_failuresLeaveBalancesIntact() public {
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1);
        assertEq(token.totalSupply(), token.SUPPLY());
        assertEq(token.balanceOf(alice), 0);
    }

    function test_noOwnerMintPauseUpgradeOrIndependentGlyphTransfer() public {
        string[7] memory signatures = [
            "owner()",
            "mint(address,uint256)",
            "pause()",
            "upgradeTo(address)",
            "transferOwnership(address)",
            "setMinter(address)",
            "safeTransferFrom(address,address,uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, 1));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), token.SUPPLY());
    }

    function test_fractionalCrossingsRetireAndCreateOnlyWholeSlots() public {
        token.transfer(alice, 2.4 ether);
        uint256 first = token.glyphAt(alice, 0);
        uint256 last = token.glyphAt(alice, 1);
        token.transfer(bob, 0.8 ether);
        assertEq(token.glyphCount(bob), 0);
        vm.prank(alice);
        token.transfer(bob, 0.5 ether);
        assertEq(token.glyphCount(alice), 1);
        assertEq(token.glyphCount(bob), 1);
        assertEq(token.glyphAt(alice, 0), first);
        vm.expectRevert(abi.encodeWithSelector(SwarmPeg.GlyphNotLive.selector, last));
        token.glyphOwner(last);
        uint256 id = token.glyphAt(bob, 0);
        (address holder, address previous, bytes32 seed) = token.glyphData(id);
        assertEq(holder, bob);
        assertEq(previous, alice);
        assertNotEq(seed, bytes32(0));
        vm.prank(bob);
        token.transfer(alice, 0.2 ether);
        assertEq(token.glyphCount(alice), 2);
        assertGt(token.glyphAt(alice, 1), id);
        vm.expectRevert(abi.encodeWithSelector(SwarmPeg.GlyphNotLive.selector, last));
        token.glyphOwner(last);
    }

    function test_truncatingManyBatchesAndAppendingDoesNotResurrectOldIds() public {
        for (uint256 i; i < 32; ++i) {
            token.transfer(alice, 1 ether);
        }
        uint256 keep = token.glyphAt(alice, 1);
        uint256 retire = token.glyphAt(alice, 2);
        vm.prank(alice);
        token.transfer(bob, 30 ether);
        assertEq(token.batchCount(alice), 2);
        assertEq(token.glyphAt(alice, 1), keep);
        token.transfer(alice, 15 ether);
        assertEq(token.batchCount(alice), 3);
        assertEq(token.glyphCount(alice), 17);
        assertEq(token.glyphOwner(keep), alice);
        vm.expectRevert(abi.encodeWithSelector(SwarmPeg.GlyphNotLive.selector, retire));
        token.glyphOwner(retire);
        for (uint256 i; i < 17; ++i) {
            assertEq(token.glyphOwner(token.glyphAt(alice, i)), alice);
        }
    }

    function test_zeroSelfAndSubunitTransfersDoNotRerollExistingGlyphs() public {
        token.transfer(alice, 2.5 ether);
        uint256 id = token.glyphAt(alice, 0);
        (,, bytes32 seed) = token.glyphData(id);
        uint256 next = token.nextGlyphId();
        vm.startPrank(alice);
        token.transfer(alice, 1 ether);
        token.transfer(bob, 0);
        token.transfer(bob, 0.1 ether);
        vm.stopPrank();
        token.transfer(alice, 0.1 ether);
        (,, bytes32 afterSeed) = token.glyphData(id);
        assertEq(seed, afterSeed);
        assertEq(token.nextGlyphId(), next);
    }

    function test_bulkTransferBoundedGasAndEmptyHolderCannotReadGlyph() public {
        uint256 before = gasleft();
        token.transfer(alice, token.SUPPLY());
        uint256 gasUsed = before - gasleft();
        assertLt(gasUsed, 500_000);
        assertEq(token.batchCount(alice), 1);
        assertEq(token.glyphCount(alice), 1_000_000_000);
        assertEq(token.glyphOwner(token.glyphAt(alice, 999_999_999)), alice);
        vm.expectRevert(SwarmPeg.GlyphIndexOutOfBounds.selector);
        token.glyphAt(address(this), 0);
        vm.expectRevert(abi.encodeWithSelector(SwarmPeg.GlyphNotLive.selector, 1));
        token.glyphOwner(1);
        vm.expectRevert(abi.encodeWithSelector(SwarmPeg.GlyphNotLive.selector, 0));
        token.glyphOwner(0);
    }

    function testFuzz_transferConservesAndMirrors(uint256 rawA, uint256 rawB) public {
        uint256 a = bound(rawA, 0, token.SUPPLY());
        uint256 b = bound(rawB, 0, a);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob), token.SUPPLY());
        assertEq(token.glyphCount(alice), (a - b) / 1 ether);
        assertEq(token.glyphCount(bob), b / 1 ether);
        if (token.glyphCount(alice) != 0) {
            assertEq(token.glyphOwner(token.glyphAt(alice, token.glyphCount(alice) - 1)), alice);
        }
        if (token.glyphCount(bob) != 0) {
            assertEq(token.glyphOwner(token.glyphAt(bob, token.glyphCount(bob) - 1)), bob);
        }
    }
}
