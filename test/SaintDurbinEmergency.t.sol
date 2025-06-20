// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/SaintDurbin.sol";
import "./mocks/MockStaking.sol";
import "./mocks/MockMetagraph.sol";

contract SaintDurbinEmergencyTest is Test {
    SaintDurbin public saintDurbin;
    MockStaking public mockStaking;
    MockMetagraph public mockMetagraph;

    address owner = address(0x1);
    address emergencyOperator = address(0x2);
    address notOperator = address(0x3);

    bytes32 drainSs58Address = bytes32(uint256(0x999));
    bytes32 validatorHotkey = bytes32(uint256(0x777));
    bytes32 contractSs58Key = bytes32(uint256(0x888));
    uint16 netuid = 1;
    uint16 validatorUid = 123;

    bytes32[] recipientColdkeys;
    uint256[] proportions;

    uint256 constant INITIAL_STAKE = 10000e9; // 10,000 TAO
    uint256 constant MIN_VALIDATOR_STAKE = 1000e9; // 1,000 TAO

    event EmergencyDrainExecuted(bytes32 indexed drainAddress, uint256 amount);
    event EmergencyDrainRequested(uint256 executionTime);

    function setUp() public {
        // Deploy mock staking at the expected address
        vm.etch(address(0x805), type(MockStaking).runtimeCode);
        mockStaking = MockStaking(address(0x805));

        // Deploy mock metagraph at the expected address
        vm.etch(address(0x802), type(MockMetagraph).runtimeCode);
        mockMetagraph = MockMetagraph(address(0x802));

        // Set up the validator in the metagraph
        mockMetagraph.setValidator(netuid, validatorUid, true, true, validatorHotkey, uint64(1000e9), 10000);

        // Setup simple recipient configuration
        recipientColdkeys = new bytes32[](16);
        proportions = new uint256[](16);

        for (uint256 i = 0; i < 16; i++) {
            recipientColdkeys[i] = bytes32(uint256(0x100 + i));
            proportions[i] = 625; // 6.25% each
        }

        // Setup validator
        mockStaking.setTotalStake(validatorHotkey, netuid, MIN_VALIDATOR_STAKE);
        mockStaking.setValidator(validatorHotkey, netuid, true);

        // Set initial stake for the contract before deployment
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, INITIAL_STAKE);

        // Deploy SaintDurbin with all immutable parameters
        saintDurbin = new SaintDurbin(
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            contractSs58Key,
            netuid,
            recipientColdkeys,
            proportions
        );
    }

    function testEmergencyDrainAccess() public {
        // Test that only emergency operator can request drain
        vm.prank(owner);
        vm.expectRevert(SaintDurbin.NotEmergencyOperator.selector);
        saintDurbin.requestEmergencyDrain();

        vm.prank(notOperator);
        vm.expectRevert(SaintDurbin.NotEmergencyOperator.selector);
        saintDurbin.requestEmergencyDrain();

        // Emergency operator can request
        vm.prank(emergencyOperator);
        saintDurbin.requestEmergencyDrain();

        // Fast forward past timelock
        vm.warp(block.timestamp + 86401);

        // Emergency operator should succeed
        vm.prank(emergencyOperator);
        saintDurbin.executeEmergencyDrain();
    }

    function testEmergencyDrainTransfersFullBalance() public {
        // Add some yield to increase balance
        uint256 yieldAmount = 5000e9; // 5,000 TAO
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, yieldAmount);

        uint256 totalBalance = INITIAL_STAKE + yieldAmount;
        assertEq(saintDurbin.getStakedBalance(), totalBalance);

        // Request and execute emergency drain
        vm.prank(emergencyOperator);
        saintDurbin.requestEmergencyDrain();

        // Fast forward past timelock
        vm.warp(block.timestamp + 86401);

        vm.expectEmit(true, false, false, true);
        emit EmergencyDrainExecuted(drainSs58Address, totalBalance);

        vm.prank(emergencyOperator);
        saintDurbin.executeEmergencyDrain();

        // Verify transfer
        assertEq(mockStaking.getTransferCount(), 1);
        MockStaking.Transfer memory drainTransfer = mockStaking.getTransfer(0);

        assertEq(drainTransfer.from, contractSs58Key);
        assertEq(drainTransfer.to, drainSs58Address);
        assertEq(drainTransfer.amount, totalBalance);
        assertEq(drainTransfer.netuid, netuid);
    }

    function testEmergencyDrainWithZeroBalance() public {
        // Drain all funds first
        vm.prank(emergencyOperator);
        saintDurbin.requestEmergencyDrain();
        vm.warp(block.timestamp + 86401);
        vm.prank(emergencyOperator);
        saintDurbin.executeEmergencyDrain();

        // Set balance to zero
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, 0);

        // Try to drain again without a pending request
        vm.prank(emergencyOperator);
        vm.expectRevert(SaintDurbin.NoPendingRequest.selector);
        saintDurbin.executeEmergencyDrain();
    }

    function testEmergencyDrainDoesNotAffectRecipients() public {
        // Execute a normal distribution first
        uint256 yieldAmount = 1000e9;
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, yieldAmount);
        vm.roll(block.number + 7200);
        saintDurbin.executeTransfer();

        uint256 transfersBeforeDrain = mockStaking.getTransferCount();
        assertEq(transfersBeforeDrain, 16); // All recipients received

        // Add more yield
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, yieldAmount);

        // Emergency drain
        vm.prank(emergencyOperator);
        saintDurbin.requestEmergencyDrain();
        vm.warp(block.timestamp + 86401);
        vm.prank(emergencyOperator);
        saintDurbin.executeEmergencyDrain();

        // Verify only one additional transfer (the drain)
        assertEq(mockStaking.getTransferCount(), transfersBeforeDrain + 1);

        // Verify the drain transfer
        MockStaking.Transfer memory drainTransfer = mockStaking.getTransfer(transfersBeforeDrain);
        assertEq(drainTransfer.to, drainSs58Address);
    }

    function testDrainAddressIsImmutable() public view {
        // Verify drain address cannot be changed
        assertEq(saintDurbin.drainSs58Address(), drainSs58Address);

        // There's no function to change it - it's immutable
    }

    function testEmergencyOperatorIsImmutable() public view {
        // Verify emergency operator cannot be changed
        assertEq(saintDurbin.emergencyOperator(), emergencyOperator);

        // There's no function to change it - it's immutable
    }

    function testEmergencyDrainAfterPrincipalAddition() public {
        // First distribution to establish baseline
        uint256 normalYield = 100e9;
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, normalYield);
        vm.roll(block.number + 7200);
        saintDurbin.executeTransfer();

        // Add principal
        uint256 principalAddition = 5000e9;
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, principalAddition + normalYield);
        vm.roll(14401); // Advance to block 14401 (7201 + 7200)
        saintDurbin.executeTransfer();

        // Verify principal was detected
        assertEq(saintDurbin.principalLocked(), INITIAL_STAKE + principalAddition);

        // Emergency drain should still transfer everything
        uint256 currentBalance = saintDurbin.getStakedBalance();

        vm.prank(emergencyOperator);
        saintDurbin.requestEmergencyDrain();
        vm.warp(block.timestamp + 86401);
        vm.prank(emergencyOperator);
        saintDurbin.executeEmergencyDrain();

        MockStaking.Transfer memory drainTransfer = mockStaking.getTransfer(mockStaking.getTransferCount() - 1);
        assertEq(drainTransfer.amount, currentBalance);
    }

    function testEmergencyDrainWithFailedStakingTransfer() public {
        // Configure mock to fail
        mockStaking.setShouldRevert(true, "Staking transfer failed");

        // Attempt emergency drain
        vm.prank(emergencyOperator);
        saintDurbin.requestEmergencyDrain();
        vm.warp(block.timestamp + 86401);
        vm.prank(emergencyOperator);
        vm.expectRevert(SaintDurbin.StakeMoveFailure.selector);
        saintDurbin.executeEmergencyDrain();
    }

    function testMultipleEmergencyDrainAttempts() public {
        // First drain
        vm.prank(emergencyOperator);
        saintDurbin.requestEmergencyDrain();
        vm.warp(block.timestamp + 86401);
        vm.prank(emergencyOperator);
        saintDurbin.executeEmergencyDrain();

        // Set balance to zero after drain
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, 0);

        // Second drain attempt should fail
        vm.prank(emergencyOperator);
        saintDurbin.requestEmergencyDrain();
        vm.warp(block.timestamp + 86401);
        vm.prank(emergencyOperator);
        vm.expectRevert(SaintDurbin.NoBalance.selector);
        saintDurbin.executeEmergencyDrain();

        // Add new funds
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, 1000e9);

        // Third drain should work
        vm.prank(emergencyOperator);
        saintDurbin.requestEmergencyDrain();
        vm.warp(block.timestamp + 86401);
        vm.prank(emergencyOperator);
        saintDurbin.executeEmergencyDrain();

        assertEq(mockStaking.getTransferCount(), 2);
    }
}
