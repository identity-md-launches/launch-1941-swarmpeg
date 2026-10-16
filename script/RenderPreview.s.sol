// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {SwarmGlyphSVG} from "../src/SwarmGlyphSVG.sol";

/// @notice Deterministic art samples; these are previews, not deployed glyph ownership records.
contract RenderPreview {
    function run() external pure {
        console2.log(SwarmGlyphSVG.render(1, keccak256("SwarmPeg art preview"), 0));
        console2.log(SwarmGlyphSVG.render(1, keccak256("SwarmPeg art preview"), 500));
        console2.log(SwarmGlyphSVG.render(1, keccak256("SwarmPeg art preview"), 1000));
    }
}
