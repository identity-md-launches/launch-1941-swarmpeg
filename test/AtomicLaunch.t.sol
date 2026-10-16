// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmPeg} from "src/SwarmPeg.sol";
import {SwarmPegHook} from "src/SwarmPegHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev This probe models the factory's deployment role, not a production factory ABI.
/// Deployment, initialization and allocation happen in one external call / transaction.
contract AtomicLaunchProbe {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function launch(bytes32 tokenSalt, bytes32 hookSalt, address requester, address swarm, uint160 price)
        external
        returns (SwarmPeg token, SwarmPegHook hook)
    {
        token = new SwarmPeg{salt: tokenSalt}();
        hook = new SwarmPegHook{salt: hookSalt}(manager, token, address(this));
        manager.initialize(hook.poolKey(), price);
        token.transfer(requester, 20_000_000 ether);
        token.transfer(swarm, 100_000_000 ether);
    }
}

contract AtomicLaunchTest is Test {
    using StateLibrary for IPoolManager;
    uint160 private constant Q96 = 79228162514264337593543950336;
    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    PoolManager private manager;
    AtomicLaunchProbe private factory;
    address private requester;
    address private swarm;

    event PoolBound(bytes32 indexed id, address indexed factory);

    function setUp() public {
        vm.chainId(1);
        manager = new PoolManager(address(this));
        factory = new AtomicLaunchProbe(manager);
        requester = makeAddr("atomic launch requester");
        swarm = makeAddr("atomic launch swarm");
    }

    function test_atomicLaunchAndAllocationWhenTokenIsCurrency0() public {
        _checkLaunch(true);
    }

    function test_atomicLaunchAndAllocationWhenTokenIsCurrency1() public {
        _checkLaunch(false);
    }

    function test_predictedHookWithoutCodeCannotBePreinitialized() public {
        (bytes32 tokenSalt, bytes32 hookSalt, address predictedToken, address predictedHook) = _prepare(true);
        PoolKey memory key = _key(predictedToken, predictedHook);
        assertEq(predictedHook.code.length, 0);
        vm.prank(makeAddr("initialization attacker"));
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(key, Q96);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, 0);
        (, SwarmPegHook hook) = factory.launch(tokenSalt, hookSalt, requester, swarm, Q96);
        assertTrue(hook.initialized(), "failed front-run poisoned the eventual launch");
    }

    function test_initializationFailureRevertsAllCreationsAndSaltsRemainUsable() public {
        (bytes32 tokenSalt, bytes32 hookSalt, address predictedToken, address predictedHook) = _prepare(true);
        // Pool.initialize rejects this price after beforeInitialize has marked the hook live.
        vm.expectRevert();
        factory.launch(tokenSalt, hookSalt, requester, swarm, 0);
        assertEq(predictedToken.code.length, 0, "failed atomic launch left its token behind");
        assertEq(predictedHook.code.length, 0, "failed atomic launch left its hook behind");
        (SwarmPeg token, SwarmPegHook hook) = factory.launch(tokenSalt, hookSalt, requester, swarm, Q96);
        assertEq(address(token), predictedToken);
        assertEq(address(hook), predictedHook);
        assertTrue(hook.initialized());
        assertEq(token.balanceOf(requester), 20_000_000 ether);
    }

    function test_atomicLaunchDoesNotGrantOriginOrRequesterAdministration() public {
        (bytes32 tokenSalt, bytes32 hookSalt,,) = _prepare(true);
        address payer = makeAddr("launch payer");
        vm.prank(payer, payer);
        (SwarmPeg token, SwarmPegHook hook) = factory.launch(tokenSalt, hookSalt, requester, swarm, Q96);
        address[3] memory targets = [address(token), address(hook), address(hook.maintenancePot())];
        address[3] memory callers = [payer, requester, address(factory)];
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 j; j < callers.length; ++j) {
                vm.prank(callers[j]);
                (bool ok,) = targets[i].call(abi.encodeWithSignature("transferOwnership(address)", payer));
                assertFalse(ok, "launch participant obtained ownership");
                vm.prank(callers[j]);
                (ok,) = targets[i].call(abi.encodeWithSignature("upgradeTo(address)", payer));
                assertFalse(ok, "launch participant can upgrade");
            }
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function _checkLaunch(bool below) private {
        (bytes32 tokenSalt, bytes32 hookSalt, address predictedToken, address predictedHook) = _prepare(below);
        PoolKey memory key = _key(predictedToken, predictedHook);
        vm.expectEmit(true, true, false, true, predictedHook);
        emit PoolBound(keccak256(abi.encode(key)), address(factory));
        (SwarmPeg token, SwarmPegHook hook) = factory.launch(tokenSalt, hookSalt, requester, swarm, Q96);
        assertEq(address(token), predictedToken);
        assertEq(address(hook), predictedHook);
        assertEq(address(hook.token()), address(token));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.factory(), address(factory));
        assertTrue(hook.initialized());
        assertEq(token.balanceOf(address(factory)), 880_000_000 ether, "pool seed allocation");
        assertEq(token.balanceOf(requester), 20_000_000 ether);
        assertEq(token.balanceOf(swarm), 100_000_000 ether);
        assertEq(token.glyphCount(address(factory)), 880_000_000);
        assertEq(token.glyphCount(requester), 20_000_000);
        assertEq(token.glyphCount(swarm), 100_000_000);
        assertGt(address(hook.maintenancePot()).code.length, 0, "constructor did not create pot");
        // A contract's first CREATE uses nonce one; this proves the pot is the hook's child.
        address child = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(hook), hex"01")))));
        assertEq(address(hook.maintenancePot()), child);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, Q96);
        vm.prank(address(manager));
        vm.expectRevert(SwarmPegHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(factory), key, Q96);
    }

    function _prepare(bool below)
        private
        view
        returns (bytes32 tokenSalt, bytes32 hookSalt, address predictedToken, address predictedHook)
    {
        bytes32 tokenHash = keccak256(type(SwarmPeg).creationCode);
        for (uint256 i;; ++i) {
            predictedToken = _predict(bytes32(i), tokenHash);
            if ((predictedToken < IMD) == below) {
                tokenSalt = bytes32(i);
                break;
            }
        }
        bytes32 hookHash = keccak256(
            abi.encodePacked(
                type(SwarmPegHook).creationCode, abi.encode(manager, SwarmPeg(predictedToken), address(factory))
            )
        );
        for (uint256 i; i < 500_000; ++i) {
            predictedHook = _predict(bytes32(i), hookHash);
            if (uint160(predictedHook) & 0x3fff == 0x20cc) {
                return (tokenSalt, bytes32(i), predictedToken, predictedHook);
            }
        }
        revert("no hook salt found");
    }

    function _predict(bytes32 salt, bytes32 hash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, hash)))));
    }

    function _key(address token, address hook) private pure returns (PoolKey memory) {
        (address c0, address c1) = token < IMD ? (token, IMD) : (IMD, token);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, 60, IHooks(hook));
    }
}
