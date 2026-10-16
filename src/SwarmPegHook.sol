// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SwarmPeg} from "./SwarmPeg.sol";
import {MaintenancePot} from "./MaintenancePot.sol";
import {SwarmGlyphSVG} from "./SwarmGlyphSVG.sol";

/// @notice Immutable, single-pool hook charging 2% of the gross IMD leg on buys and sells.
/// @dev Cosmetic entropy is manipulable, never used for payouts or financial authorization.
contract SwarmPegHook {
    using Strings for uint256;
    using SafeCast for uint256;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant FEE_BPS = 200;
    uint160 public constant HOOK_FLAGS = 0x20cc;
    uint256 public constant MAX_PULSE = 1000;
    uint256 public constant PULSE_PER_TRADE = 25;
    uint256 public constant DECAY_SECONDS = 60;
    uint256 public constant MAX_SWAP_AMOUNT = (1 << 127) - 1;

    IPoolManager public immutable poolManager;
    SwarmPeg public immutable token;
    address public immutable factory;
    MaintenancePot public immutable maintenancePot;
    PoolId public immutable poolId;

    bool public initialized;
    uint256 public storedPulse;
    uint256 public pulseUpdatedAt;
    uint256 public tradeCount;
    uint256 public totalFees;
    bytes32 public tradeEntropy;

    error InvalidAddress();
    error OnlyPoolManager();
    error OnlyFactory();
    error InvalidPool();
    error AlreadyInitialized();
    error PoolNotInitialized();
    error InvalidSwapAmount();
    error PartialFillUnsupported();
    error InvalidSwapDelta();

    event PoolBound(PoolId indexed id, address indexed factory);
    event FeeAccrued(uint256 indexed trade, bool indexed buy, uint256 grossIMD, uint256 feeIMD);
    event PulseUpdated(uint256 pulse, uint256 timestamp, uint256 indexed trade);
    event TradeRecorded(
        uint256 indexed trade, address indexed router, bytes32 entropy, int128 imdDelta, int128 tokenDelta
    );

    constructor(IPoolManager poolManager_, SwarmPeg token_, address factory_) {
        if (
            address(poolManager_) == address(0) || address(token_) == address(0) || factory_ == address(0)
                || address(token_) == IMD
        ) revert InvalidAddress();
        poolManager = poolManager_;
        token = token_;
        factory = factory_;
        PoolKey memory key = _key(address(token_));
        poolId = key.toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        maintenancePot = new MaintenancePot(poolManager_, Currency.wrap(IMD));
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        _checkKey(key);
        if (sender != factory) revert OnlyFactory();
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        emit PoolBound(poolId, sender);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkLive(key);
        uint256 amount = _amount(params.amountSpecified);
        bool buy = _isBuy(key, params);
        // IMD is specified on exact-input buys and exact-output sells. afterSwap can only
        // modify the unspecified currency, so this portion must be returned before the swap.
        uint256 fee;
        if ((params.amountSpecified < 0) == buy) {
            fee = params.amountSpecified < 0 ? amount / 50 : amount / 49;
            if (amount + fee > MAX_SWAP_AMOUNT) revert InvalidSwapAmount();
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkLive(key);
        uint256 amount = _amount(params.amountSpecified);
        bool buy = _isBuy(key, params);
        bool specifiedIMD = (params.amountSpecified < 0) == buy;
        bool imd0 = Currency.unwrap(key.currency0) == IMD;
        int128 imdDelta = imd0 ? delta.amount0() : delta.amount1();
        int128 tokenDelta = imd0 ? delta.amount1() : delta.amount0();
        if (buy ? (imdDelta > 0 || tokenDelta < 0) : (imdDelta < 0 || tokenDelta > 0)) revert InvalidSwapDelta();
        uint256 imdAmount = uint256(imdDelta < 0 ? -int256(imdDelta) : int256(imdDelta));
        uint256 fee;
        if (specifiedIMD) {
            fee = buy ? amount / 50 : amount / 49;
            uint256 expected = buy ? amount - fee : amount + fee;
            // Returning a specified delta fixes the fee before execution. Never tax unfilled
            // volume: revert atomically when this leg cannot fill at the caller's price limit.
            if (imdAmount != expected) revert PartialFillUnsupported();
        } else {
            fee = buy ? imdAmount / 49 : imdAmount / 50;
        }
        uint256 gross = buy ? imdAmount + fee : imdAmount;
        if (fee > MAX_SWAP_AMOUNT) revert InvalidSwapAmount();
        if (imdAmount > 0 && tokenDelta != 0) {
            uint256 pulse = currentPulse() + PULSE_PER_TRADE;
            if (pulse > MAX_PULSE) pulse = MAX_PULSE;
            storedPulse = pulse;
            pulseUpdatedAt = block.timestamp;
            ++tradeCount;
            tradeEntropy = keccak256(
                abi.encode(
                    tradeEntropy,
                    sender,
                    params,
                    delta,
                    block.chainid,
                    block.number,
                    block.timestamp,
                    block.prevrandao,
                    block.number == 0 ? bytes32(0) : blockhash(block.number - 1),
                    pulse,
                    tradeCount
                )
            );
            emit PulseUpdated(pulse, block.timestamp, tradeCount);
            emit TradeRecorded(tradeCount, sender, tradeEntropy, imdDelta, tokenDelta);
        }
        if (fee != 0) {
            totalFees += fee;
            // This debit exactly offsets the positive IMD hook delta. Claims need no manager
            // inventory before the router settles, and are owned directly by the pot.
            poolManager.mint(address(maintenancePot), Currency.wrap(IMD).toId(), fee);
        }
        emit FeeAccrued(tradeCount, buy, gross, fee);
        return (IHooks.afterSwap.selector, specifiedIMD ? int128(0) : fee.toInt128());
    }

    function currentPulse() public view returns (uint256) {
        uint256 elapsed = (block.timestamp - pulseUpdatedAt) / DECAY_SECONDS;
        return elapsed >= storedPulse ? 0 : storedPulse - elapsed;
    }

    /// @notice Materializes decay without discarding fractional minutes or allowing callers to slow it.
    function checkpointPulse() external returns (uint256 pulse) {
        pulse = currentPulse();
        uint256 elapsed = (block.timestamp - pulseUpdatedAt) / DECAY_SECONDS;
        storedPulse = pulse;
        pulseUpdatedAt += elapsed * DECAY_SECONDS;
        emit PulseUpdated(pulse, pulseUpdatedAt, tradeCount);
    }

    function glyphSeed(uint256 id) public view returns (bytes32) {
        (address holder, address previousHolder, bytes32 birthSeed) = token.glyphData(id);
        return keccak256(abi.encode(address(this), id, holder, previousHolder, birthSeed, tradeEntropy, currentPulse()));
    }

    function glyphSVG(uint256 id) public view returns (string memory) {
        return SwarmGlyphSVG.render(id, glyphSeed(id), currentPulse());
    }

    function glyphURI(uint256 id) external view returns (string memory) {
        uint256 pulse = currentPulse();
        string memory image = string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(glyphSVG(id))));
        (uint256 nodes, uint256 duration, uint256 lightness) = SwarmGlyphSVG.traits(pulse);
        bytes memory json = abi.encodePacked(
            '{"name":"SwarmPeg #',
            id.toString(),
            '","description":"Live integer-balance swarm glyph. Cosmetic, evolving on-chain art.",',
            '"image":"',
            image,
            '","animation_url":"',
            image,
            '","attributes":[',
            '{"trait_type":"Pulse","value":',
            pulse.toString(),
            "},",
            '{"trait_type":"Nodes","value":',
            nodes.toString(),
            "},",
            '{"trait_type":"Animation milliseconds","value":',
            duration.toString(),
            "},",
            '{"trait_type":"Palette lightness","value":',
            lightness.toString(),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function glyphTraits() external view returns (uint256 nodes, uint256 durationMs, uint256 lightness) {
        return SwarmGlyphSVG.traits(currentPulse());
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key(address(token));
    }

    function _key(address tokenAddress) private view returns (PoolKey memory key) {
        (address c0, address c1) = tokenAddress < IMD ? (tokenAddress, IMD) : (IMD, tokenAddress);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LP_FEE, TICK_SPACING, IHooks(address(this)));
    }

    function _checkKey(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    function _checkLive(PoolKey calldata key) private view {
        _checkKey(key);
        if (!initialized) revert PoolNotInitialized();
    }

    function _isBuy(PoolKey calldata key, SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (Currency.unwrap(key.currency0) == IMD);
    }

    function _amount(int256 amount) private pure returns (uint256) {
        if (amount == 0 || amount > type(int128).max || amount < -int256(type(int128).max)) revert InvalidSwapAmount();
        return uint256(amount < 0 ? -amount : amount);
    }
}
