// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockIMD is ERC20 {
    bool public rejectTransfers;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;
    constructor() ERC20("IMD test double", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRejectTransfers(bool value) external {
        rejectTransfers = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!rejectTransfers || from == address(0), "IMD transfer rejected");
        super._update(from, to, value);
        if (reentryTarget != address(0)) {
            address target = reentryTarget;
            reentryTarget = address(0);
            (reentrySucceeded,) = target.call(reentryData);
        }
    }
}
