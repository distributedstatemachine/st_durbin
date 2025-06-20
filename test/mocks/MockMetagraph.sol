// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "../../src/interfaces/IMetagraph.sol";

/**
 * @title MockMetagraph
 * @notice Mock implementation of the Bittensor metagraph precompile for testing
 */
contract MockMetagraph is IMetagraph {
    struct Validator {
        bool isValidator;
        bool isActive;
        bytes32 hotkey;
        uint64 stake;
        uint16 dividend;
    }

    mapping(uint16 => mapping(uint16 => Validator)) public validators;
    mapping(uint16 => uint16) public uidCounts;

    // Set validator data for testing
    function setValidator(
        uint16 netuid,
        uint16 uid,
        bool isValidator,
        bool isActive,
        bytes32 hotkey,
        uint64 stake,
        uint16 dividend
    ) external {
        validators[netuid][uid] =
            Validator({isValidator: isValidator, isActive: isActive, hotkey: hotkey, stake: stake, dividend: dividend});

        // Update uid count if needed
        if (uid >= uidCounts[netuid]) {
            uidCounts[netuid] = uid + 1;
        }
    }

    function setUidCount(uint16 netuid, uint16 count) external {
        uidCounts[netuid] = count;
    }

    // IMetagraph implementation
    function getValidatorStatus(uint16 netuid, uint16 uid) external view override returns (bool) {
        return validators[netuid][uid].isValidator;
    }

    function getIsActive(uint16 netuid, uint16 uid) external view override returns (bool) {
        return validators[netuid][uid].isActive;
    }

    function getHotkey(uint16 netuid, uint16 uid) external view override returns (bytes32) {
        return validators[netuid][uid].hotkey;
    }

    function getStake(uint16 netuid, uint16 uid) external view override returns (uint64) {
        return validators[netuid][uid].stake;
    }

    function getDividends(uint16 netuid, uint16 uid) external view override returns (uint16) {
        return validators[netuid][uid].dividend;
    }

    function getUidCount(uint16 netuid) external view override returns (uint16) {
        return uidCounts[netuid];
    }

    // Additional IMetagraph methods - return default values for testing
    function getAxon(uint16 netuid, uint16 uid) external view override returns (AxonInfo memory) {
        return AxonInfo({block: 0, version: 0, ip: 0, port: 0, ip_type: 0, protocol: 0});
    }

    function getColdkey(uint16 netuid, uint16 uid) external view override returns (bytes32) {
        return bytes32(0);
    }

    function getConsensus(uint16 netuid, uint16 uid) external view override returns (uint16) {
        return 0;
    }

    function getEmission(uint16 netuid, uint16 uid) external view override returns (uint64) {
        return 0;
    }

    function getIncentive(uint16 netuid, uint16 uid) external view override returns (uint16) {
        return 0;
    }

    function getLastUpdate(uint16 netuid, uint16 uid) external view override returns (uint64) {
        return 0;
    }

    function getRank(uint16 netuid, uint16 uid) external view override returns (uint16) {
        return 0;
    }

    function getTrust(uint16 netuid, uint16 uid) external view override returns (uint16) {
        return 0;
    }

    function getVtrust(uint16 netuid, uint16 uid) external view override returns (uint16) {
        return 0;
    }
}
