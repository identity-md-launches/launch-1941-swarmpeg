// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Fixture, SwarmPeg, SwarmPegHook, IPoolManager} from "./helpers/Fixture.sol";
import {PrepareLaunch} from "../script/PrepareLaunch.s.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract DeploymentTest is Fixture {
    function setUp() public {
        _deploy(true);
    }

    function test_prepareLaunchPredictsActualFactoryAddress() public {
        PrepareLaunch prepare = new PrepareLaunch();
        (bytes32 salt, address predicted, bytes32 hash) = prepare.run(address(factory), manager, token, 0, 500_000);
        assertEq(predicted, address(hook));
        assertEq(
            hash,
            keccak256(abi.encodePacked(type(SwarmPegHook).creationCode, abi.encode(manager, token, address(factory))))
        );
        assertEq(_predict(address(factory), salt, hash), address(hook));
    }

    function test_constructorDoesNotCallExternalManagerOrToken() public {
        address absentManager = makeAddr("absent manager");
        address absentToken = makeAddr("absent token");
        PrepareLaunch prepare = new PrepareLaunch();
        (bytes32 salt, address predicted,) =
            prepare.run(address(this), IPoolManager(absentManager), SwarmPeg(absentToken), 0, 500_000);
        SwarmPegHook deployed =
            new SwarmPegHook{salt: salt}(IPoolManager(absentManager), SwarmPeg(absentToken), address(this));
        assertEq(address(deployed), predicted);
        assertGt(address(deployed.maintenancePot()).code.length, 0);
        assertEq(absentManager.code.length, 0);
        assertEq(absentToken.code.length, 0);
    }

    function test_constructorRefusesMissingOrPairTokenArguments() public {
        vm.expectRevert(SwarmPegHook.InvalidAddress.selector);
        new SwarmPegHook(IPoolManager(address(0)), token, address(factory));
        vm.expectRevert(SwarmPegHook.InvalidAddress.selector);
        new SwarmPegHook(manager, SwarmPeg(address(0)), address(factory));
        vm.expectRevert(SwarmPegHook.InvalidAddress.selector);
        new SwarmPegHook(manager, token, address(0));
        vm.expectRevert(SwarmPegHook.InvalidAddress.selector);
        new SwarmPegHook(manager, SwarmPeg(IMD), address(factory));
    }

    function test_wrongAddressFlagsRefused() public {
        bytes32 hash =
            keccak256(abi.encodePacked(type(SwarmPegHook).creationCode, abi.encode(manager, token, address(this))));
        bytes32 salt;
        address predicted = _predict(address(this), salt, hash);
        if (uint160(predicted) & 0x3fff == hook.HOOK_FLAGS()) {
            salt = bytes32(uint256(1));
            predicted = _predict(address(this), salt, hash);
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SwarmPegHook{salt: salt}(manager, token, address(this));
    }

    function test_prepareRejectsInvalidSearch() public {
        PrepareLaunch prepare = new PrepareLaunch();
        vm.expectRevert(PrepareLaunch.InvalidParameters.selector);
        prepare.run(address(0), manager, token, 0, 10);
        vm.expectRevert(PrepareLaunch.InvalidParameters.selector);
        prepare.run(address(factory), manager, token, 0, 0);
    }
}
