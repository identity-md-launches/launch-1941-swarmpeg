// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply ERC20 with a lazy, integer-balance glyph mirror.
/// @dev Glyphs are not separate ERC721 assets. Outgoing whole-balance slots retire last-in-first-out;
/// incoming slots receive fresh, globally unique IDs. Even the billion-token mint is O(1).
contract SwarmPeg is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant UNIT = 1 ether;

    struct Batch {
        uint256 startSlot;
        uint256 endSlot;
        uint256 firstId;
    }

    struct Issuance {
        uint256 firstId;
        uint256 count;
        uint256 startSlot;
        address holder;
        address previousHolder;
        bytes32 seed;
    }

    mapping(address => mapping(uint256 => Batch)) private _batches;
    mapping(address => uint256) public batchCount;
    Issuance[] private _issuances;
    uint256 public nextGlyphId = 1;

    error GlyphIndexOutOfBounds();
    error GlyphNotLive(uint256 id);

    event GlyphBatchCreated(
        address indexed holder, uint256 indexed firstId, uint256 count, address indexed previousHolder, bytes32 seed
    );
    event GlyphBalanceChanged(address indexed holder, uint256 previousCount, uint256 newCount);

    constructor() ERC20("SwarmPeg", "SWARMPEG") {
        _mint(msg.sender, SUPPLY);
    }

    function glyphCount(address holder) public view returns (uint256) {
        return balanceOf(holder) / UNIT;
    }

    function glyphAt(address holder, uint256 index) public view returns (uint256) {
        if (index >= glyphCount(holder)) revert GlyphIndexOutOfBounds();
        Batch storage batch = _batches[holder][_batchAt(holder, index)];
        return batch.firstId + index - batch.startSlot;
    }

    /// @notice Reverts for a retired ID; historical issuance does not grant ownership.
    function glyphOwner(uint256 id) public view returns (address holder) {
        (holder,,) = glyphData(id);
    }

    function glyphData(uint256 id) public view returns (address holder, address previousHolder, bytes32 birthSeed) {
        if (id == 0 || id >= nextGlyphId) revert GlyphNotLive(id);
        uint256 low = 0;
        uint256 high = _issuances.length;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (_issuances[mid].firstId <= id) low = mid + 1;
            else high = mid;
        }
        Issuance storage issued = _issuances[low - 1];
        uint256 slot = issued.startSlot + id - issued.firstId;
        holder = issued.holder;
        if (slot >= glyphCount(holder) || glyphAt(holder, slot) != id) revert GlyphNotLive(id);
        return (holder, issued.previousHolder, issued.seed);
    }

    function issuanceCount() external view returns (uint256) {
        return _issuances.length;
    }

    function issuance(uint256 index) external view returns (Issuance memory) {
        return _issuances[index];
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 oldFrom = glyphCount(from);
        uint256 oldTo = glyphCount(to);
        super._update(from, to, value);
        // A zero transfer or self-transfer must not reroll anyone's art.
        if (value == 0 || from == to) return;
        if (from != address(0)) {
            uint256 remaining = glyphCount(from);
            if (remaining < oldFrom) {
                if (remaining == 0) {
                    batchCount[from] = 0;
                } else {
                    uint256 last = _batchAt(from, remaining - 1);
                    _batches[from][last].endSlot = remaining;
                    batchCount[from] = last + 1;
                }
                emit GlyphBalanceChanged(from, oldFrom, remaining);
            }
        }
        if (to != address(0)) {
            uint256 current = glyphCount(to);
            if (current > oldTo) {
                uint256 first = nextGlyphId;
                uint256 count = current - oldTo;
                bytes32 seed = keccak256(
                    abi.encode(
                        block.chainid,
                        address(this),
                        first,
                        from,
                        to,
                        value,
                        block.number,
                        block.timestamp,
                        block.prevrandao,
                        block.number == 0 ? bytes32(0) : blockhash(block.number - 1)
                    )
                );
                _batches[to][batchCount[to]++] = Batch(oldTo, current, first);
                _issuances.push(Issuance(first, count, oldTo, to, from, seed));
                nextGlyphId = first + count;
                emit GlyphBatchCreated(to, first, count, from, seed);
                emit GlyphBalanceChanged(to, oldTo, current);
            }
        }
    }

    /// @dev Strictly shrinking binary search: cost depends on transfer history, never token amount.
    function _batchAt(address holder, uint256 slot) private view returns (uint256) {
        uint256 low = 0;
        uint256 high = batchCount[holder];
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (_batches[holder][mid].endSlot <= slot) low = mid + 1;
            else high = mid;
        }
        return low;
    }
}
