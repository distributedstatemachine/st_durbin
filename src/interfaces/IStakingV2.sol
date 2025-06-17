// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

/**
 * @title IStakingV2
 * @notice Interface for the Bittensor staking precompile at address 0x808
 */
interface IStakingV2 {
    /**
     * @notice Get the total stake for a hotkey on a specific subnet
     * @param hotkey The validator hotkey
     * @param netuid The network UID
     * @return The total stake amount
     */
    function getTotalStake(bytes32 hotkey, uint16 netuid) external view returns (uint256);

    /**
     * @notice Transfer stake between coldkeys
     * @param fromColdkey The source coldkey
     * @param toColdkey The destination coldkey
     * @param amount The amount to transfer
     * @param netuid The network UID
     */
    function transferStake(
        bytes32 fromColdkey,
        bytes32 toColdkey,
        uint256 amount,
        uint16 netuid
    ) external;

    /**
     * @notice Get the stake balance for a specific coldkey
     * @param coldkey The coldkey to query
     * @param hotkey The associated hotkey
     * @param netuid The network UID
     * @return The stake balance
     */
    function getStake(
        bytes32 coldkey,
        bytes32 hotkey,
        uint16 netuid
    ) external view returns (uint256);
}