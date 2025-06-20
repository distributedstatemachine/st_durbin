// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/SaintDurbin.sol";
import "./mocks/MockStaking.sol";
import "./mocks/MockMetagraph.sol";

contract SaintDurbinTest is Test {
    SaintDurbin public saintDurbin;
    MockStaking public mockStaking;
    MockMetagraph public mockMetagraph;

    address owner = address(0x1);
    address emergencyOperator = address(0x2);
    address executor = address(0x3);

    bytes32 drainSs58Address = bytes32(uint256(0x999));
    bytes32 validatorHotkey = bytes32(uint256(0x777));
    bytes32 contractSs58Key = bytes32(uint256(0x888));
    uint16 netuid = 1;
    uint16 validatorUid = 123;

    bytes32[] recipientColdkeys;
    uint256[] proportions;

    uint256 constant INITIAL_STAKE = 10000e9; // 10,000 TAO
    uint256 constant MIN_VALIDATOR_STAKE = 1000e9; // 1,000 TAO

    function setUp() public {
        // Deploy mock staking at the expected address
        bytes memory bytecode = type(MockStaking).creationCode;
        address mockAddress;
        assembly {
            mockAddress := create2(0, add(bytecode, 0x20), mload(bytecode), 0)
        }

        // Ensure it's deployed at the correct address (0x805)
        vm.etch(address(0x805), mockAddress.code);
        mockStaking = MockStaking(address(0x805));

        // Deploy mock metagraph at the expected address
        vm.etch(address(0x802), type(MockMetagraph).runtimeCode);
        mockMetagraph = MockMetagraph(address(0x802));

        // Set up the validator in the metagraph
        mockMetagraph.setValidator(netuid, validatorUid, true, true, validatorHotkey, uint64(1000e9), 10000);

        // Setup recipients - 16 total
        recipientColdkeys = new bytes32[](16);
        proportions = new uint256[](16);

        // Named recipients from spec
        recipientColdkeys[0] = bytes32(uint256(0x100)); // Sam
        recipientColdkeys[1] = bytes32(uint256(0x200)); // WSL
        recipientColdkeys[2] = bytes32(uint256(0x300)); // Paper
        recipientColdkeys[3] = bytes32(uint256(0x400)); // Florian

        proportions[0] = 100; // Sam: 1%
        proportions[1] = 100; // WSL: 1%
        proportions[2] = 500; // Paper: 5%
        proportions[3] = 100; // Florian: 1%

        // Remaining 12 recipients with uneven distribution
        proportions[4] = 100; // Extra recipient 1: 1%
        proportions[5] = 100; // Extra recipient 2: 1%
        proportions[6] = 100; // Extra recipient 3: 1%
        proportions[7] = 300; // Extra recipient 4: 3%
        proportions[8] = 300; // Extra recipient 5: 3%
        proportions[9] = 300; // Extra recipient 6: 3%
        proportions[10] = 1000; // Extra recipient 7: 10%
        proportions[11] = 1000; // Extra recipient 8: 10%
        proportions[12] = 1000; // Extra recipient 9: 10%
        proportions[13] = 1500; // Extra recipient 10: 15%
        proportions[14] = 1500; // Extra recipient 11: 15%
        proportions[15] = 2000; // Extra recipient 12: 20%

        for (uint256 i = 4; i < 16; i++) {
            recipientColdkeys[i] = bytes32(uint256(0x500 + i));
        }

        // Setup validator
        mockStaking.setTotalStake(validatorHotkey, netuid, MIN_VALIDATOR_STAKE);
        mockStaking.setValidator(validatorHotkey, netuid, true);

        // Set initial stake for the empty key (will be used during constructor)
        mockStaking.setStake(bytes32(0), validatorHotkey, netuid, INITIAL_STAKE);

        // Deploy SaintDurbin
        // Move stake before deployment so initial principal is set correctly
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, INITIAL_STAKE);

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

        // Stake is already set before deployment
    }

    function testInitialState() public view {
        assertEq(saintDurbin.emergencyOperator(), emergencyOperator);
        assertEq(saintDurbin.drainSs58Address(), drainSs58Address);
        assertEq(saintDurbin.currentValidatorHotkey(), validatorHotkey);
        assertEq(saintDurbin.currentValidatorUid(), validatorUid);
        assertEq(saintDurbin.netuid(), netuid);
        assertEq(saintDurbin.principalLocked(), INITIAL_STAKE);
        assertEq(saintDurbin.getRecipientCount(), 16);
    }

    function testRecipientConfiguration() public view {
        uint256 totalProportions = 0;

        for (uint256 i = 0; i < 16; i++) {
            (bytes32 coldkey, uint256 proportion) = saintDurbin.getRecipient(i);
            assertEq(coldkey, recipientColdkeys[i]);
            assertEq(proportion, proportions[i]);
            totalProportions += proportion;
        }

        assertEq(totalProportions, 10000); // Must sum to 100%
    }

    function testCannotExecuteTransferBeforeInterval() public {
        vm.expectRevert(SaintDurbin.TransferTooSoon.selector);
        saintDurbin.executeTransfer();
    }

    function testSuccessfulYieldDistribution() public {
        // Add yield
        uint256 yieldAmount = 1000e9; // 1,000 TAO yield
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, yieldAmount);

        // Advance blocks
        vm.roll(block.number + 7200);

        // Execute transfer
        saintDurbin.executeTransfer();

        // Verify transfers
        uint256 transferCount = mockStaking.getTransferCount();
        assertEq(transferCount, 16); // All recipients should receive

        // Verify Sam's transfer (1% of 1000 TAO = 10 TAO)
        MockStaking.Transfer memory samTransfer = mockStaking.getTransfer(0);
        assertEq(samTransfer.from, contractSs58Key);
        assertEq(samTransfer.to, recipientColdkeys[0]);
        assertEq(samTransfer.amount, (yieldAmount * 100) / 10000); // 10 TAO

        // Verify Paper's transfer (5% of 1000 TAO = 50 TAO)
        MockStaking.Transfer memory paperTransfer = mockStaking.getTransfer(2);
        assertEq(paperTransfer.amount, (yieldAmount * 500) / 10000); // 50 TAO
    }

    function testFallbackToLastPaymentAmount() public {
        // First, make a successful transfer with yield
        uint256 firstYield = 1000e9; // 1,000 TAO
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, firstYield);

        // Advance blocks and execute first transfer
        vm.roll(block.number + 7200);
        saintDurbin.executeTransfer();

        // Verify first transfer happened
        uint256 firstTransferCount = mockStaking.getTransferCount();
        assertEq(firstTransferCount, 16);

        // Now advance blocks again but don't add any new yield
        vm.roll(block.number + 7200);

        // Execute transfer again - should use last payment amount as fallback
        saintDurbin.executeTransfer();

        // Verify second round of transfers happened
        uint256 secondTransferCount = mockStaking.getTransferCount();
        assertEq(secondTransferCount, 32); // 16 more transfers

        // Verify the amounts are the same as the first transfer
        // Check Sam's second transfer (index 16) matches first (index 0)
        MockStaking.Transfer memory firstSamTransfer = mockStaking.getTransfer(0);
        MockStaking.Transfer memory secondSamTransfer = mockStaking.getTransfer(16);
        assertEq(secondSamTransfer.amount, firstSamTransfer.amount);
        assertEq(secondSamTransfer.amount, (firstYield * 100) / 10000); // Still 1% of original yield

        // Check Paper's second transfer matches first
        MockStaking.Transfer memory firstPaperTransfer = mockStaking.getTransfer(2);
        MockStaking.Transfer memory secondPaperTransfer = mockStaking.getTransfer(18);
        assertEq(secondPaperTransfer.amount, firstPaperTransfer.amount);
        assertEq(secondPaperTransfer.amount, (firstYield * 500) / 10000); // Still 5% of original yield
    }

    function testNoFallbackWhenNoPreviousPayment() public {
        // Try to execute without any yield or previous payment
        vm.roll(block.number + 7200);

        // Should not revert, but should not transfer anything
        saintDurbin.executeTransfer();

        // Verify no transfers occurred
        assertEq(mockStaking.getTransferCount(), 0);

        // Verify tracking was updated
        assertEq(saintDurbin.lastTransferBlock(), block.number);
    }

    function testMinimumBlockInterval() public {
        // Add yield
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, 1000e9);

        // Execute first transfer
        vm.roll(block.number + 7200);
        saintDurbin.executeTransfer();

        // Try immediate second transfer
        vm.expectRevert(SaintDurbin.TransferTooSoon.selector);
        saintDurbin.executeTransfer();

        // Advance blocks and try again
        vm.roll(block.number + 7200);

        // Add more yield
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, 500e9);

        // Should work now
        saintDurbin.executeTransfer();
    }

    function testEmergencyDrain() public {
        // Add additional stake
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, 1000e9);

        // Only emergency operator can request drain
        vm.expectRevert(SaintDurbin.NotEmergencyOperator.selector);
        saintDurbin.requestEmergencyDrain();

        // Emergency operator requests drain
        vm.prank(emergencyOperator);
        saintDurbin.requestEmergencyDrain();

        // Cannot execute immediately due to timelock
        vm.prank(emergencyOperator);
        vm.expectRevert(SaintDurbin.TimelockNotExpired.selector);
        saintDurbin.executeEmergencyDrain();

        // Fast forward past timelock (24 hours)
        vm.warp(block.timestamp + 86401);

        // Now emergency operator can execute drain
        vm.prank(emergencyOperator);
        saintDurbin.executeEmergencyDrain();

        // Verify entire balance was transferred (including yield)
        assertEq(mockStaking.getTransferCount(), 1);
        MockStaking.Transfer memory drainTransfer = mockStaking.getTransfer(0);
        assertEq(drainTransfer.from, contractSs58Key);
        assertEq(drainTransfer.to, drainSs58Address);
        assertEq(drainTransfer.amount, INITIAL_STAKE + 1000e9); // Initial stake + yield
    }

    function testValidatorIsImmutable() public view {
        // Verify validator hotkey cannot be changed
        assertEq(saintDurbin.currentValidatorHotkey(), validatorHotkey);
        assertEq(saintDurbin.currentValidatorUid(), validatorUid);
        // Contract has no functions to change validator
    }

    function testSs58KeyIsImmutable() public view {
        // Verify SS58 key is set and immutable
        assertEq(saintDurbin.thisSs58PublicKey(), contractSs58Key);
        // Contract has no functions to change SS58 key
    }

    function testViewFunctions() public {
        // Add yield
        uint256 yieldAmount = 500e9;
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, yieldAmount);

        // Test getStakedBalance
        assertEq(saintDurbin.getStakedBalance(), INITIAL_STAKE + yieldAmount);

        // Test getNextTransferAmount
        assertEq(saintDurbin.getNextTransferAmount(), yieldAmount);

        // Test getAvailableRewards
        assertEq(saintDurbin.getAvailableRewards(), yieldAmount);

        // Test canExecuteTransfer
        assertFalse(saintDurbin.canExecuteTransfer());
        vm.roll(block.number + 7200);
        assertTrue(saintDurbin.canExecuteTransfer());

        // Test blocksUntilNextTransfer
        vm.roll(block.number - 3600); // Go back 3600 blocks
        assertEq(saintDurbin.blocksUntilNextTransfer(), 3600);
    }

    function test_RevertWhen_TransferFails() public {
        // Setup staking to revert on certain transfers
        mockStaking.setShouldRevert(true, "Transfer failed");

        // Add yield
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, 1000e9);

        // Advance blocks
        vm.roll(block.number + 7200);

        // Execute transfer - should emit failure events but not revert
        saintDurbin.executeTransfer();

        // No transfers should have succeeded
        assertEq(mockStaking.getTransferCount(), 0);
    }

    function testExistentialAmountCheck() public {
        // Add yield below existential amount
        uint256 tinyYield = 0.5e9; // 0.5 TAO
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, tinyYield);

        // Advance blocks
        vm.roll(block.number + 7200);

        // Execute transfer - should skip distribution
        saintDurbin.executeTransfer();

        // No transfers should have occurred
        assertEq(mockStaking.getTransferCount(), 0);

        // But block timer should have been reset
        assertEq(saintDurbin.lastTransferBlock(), block.number);
    }

    // ========== Function Parameter Validation Tests ==========

    function testExecuteTransfer_UnknownError() public {
        // Configure mock to revert without reason
        mockStaking.setShouldRevertWithoutReason(true);

        // Add yield
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, 1000e9);

        // Advance blocks
        vm.roll(block.number + 7200);

        // Execute transfer - should emit TransferFailed with "Unknown error"
        vm.expectEmit(false, false, false, true);
        emit TransferFailed(recipientColdkeys[0], 10000000000, "Unknown error"); // 1% of 1000 TAO

        saintDurbin.executeTransfer();
    }

    function testInvalidDeploymentParameters() public {
        // Test deployment with invalid SS58 key
        vm.expectRevert(SaintDurbin.InvalidAddress.selector);
        new SaintDurbin(
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            validatorUid,
            bytes32(0), // Invalid SS58 key
            netuid,
            recipientColdkeys,
            proportions
        );
    }

    // ========== View Function Edge Cases ==========

    function testGetNextTransferAmount_EdgeCase() public {
        // Set balance below principal
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, 9000e9);

        // Should return 0
        assertEq(saintDurbin.getNextTransferAmount(), 0);
    }

    function testBlocksUntilNextTransfer_EdgeCase() public {
        // Roll to exactly the next transfer block
        vm.roll(saintDurbin.lastTransferBlock() + 7200);

        // Should return 0
        assertEq(saintDurbin.blocksUntilNextTransfer(), 0);
    }

    function testGetAvailableRewards_EdgeCase() public {
        // Set balance below principal
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, 9000e9);

        // Should return 0
        assertEq(saintDurbin.getAvailableRewards(), 0);
    }

    function testGetCurrentValidatorInfo() public {
        // Test current validator info
        (bytes32 hotkey, uint16 uid, bool isValid) = saintDurbin.getCurrentValidatorInfo();
        assertEq(hotkey, validatorHotkey);
        assertEq(uid, validatorUid);
        // Note: isValid will be false since we haven't set up the metagraph mock yet
    }

    function testGetRecipient_InvalidIndex() public {
        vm.expectRevert("Invalid index");
        saintDurbin.getRecipient(16); // index out of bounds

        vm.expectRevert("Invalid index");
        saintDurbin.getRecipient(100); // way out of bounds
    }

    // Event declaration for tests
    event TransferFailed(bytes32 indexed coldkey, uint256 amount, string reason);
}
