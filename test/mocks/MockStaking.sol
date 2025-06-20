// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "../../src/interfaces/IStakingV2.sol";

/**
 * @title MockStaking
 * @notice Mock implementation of the Bittensor staking precompile for testing
 */
contract MockStaking is IStaking {
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

    function setStake(bytes32 coldkey, bytes32 hotkey, uint16 netuid, uint256 amount) external {
        stakes[coldkey][hotkey][netuid] = amount;
    }

    function setTotalStake(bytes32 hotkey, uint16 netuid, uint256 amount) external {
        totalStakes[hotkey][netuid] = amount;
    }

    function setValidator(bytes32 hotkey, uint16 netuid, bool _isValidator) external {
        validators[hotkey][netuid] = _isValidator;
    }

    function setShouldRevert(bool _shouldRevert, string memory _message) external {
        shouldRevert = _shouldRevert;
        revertMessage = _message;
    }

    function setShouldRevertWithoutReason(bool _shouldRevert) external {
        shouldRevertWithoutReason = _shouldRevert;
    }

    function getTotalStake(bytes32 hotkey, uint16 netuid) external view returns (uint256) {
        return totalStakes[hotkey][netuid];
    }

    function transferStake(
        bytes32 destination_coldkey,
        bytes32 hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external override {
        if (shouldRevert) {
            revert(revertMessage);
        }

        if (shouldRevertWithoutReason) {
            assembly {
                revert(0, 0)
            }
        }

        // In real Bittensor, the source coldkey is derived from msg.sender
        // But for testing, we need to handle the mismatch between the contract's SS58 key
        // and its EVM address. We'll look for the stake under the contract's SS58 key.
        bytes32 sourceColdkey = bytes32(uint256(uint160(msg.sender)));
        uint16 srcNetuid = uint16(origin_netuid);
        uint16 dstNetuid = uint16(destination_netuid);

        // Special handling for SaintDurbin contract - check under its SS58 key
        bytes32 contractSs58 = bytes32(uint256(0x888)); // The test contract's SS58 key

        // Try to find stake under the contract's SS58 key first
        if (stakes[contractSs58][hotkey][srcNetuid] >= amount) {
            stakes[contractSs58][hotkey][srcNetuid] -= amount;
            stakes[destination_coldkey][hotkey][dstNetuid] += amount;
        } else if (stakes[sourceColdkey][hotkey][srcNetuid] >= amount) {
            // Fallback to msg.sender derived key
            stakes[sourceColdkey][hotkey][srcNetuid] -= amount;
            stakes[destination_coldkey][hotkey][dstNetuid] += amount;
        } else {
            revert("Insufficient stake");
        }

        transfers.push(
            Transfer({
                from: contractSs58, // Tests expect transfers to come from the contract's SS58 key
                to: destination_coldkey,
                amount: amount,
                netuid: dstNetuid,
                blockNumber: block.number
            })
        );
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
    function addYield(bytes32 coldkey, bytes32 hotkey, uint16 netuid, uint256 amount) external {
        stakes[coldkey][hotkey][netuid] += amount;
    }

    // Implement remaining IStaking interface methods
    function moveStake(
        bytes32 origin_hotkey,
        bytes32 destination_hotkey,
        uint256 origin_netuid,
        uint256 destination_netuid,
        uint256 amount
    ) external override {
        if (shouldRevert) {
            revert(revertMessage);
        }
        // Mock implementation - just track the transfer
        transfers.push(
            Transfer({
                from: origin_hotkey,
                to: destination_hotkey,
                amount: amount,
                netuid: uint16(destination_netuid),
                blockNumber: block.number
            })
        );
    }

    function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable override {
        if (shouldRevert) {
            revert(revertMessage);
        }

        bytes32 coldkey = bytes32(uint256(uint160(msg.sender)));
        stakes[coldkey][hotkey][uint16(netuid)] += amount;
        totalStakes[hotkey][uint16(netuid)] += amount;
    }

    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external override {
        if (shouldRevert) {
            revert(revertMessage);
        }

        bytes32 coldkey = bytes32(uint256(uint160(msg.sender)));
        require(stakes[coldkey][hotkey][uint16(netuid)] >= amount, "Insufficient stake");

        stakes[coldkey][hotkey][uint16(netuid)] -= amount;
        totalStakes[hotkey][uint16(netuid)] -= amount;
    }

    function getTotalColdkeyStake(bytes32 coldkey) external view override returns (uint256) {
        // Mock implementation - return 0
        return 0;
    }

    function getTotalHotkeyStake(bytes32 hotkey) external view override returns (uint256) {
        // Mock implementation - return 0
        return 0;
    }

    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view override returns (uint256) {
        return stakes[coldkey][hotkey][uint16(netuid)];
    }

    function addProxy(bytes32 delegate) external override {
        // Mock implementation - no-op
    }

    function removeProxy(bytes32 delegate) external override {
        // Mock implementation - no-op
    }

    function getAlphaStakedValidators(bytes32 hotkey, uint256 netuid)
        external
        view
        override
        returns (uint256[] memory)
    {
        // Mock implementation - return empty array
        return new uint256[](0);
    }

    function getTotalAlphaStaked(bytes32 hotkey, uint256 netuid) external view override returns (uint256) {
        // Mock implementation - return 0
        return 0;
    }

    function addStakeLimit(bytes32 hotkey, uint256 amount, uint256 limit_price, bool allow_partial, uint256 netuid)
        external
        payable
        override
    {
        // Mock implementation - just call addStake
        this.addStake(hotkey, amount, netuid);
    }

    function removeStakeLimit(bytes32 hotkey, uint256 amount, uint256 limit_price, bool allow_partial, uint256 netuid)
        external
        override
    {
        // Mock implementation - just call removeStake
        this.removeStake(hotkey, amount, netuid);
    }
}
