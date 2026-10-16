// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Bounded, entirely on-chain SVG renderer. All functions are internal (no linked bytecode).
library SwarmGlyphSVG {
    using Strings for uint256;

    function traits(uint256 pulse) internal pure returns (uint256 nodes, uint256 durationMs, uint256 lightness) {
        nodes = 6 + pulse * 12 / 1000;
        durationMs = 6000 - pulse * 4800 / 1000;
        lightness = 42 + pulse * 30 / 1000;
    }

    function render(uint256 id, bytes32 seed, uint256 pulse) internal pure returns (string memory) {
        (uint256 nodes, uint256 duration, uint256 lightness) = traits(pulse);
        string memory color =
            string.concat("hsl(", (uint256(seed) % 360).toString(), ",90%,", lightness.toString(), "%)");
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400" role="img">',
            "<title>SwarmPeg #",
            id.toString(),
            "</title>",
            "<desc>Animated node network and pixel agent. Swarm pulse ",
            pulse.toString(),
            ".</desc>",
            "<style>:root{--ink:",
            color,
            ";--speed:",
            duration.toString(),
            "ms}",
            ".node{fill:var(--ink);transform-box:fill-box;transform-origin:center;animation:nodePulse var(--speed) ease-in-out infinite}",
            ".wire{fill:none;stroke:var(--ink);stroke-width:1.5;stroke-dasharray:12 8;animation:connect var(--speed) linear infinite}",
            ".agent{fill:var(--ink);animation:breathe var(--speed) ease-in-out infinite}",
            ".status{fill:#fff;animation:blink calc(var(--speed)/3) steps(2,end) infinite}",
            "@keyframes nodePulse{0%,100%{opacity:.4;transform:scale(.8)}50%{opacity:1;transform:scale(1.4)}}",
            "@keyframes connect{0%{stroke-dashoffset:100;opacity:0}50%{opacity:.85}100%{stroke-dashoffset:0;opacity:.1}}",
            "@keyframes breathe{0%,100%{filter:brightness(.8) hue-rotate(0deg)}50%{filter:brightness(1.5) hue-rotate(25deg)}}",
            "@keyframes blink{0%{opacity:1}100%{opacity:.1}}",
            "@media(prefers-reduced-motion:reduce){.node,.wire,.agent,.status{animation:none}}",
            '</style><rect width="400" height="400" rx="24" fill="#080e1b"/>',
            '<path d="M0 100H400M0 200H400M0 300H400M100 0V400M200 0V400M300 0V400" stroke="#162238"/>',
            '<rect x="18" y="18" width="364" height="364" rx="16" fill="none" stroke="#25354c"/>',
            '<g aria-label="network">'
        );
        for (uint256 i; i < nodes; ++i) {
            (uint256 x, uint256 y) = _point(seed, i);
            (uint256 nx, uint256 ny) = _point(seed, (i + 1) % nodes);
            svg = string.concat(
                svg,
                '<path class="wire" d="M',
                x.toString(),
                " ",
                y.toString(),
                "L",
                nx.toString(),
                " ",
                ny.toString(),
                "M",
                x.toString(),
                " ",
                y.toString(),
                'L200 200" style="animation-delay:-',
                (i * 137).toString(),
                'ms"/>',
                '<circle class="node" cx="',
                x.toString(),
                '" cy="',
                y.toString(),
                '" r="',
                (3 + i % 3).toString(),
                '" style="animation-delay:-',
                (i * 211).toString(),
                'ms"/>'
            );
        }
        svg = string.concat(
            svg,
            '</g><rect x="144" y="140" width="112" height="120" rx="8" fill="#101c2e" stroke="',
            color,
            '"/><g class="agent" shape-rendering="crispEdges" aria-label="pixel agent">',
            _agent(seed),
            '</g><rect class="status" x="176" y="187" width="8" height="6"/>',
            '<rect class="status" x="216" y="187" width="8" height="6"/>',
            '<g fill="#c8d6e8" font-family="monospace" font-size="12">',
            '<text x="30" y="43">SWARMPEG / AGENT ',
            id.toString(),
            "</text>",
            '<text x="30" y="357">PULSE ',
            pulse.toString(),
            " / 1000</text>",
            '<text x="258" y="357">NODES ',
            nodes.toString(),
            "</text></g></svg>"
        );
        return svg;
    }

    function _point(bytes32 seed, uint256 index) private pure returns (uint256 x, uint256 y) {
        uint256 h = uint256(keccak256(abi.encode(seed, index)));
        x = 40 + h % 320;
        y = 65 + (h >> 32) % 265;
    }

    function _agent(bytes32 seed) private pure returns (string memory pixels) {
        // 8 x 10 pixel silhouette, variable hair/visor and mirrored accessory pixels.
        uint256 bits = uint256(seed);
        for (uint256 y; y < 10; ++y) {
            for (uint256 x; x < 8; ++x) {
                bool body = y >= 2 && y <= 7 && x >= 1 && x <= 6;
                bool hair = y < 2 && ((bits >> (x + y * 8)) & 1 != 0);
                bool shoulders = y >= 8 && (x <= 2 || x >= 5);
                bool cutout = y == 4 && (x == 2 || x == 5);
                if ((body || hair || shoulders) && !cutout) {
                    pixels = string.concat(
                        pixels,
                        '<rect x="',
                        (160 + x * 10).toString(),
                        '" y="',
                        (150 + y * 10).toString(),
                        '" width="10" height="10"/>'
                    );
                }
            }
        }
    }
}
