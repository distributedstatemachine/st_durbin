// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/SaintDurbin.sol";
import "./mocks/MockStaking.sol";

contract SaintDurbinTest is Test {
    SaintDurbin public saintDurbin;
    MockStaking public mockStaking;
    
    address owner = address(0x1);
    address emergencyOperator = address(0x2);
    address executor = address(0x3);
    
    bytes32 drainSs58Address = bytes32(uint256(0x999));
    bytes32 validatorHotkey = bytes32(uint256(0x777));
    bytes32 contractSs58Key = bytes32(uint256(0x888));
    uint16 netuid = 1;
    
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
        
        // Ensure it's deployed at the correct address (0x808)
        vm.etch(address(0x808), mockAddress.code);
        mockStaking = MockStaking(address(0x808));
        
        // Setup recipients - 16 total
        recipientColdkeys = new bytes32[](16);
        proportions = new uint256[](16);
        
        // Named recipients from spec
        recipientColdkeys[0] = bytes32(uint256(0x100)); // Sam
        recipientColdkeys[1] = bytes32(uint256(0x200)); // WSL
        recipientColdkeys[2] = bytes32(uint256(0x300)); // Paper
        recipientColdkeys[3] = bytes32(uint256(0x400)); // Florian
        
        proportions[0] = 100;  // Sam: 1%
        proportions[1] = 100;  // WSL: 1%
        proportions[2] = 500;  // Paper: 5%
        proportions[3] = 100;  // Florian: 1%
        
        // Remaining 12 recipients with even distribution
        uint256 remaining = 9200; // 92%
        uint256 perWallet = remaining / 12; // 766
        uint256 leftover = remaining % 12; // 8
        
        for (uint256 i = 4; i < 16; i++) {
            recipientColdkeys[i] = bytes32(uint256(0x500 + i));
            proportions[i] = perWallet;
            if (i == 15) {
                proportions[i] += leftover; // Add remainder to last wallet
            }
        }
        
        // Setup validator
        mockStaking.setTotalStake(validatorHotkey, netuid, MIN_VALIDATOR_STAKE);
        mockStaking.setValidator(validatorHotkey, netuid, true);
        
        // Set initial stake for the empty key (will be used during constructor)
        mockStaking.setStake(bytes32(0), validatorHotkey, netuid, INITIAL_STAKE);
        
        // Deploy SaintDurbin
        saintDurbin = new SaintDurbin(
            owner,
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            netuid,
            recipientColdkeys,
            proportions
        );
        
        // Move stake from empty key to contract's SS58 key
        mockStaking.setStake(bytes32(0), validatorHotkey, netuid, 0);
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, INITIAL_STAKE);
        
        // Set the contract's SS58 key
        vm.prank(owner);
        saintDurbin.setThisSs58PublicKey(contractSs58Key);
    }
    
    function testInitialState() public view {
        assertEq(saintDurbin.owner(), owner);
        assertEq(saintDurbin.emergencyOperator(), emergencyOperator);
        assertEq(saintDurbin.drainSs58Address(), drainSs58Address);
        assertEq(saintDurbin.validatorHotkey(), validatorHotkey);
        assertEq(saintDurbin.netuid(), netuid);
        assertEq(saintDurbin.principalLocked(), INITIAL_STAKE);
        assertEq(saintDurbin.getRecipientCount(), 16);
        assertTrue(saintDurbin.ss58KeySet());
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
        vm.expectRevert("Cannot execute transfer yet");
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
    
    function testPrincipalProtection() public {
        // Try to execute without yield
        vm.roll(block.number + 7200);
        vm.expectRevert("No yield to distribute");
        saintDurbin.executeTransfer();
    }
    
    function testMinimumBlockInterval() public {
        // Add yield
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, 1000e9);
        
        // Execute first transfer
        vm.roll(block.number + 7200);
        saintDurbin.executeTransfer();
        
        // Try immediate second transfer
        vm.expectRevert("Cannot execute transfer yet");
        saintDurbin.executeTransfer();
        
        // Advance blocks and try again
        vm.roll(block.number + 7200);
        
        // Add more yield
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, 500e9);
        
        // Should work now
        saintDurbin.executeTransfer();
    }
    
    function testEmergencyDrain() public {
        // Only emergency operator can drain
        vm.expectRevert("Only emergency operator");
        saintDurbin.emergencyDrain();
        
        // Emergency operator drains
        vm.prank(emergencyOperator);
        saintDurbin.emergencyDrain();
        
        // Verify entire balance was transferred
        assertEq(mockStaking.getTransferCount(), 1);
        MockStaking.Transfer memory drainTransfer = mockStaking.getTransfer(0);
        assertEq(drainTransfer.from, contractSs58Key);
        assertEq(drainTransfer.to, drainSs58Address);
        assertEq(drainTransfer.amount, INITIAL_STAKE);
    }
    
    function testChangeValidatorHotkey() public {
        bytes32 newHotkey = bytes32(uint256(0x666));
        
        // Setup new validator
        mockStaking.setTotalStake(newHotkey, netuid, MIN_VALIDATOR_STAKE);
        mockStaking.setValidator(newHotkey, netuid, true);
        
        // Only owner can change
        vm.expectRevert("Only owner");
        saintDurbin.changeValidatorHotkey(newHotkey);
        
        // Owner changes hotkey
        vm.prank(owner);
        saintDurbin.changeValidatorHotkey(newHotkey);
        
        assertEq(saintDurbin.validatorHotkey(), newHotkey);
    }
    
    function testCannotChangeToInvalidValidator() public {
        bytes32 invalidHotkey = bytes32(uint256(0x555));
        
        // Not a validator (no stake)
        vm.prank(owner);
        vm.expectRevert("Not a validator");
        saintDurbin.changeValidatorHotkey(invalidHotkey);
    }
    
    function testSs58KeyCanOnlyBeSetOnce() public {
        bytes32 newKey = bytes32(uint256(0x444));
        
        vm.prank(owner);
        vm.expectRevert("SS58 key already set");
        saintDurbin.setThisSs58PublicKey(newKey);
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

    // ========== Constructor Validation Tests ==========
    
    function testConstructor_InvalidOwner() public {
        vm.expectRevert("Invalid owner");
        new SaintDurbin(
            address(0), // invalid owner
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            netuid,
            recipientColdkeys,
            proportions
        );
    }
    
    function testConstructor_InvalidEmergencyOperator() public {
        vm.expectRevert("Invalid emergency operator");
        new SaintDurbin(
            owner,
            address(0), // invalid emergency operator
            drainSs58Address,
            validatorHotkey,
            netuid,
            recipientColdkeys,
            proportions
        );
    }
    
    function testConstructor_InvalidDrainAddress() public {
        vm.expectRevert("Invalid drain address");
        new SaintDurbin(
            owner,
            emergencyOperator,
            bytes32(0), // invalid drain address
            validatorHotkey,
            netuid,
            recipientColdkeys,
            proportions
        );
    }
    
    function testConstructor_InvalidValidatorHotkey() public {
        vm.expectRevert("Invalid validator hotkey");
        new SaintDurbin(
            owner,
            emergencyOperator,
            drainSs58Address,
            bytes32(0), // invalid validator hotkey
            netuid,
            recipientColdkeys,
            proportions
        );
    }
    
    function testConstructor_MismatchedArrays() public {
        uint256[] memory wrongProportions = new uint256[](15); // wrong size
        for (uint256 i = 0; i < 15; i++) {
            wrongProportions[i] = 666;
        }
        
        vm.expectRevert("Mismatched arrays");
        new SaintDurbin(
            owner,
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            netuid,
            recipientColdkeys,
            wrongProportions
        );
    }
    
    function testConstructor_WrongRecipientCount() public {
        bytes32[] memory wrongRecipients = new bytes32[](15); // wrong count
        uint256[] memory wrongProportions = new uint256[](15);
        
        for (uint256 i = 0; i < 15; i++) {
            wrongRecipients[i] = bytes32(uint256(0x100 + i));
            wrongProportions[i] = 666;
        }
        
        vm.expectRevert("Must have 16 recipients");
        new SaintDurbin(
            owner,
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            netuid,
            wrongRecipients,
            wrongProportions
        );
    }
    
    function testConstructor_InvalidRecipient() public {
        bytes32[] memory badRecipients = new bytes32[](16);
        uint256[] memory validProportions = new uint256[](16);
        
        for (uint256 i = 0; i < 16; i++) {
            badRecipients[i] = bytes32(uint256(0x100 + i));
            validProportions[i] = 625;
        }
        badRecipients[5] = bytes32(0); // invalid recipient
        
        vm.expectRevert("Invalid recipient");
        new SaintDurbin(
            owner,
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            netuid,
            badRecipients,
            validProportions
        );
    }
    
    function testConstructor_InvalidProportion() public {
        uint256[] memory badProportions = new uint256[](16);
        
        for (uint256 i = 0; i < 16; i++) {
            badProportions[i] = 625;
        }
        badProportions[7] = 0; // invalid proportion
        
        vm.expectRevert("Invalid proportion");
        new SaintDurbin(
            owner,
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            netuid,
            recipientColdkeys,
            badProportions
        );
    }
    
    function testConstructor_InvalidProportionSum() public {
        uint256[] memory badProportions = new uint256[](16);
        
        for (uint256 i = 0; i < 16; i++) {
            badProportions[i] = 600; // total = 9600, not 10000
        }
        
        vm.expectRevert("Proportions must sum to 10000");
        new SaintDurbin(
            owner,
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            netuid,
            recipientColdkeys,
            badProportions
        );
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
    
    function testChangeValidatorHotkey_InvalidHotkey() public {
        vm.prank(owner);
        vm.expectRevert("Invalid hotkey");
        saintDurbin.changeValidatorHotkey(bytes32(0));
    }
    
    function testSetThisSs58PublicKey_InvalidKey() public {
        // Deploy new contract without setting SS58 key
        SaintDurbin newSaintDurbin = new SaintDurbin(
            owner,
            emergencyOperator,
            drainSs58Address,
            validatorHotkey,
            netuid,
            recipientColdkeys,
            proportions
        );
        
        vm.prank(owner);
        vm.expectRevert("Invalid public key");
        newSaintDurbin.setThisSs58PublicKey(bytes32(0));
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
    
    function testIsValidator() public {
        // Test valid validator
        assertTrue(saintDurbin.isValidator(validatorHotkey));
        
        // Test invalid validator (no stake)
        bytes32 invalidValidator = bytes32(uint256(0x555));
        assertFalse(saintDurbin.isValidator(invalidValidator));
        
        // Test validator with insufficient stake
        bytes32 lowStakeValidator = bytes32(uint256(0x666));
        mockStaking.setTotalStake(lowStakeValidator, netuid, 999e9); // below threshold
        assertFalse(saintDurbin.isValidator(lowStakeValidator));
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