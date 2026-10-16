// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Ownerless IMD reserve. No withdrawal, approval, upgrade, or arbitrary execution powers.
/// @dev Fees arrive as PoolManager claims; anyone can materialize them as IMD here. No spending
/// policy was specified for this reserve, so principal cannot be distributed by any actor.
contract MaintenancePot is IUnlockCallback, ReentrancyGuard {
    IPoolManager public immutable poolManager;
    Currency public immutable currency;
    uint256 public totalRedeemed;
    bool private _redeeming;

    error OnlyPoolManager();
    error RedemptionNotActive();
    error InvalidAmount();
    error InvalidRedemptionResponse();

    event FeesRedeemed(address indexed caller, uint256 amount);

    constructor(IPoolManager manager_, Currency currency_) {
        poolManager = manager_;
        currency = currency_;
    }

    function claimBalance() public view returns (uint256) {
        return poolManager.balanceOf(address(this), currency.toId());
    }

    function reserveBalance() external view returns (uint256) {
        return currency.balanceOf(address(this)) + claimBalance();
    }

    /// @notice Anyone can redeem claims, always to this pot. A failed transfer rolls back the burn.
    function redeem(uint256 amount) external nonReentrant {
        if (amount == 0 || amount > claimBalance()) revert InvalidAmount();
        _redeeming = true;
        totalRedeemed += amount;
        emit FeesRedeemed(msg.sender, amount);
        if (poolManager.unlock(abi.encode(amount)).length != 0) revert InvalidRedemptionResponse();
        _redeeming = false;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (!_redeeming) revert RedemptionNotActive();
        _redeeming = false;
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, address(this), amount);
        return "";
    }
}
