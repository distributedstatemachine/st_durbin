// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "../../src/interfaces/IStakingV2.sol";

/**
 * @title MockStaking
 * @notice Mock implementation of the Bittensor staking precompile for testing
 */
contract MockStaking is IStakingV2 {
    mapping(bytes32 => mapping(bytes32 => mapping(uint16 => uint256))) public stakes;
    mapping(bytes32 => mapping(uint16 => uint256)) public totalStakes;
    mapping(bytes32 => mapping(uint16 => bool)) public validators;
    
    // Track transfers for testing
    struct Transfer {
        bytes32 from;
        bytes32 to;
        uint256 amount;
        uint16 netuid;
        uint256 blockNumber;
    }
    Transfer[] public transfers;
    
    // Configurable behavior for testing
    bool public shouldRevert;
    string public revertMessage = "Mock revert";
    bool public shouldRevertWithoutReason;
    
    function setStake(
        bytes32 coldkey,
        bytes32 hotkey,
        uint16 netuid,
        uint256 amount
    ) external {
        stakes[coldkey][hotkey][netuid] = amount;
    }
    
    function setTotalStake(
        bytes32 hotkey,
        uint16 netuid,
        uint256 amount
    ) external {
        totalStakes[hotkey][netuid] = amount;
    }
    
    function setValidator(
        bytes32 hotkey,
        uint16 netuid,
        bool _isValidator
    ) external {
        validators[hotkey][netuid] = _isValidator;
    }
    
    function setShouldRevert(bool _shouldRevert, string memory _message) external {
        shouldRevert = _shouldRevert;
        revertMessage = _message;
    }
    
    function setShouldRevertWithoutReason(bool _shouldRevert) external {
        shouldRevertWithoutReason = _shouldRevert;
    }
    
    function getTotalStake(bytes32 hotkey, uint16 netuid) external view override returns (uint256) {
        return totalStakes[hotkey][netuid];
    }
    
    function transferStake(
        bytes32 fromColdkey,
        bytes32 toColdkey,
        uint256 amount,
        uint16 netuid
    ) external override {
        if (shouldRevert) {
            revert(revertMessage);
        }
        
        if (shouldRevertWithoutReason) {
            assembly {
                revert(0, 0)
            }
        }
        
        // Find the total stake across all hotkeys for this coldkey
        bytes32 validatorHotkey = bytes32(uint256(0x777)); // The validator hotkey used in tests
        
        if (stakes[fromColdkey][validatorHotkey][netuid] >= amount) {
            stakes[fromColdkey][validatorHotkey][netuid] -= amount;
            stakes[toColdkey][validatorHotkey][netuid] += amount;
        } else {
            revert("Insufficient stake");
        }
        
        transfers.push(Transfer({
            from: fromColdkey,
            to: toColdkey,
            amount: amount,
            netuid: netuid,
            blockNumber: block.number
        }));
    }
    
    function getStake(
        bytes32 coldkey,
        bytes32 hotkey,
        uint16 netuid
    ) external view override returns (uint256) {
        return stakes[coldkey][hotkey][netuid];
    }
    
    function isValidator(bytes32 hotkey, uint16 netuid) external view returns (bool) {
        return validators[hotkey][netuid];
    }
    
    // Helper functions for testing
    function getTransferCount() external view returns (uint256) {
        return transfers.length;
    }
    
    function getTransfer(uint256 index) external view returns (Transfer memory) {
        require(index < transfers.length, "Invalid index");
        return transfers[index];
    }
    
    function clearTransfers() external {
        delete transfers;
    }
    
    // Simulate adding yield
    function addYield(
        bytes32 coldkey,
        bytes32 hotkey,
        uint16 netuid,
        uint256 amount
    ) external {
        stakes[coldkey][hotkey][netuid] += amount;
    }
}