// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, SwarmPeg} from "./helpers/Fixture.sol";

/// forge-config: default.fuzz.runs = 128
contract GlyphMetadataTest is Fixture {
    uint256 private peakTime;

    function setUp() public {
        _deploy(true);
        _initializeAndSeed();
        for (uint256 i; i < 40; ++i) {
            _swap(i % 2 == 0, true, 1 ether);
        }
        assertEq(hook.currentPulse(), 1000);
        peakTime = block.timestamp;
    }

    function testFuzz_metadataDecodesToTheLiveSVGAndTraits(uint256 rawPulse, uint256 rawSlot) public {
        uint256 pulse = bound(rawPulse, 0, 1000);
        vm.warp(peakTime + (1000 - pulse) * 60);
        uint256 id = token.glyphAt(trader, bound(rawSlot, 0, token.glyphCount(trader) - 1));
        string memory svg = hook.glyphSVG(id);
        string memory uri = hook.glyphURI(id);
        string memory json = string(_decodeDataURI(uri, "data:application/json;base64,"));
        assertEq(vm.parseJsonString(json, ".name"), string.concat("SwarmPeg #", vm.toString(id)));
        string memory image = vm.parseJsonString(json, ".image");
        assertEq(vm.parseJsonString(json, ".animation_url"), image);
        assertEq(string(_decodeDataURI(image, "data:image/svg+xml;base64,")), svg);
        // Independent encoder catches malformed padding and noncanonical base64 too.
        assertEq(image, string.concat("data:image/svg+xml;base64,", vm.toBase64(bytes(svg))));
        assertEq(uri, string.concat("data:application/json;base64,", vm.toBase64(bytes(json))));
        assertEq(vm.parseJsonString(json, ".attributes[0].trait_type"), "Pulse");
        assertEq(vm.parseJsonUint(json, ".attributes[0].value"), pulse);
        (uint256 nodes, uint256 duration, uint256 lightness) = hook.glyphTraits();
        assertEq(vm.parseJsonString(json, ".attributes[1].trait_type"), "Nodes");
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), nodes);
        assertEq(vm.parseJsonString(json, ".attributes[2].trait_type"), "Animation milliseconds");
        assertEq(vm.parseJsonUint(json, ".attributes[2].value"), duration);
        assertEq(vm.parseJsonString(json, ".attributes[3].trait_type"), "Palette lightness");
        assertEq(vm.parseJsonUint(json, ".attributes[3].value"), lightness);
        assertEq(_occurrences(svg, '<circle class="node"'), nodes);
        assertEq(_occurrences(svg, '<path class="wire"'), nodes);
        assertEq(_occurrences(svg, string.concat("--speed:", vm.toString(duration), "ms")), 1);
        assertGt(_occurrences(svg, string.concat(",90%,", vm.toString(lightness), "%)")), 0);
        assertEq(_occurrences(svg, "@keyframes nodePulse"), 1);
        assertEq(_occurrences(svg, "@keyframes connect"), 1);
        assertEq(_occurrences(svg, "@keyframes breathe"), 1);
        assertEq(_occurrences(svg, "@keyframes blink"), 1);
        assertEq(_occurrences(svg, 'shape-rendering="crispEdges"'), 1);
        assertEq(_occurrences(svg, "prefers-reduced-motion:reduce"), 1);
        assertEq(_occurrences(svg, "<script"), 0);
        assertEq(_occurrences(svg, "https://"), 0);
        assertEq(_occurrences(svg, "<image"), 0);
        assertEq(_occurrences(svg, "</svg>"), 1);
    }

    function testFuzz_densityBrightnessAndSpeedAreMonotonic(uint256 rawA, uint256 rawB) public {
        uint256 low = bound(rawA, 0, 1000);
        uint256 high = bound(rawB, low, 1000);
        vm.warp(peakTime + (1000 - high) * 60);
        (uint256 highNodes, uint256 highDuration, uint256 highLightness) = hook.glyphTraits();
        vm.warp(peakTime + (1000 - low) * 60);
        (uint256 lowNodes, uint256 lowDuration, uint256 lowLightness) = hook.glyphTraits();
        assertGe(highNodes, lowNodes);
        assertGe(highLightness, lowLightness);
        assertLe(highDuration, lowDuration);
        assertGe(lowNodes, 6);
        assertLe(highNodes, 18);
        assertGe(highDuration, 1200);
        assertLe(lowDuration, 6000);
    }

    function test_peakAndFullyDecayedTraits() public {
        (uint256 nodes, uint256 duration, uint256 lightness) = hook.glyphTraits();
        assertEq(nodes, 18);
        assertEq(duration, 1200);
        assertEq(lightness, 72);
        vm.warp(peakTime + 60_000);
        (nodes, duration, lightness) = hook.glyphTraits();
        assertEq(nodes, 6);
        assertEq(duration, 6000);
        assertEq(lightness, 42);
    }

    function test_checkpointAndSelfTransferDoNotRerollArt() public {
        uint256 id = token.glyphAt(trader, 0);
        bytes32 peakSeed = hook.glyphSeed(id);
        vm.warp(peakTime + 61);
        bytes32 liveSeed = hook.glyphSeed(id);
        assertNotEq(liveSeed, peakSeed, "decay is missing from live seed");
        string memory uri = hook.glyphURI(id);
        (,, bytes32 birth) = token.glyphData(id);
        hook.checkpointPulse();
        hook.checkpointPulse();
        uint256 balance = token.balanceOf(trader);
        vm.prank(trader);
        token.transfer(trader, balance);
        assertEq(hook.glyphSeed(id), liveSeed);
        assertEq(hook.glyphURI(id), uri);
        (,, bytes32 afterBirth) = token.glyphData(id);
        assertEq(afterBirth, birth);
    }

    function test_allGlyphViewsRejectRetiredAndUnknownIds() public {
        uint256 id = token.glyphAt(trader, 0);
        uint256 balance = token.balanceOf(trader);
        vm.prank(trader);
        token.transfer(requester, balance);
        uint256[4] memory invalid = [id, uint256(0), token.nextGlyphId(), type(uint256).max];
        for (uint256 i; i < invalid.length; ++i) {
            bytes memory reason = abi.encodeWithSelector(SwarmPeg.GlyphNotLive.selector, invalid[i]);
            vm.expectRevert(reason);
            hook.glyphSeed(invalid[i]);
            vm.expectRevert(reason);
            hook.glyphSVG(invalid[i]);
            vm.expectRevert(reason);
            hook.glyphURI(invalid[i]);
        }
    }

    function test_birthSeedChangesWhenOnlyBlockContextChanges() public {
        uint256 state = vm.snapshotState();
        vm.prank(trader);
        token.transfer(requester, 1 ether);
        uint256 id = token.glyphAt(requester, 0);
        (address holder, address previous, bytes32 firstSeed) = token.glyphData(id);
        assertEq(holder, requester);
        assertEq(previous, trader);
        for (uint256 i; i < 3; ++i) {
            assertTrue(vm.revertToState(state));
            if (i == 0) vm.roll(block.number + 1);
            if (i == 1) vm.warp(block.timestamp + 1);
            if (i == 2) vm.prevrandao(bytes32(uint256(123456)));
            vm.prank(trader);
            token.transfer(requester, 1 ether);
            assertEq(token.glyphAt(requester, 0), id);
            (,, bytes32 changedSeed) = token.glyphData(id);
            assertNotEq(changedSeed, firstSeed, "block context omitted from issuance entropy");
        }
    }

    function _decodeDataURI(string memory uri, string memory prefix) private pure returns (bytes memory decoded) {
        bytes memory input = bytes(uri);
        bytes memory head = bytes(prefix);
        require(input.length > head.length, "missing data URI payload");
        for (uint256 i; i < head.length; ++i) {
            require(input[i] == head[i], "incorrect data URI type");
        }
        uint256 length = input.length - head.length;
        require(length % 4 == 0, "invalid base64 length");
        uint256 padding = input[input.length - 1] == "=" ? 1 : 0;
        if (input[input.length - 2] == "=") ++padding;
        decoded = new bytes(length / 4 * 3 - padding);
        uint256 written;
        for (uint256 i = head.length; i < input.length; i += 4) {
            uint256 word;
            for (uint256 j; j < 4; ++j) {
                bytes1 ch = input[i + j];
                uint256 value;
                if (ch >= "A" && ch <= "Z") value = uint8(ch) - 65;
                else if (ch >= "a" && ch <= "z") value = uint8(ch) - 71;
                else if (ch >= "0" && ch <= "9") value = uint8(ch) + 4;
                else if (ch == "+") value = 62;
                else if (ch == "/") value = 63;
                else require(ch == "=" && i + j >= input.length - padding, "invalid base64 character");
                word = (word << 6) | value;
            }
            for (uint256 j; j < 3 && written < decoded.length; ++j) {
                decoded[written++] = bytes1(uint8(word >> (16 - j * 8)));
            }
        }
    }

    function _occurrences(string memory full, string memory part) private pure returns (uint256 count) {
        bytes memory text = bytes(full);
        bytes memory needle = bytes(part);
        if (text.length < needle.length) return 0;
        for (uint256 i; i <= text.length - needle.length; ++i) {
            bool matched = true;
            for (uint256 j; j < needle.length; ++j) {
                if (text[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) ++count;
        }
    }
}
