// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/SaintDurbin.sol";
import "./mocks/MockStaking.sol";

contract SaintDurbinEmergencyTest is Test {
    SaintDurbin public saintDurbin;
    MockStaking public mockStaking;
    
    address owner = address(0x1);
    address emergencyOperator = address(0x2);
    address notOperator = address(0x3);
    
    bytes32 drainSs58Address = bytes32(uint256(0x999));
    bytes32 validatorHotkey = bytes32(uint256(0x777));
    bytes32 contractSs58Key = bytes32(uint256(0x888));
    uint16 netuid = 1;
    
    bytes32[] recipientColdkeys;
    uint256[] proportions;
    
    uint256 constant INITIAL_STAKE = 10000e9; // 10,000 TAO
    uint256 constant MIN_VALIDATOR_STAKE = 1000e9; // 1,000 TAO
    
    event EmergencyDrainExecuted(bytes32 indexed drainAddress, uint256 amount);
    
    function setUp() public {
        // Deploy mock staking at the expected address
        vm.etch(address(0x808), type(MockStaking).runtimeCode);
        mockStaking = MockStaking(address(0x808));
        
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
        
        // Set initial stake for the contract
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, INITIAL_STAKE);
        
        // Set the contract's SS58 key
        vm.prank(owner);
        saintDurbin.setThisSs58PublicKey(contractSs58Key);
    }
    
    function testEmergencyDrainAccess() public {
        // Test that only emergency operator can drain
        vm.prank(owner);
        vm.expectRevert("Only emergency operator");
        saintDurbin.emergencyDrain();
        
        vm.prank(notOperator);
        vm.expectRevert("Only emergency operator");
        saintDurbin.emergencyDrain();
        
        // Emergency operator should succeed
        vm.prank(emergencyOperator);
        saintDurbin.emergencyDrain();
    }
    
    function testEmergencyDrainTransfersFullBalance() public {
        // Add some yield to increase balance
        uint256 yieldAmount = 5000e9; // 5,000 TAO
        mockStaking.addYield(contractSs58Key, validatorHotkey, netuid, yieldAmount);
        
        uint256 totalBalance = INITIAL_STAKE + yieldAmount;
        assertEq(saintDurbin.getStakedBalance(), totalBalance);
        
        // Execute emergency drain
        vm.expectEmit(true, false, false, true);
        emit EmergencyDrainExecuted(drainSs58Address, totalBalance);
        
        vm.prank(emergencyOperator);
        saintDurbin.emergencyDrain();
        
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
        saintDurbin.emergencyDrain();
        
        // Set balance to zero
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, 0);
        
        // Try to drain again
        vm.prank(emergencyOperator);
        vm.expectRevert("No balance to drain");
        saintDurbin.emergencyDrain();
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
        saintDurbin.emergencyDrain();
        
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
        vm.roll(14401);  // Advance to block 14401 (7201 + 7200)
        saintDurbin.executeTransfer();
        
        // Verify principal was detected
        assertEq(saintDurbin.principalLocked(), INITIAL_STAKE + principalAddition);
        
        // Emergency drain should still transfer everything
        uint256 currentBalance = saintDurbin.getStakedBalance();
        
        vm.prank(emergencyOperator);
        saintDurbin.emergencyDrain();
        
        MockStaking.Transfer memory drainTransfer = mockStaking.getTransfer(mockStaking.getTransferCount() - 1);
        assertEq(drainTransfer.amount, currentBalance);
    }
    
    function testEmergencyDrainWithFailedStakingTransfer() public {
        // Configure mock to fail
        mockStaking.setShouldRevert(true, "Staking transfer failed");
        
        // Attempt emergency drain
        vm.prank(emergencyOperator);
        vm.expectRevert("Staking transfer failed");
        saintDurbin.emergencyDrain();
    }
    
    function testMultipleEmergencyDrainAttempts() public {
        // First drain
        vm.prank(emergencyOperator);
        saintDurbin.emergencyDrain();
        
        // Set balance to zero after drain
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, 0);
        
        // Second drain attempt should fail
        vm.prank(emergencyOperator);
        vm.expectRevert("No balance to drain");
        saintDurbin.emergencyDrain();
        
        // Add new funds
        mockStaking.setStake(contractSs58Key, validatorHotkey, netuid, 1000e9);
        
        // Third drain should work
        vm.prank(emergencyOperator);
        saintDurbin.emergencyDrain();
        
        assertEq(mockStaking.getTransferCount(), 2);
    }
}