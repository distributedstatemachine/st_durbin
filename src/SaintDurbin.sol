// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "./interfaces/IStakingV2.sol";
import "./interfaces/IMetagraph.sol";

/**
 * @title SaintDurbin
 * @notice Patron Saint of Bittensor - With Automatic Validator Switching
 * @dev Distributes staking rewards to recipients while preserving the principal amount
 * @dev Automatically switches validators if current validator loses permit
 */
contract SaintDurbin {
    // ========== Constants ==========
    address constant IMETAGRAPH_ADDRESS = address(0x802);
    uint256 constant MIN_BLOCK_INTERVAL = 7200; // ~24 hours at 12s blocks
    uint256 constant EXISTENTIAL_AMOUNT = 1e9; // 1 TAO in rao (9 decimals)
    uint256 constant BASIS_POINTS = 10000;
    uint256 constant RATE_MULTIPLIER_THRESHOLD = 2;
    uint256 constant MIN_VALIDATOR_STAKE = 1000e9; // 1000 TAO
    uint256 constant EMERGENCY_TIMELOCK = 86400; // 24 hours timelock for emergency drain

    // ========== State Variables ==========

    // Core configuration
    IStaking public immutable staking;
    IMetagraph public immutable metagraph;
    bytes32 public currentValidatorHotkey; // Mutable - can change if validator loses permit
    uint16 public currentValidatorUid; // Track the UID of current validator
    bytes32 public immutable thisSs58PublicKey;
    uint16 public immutable netuid;

    // Recipients
    struct Recipient {
        bytes32 coldkey;
        uint256 proportion; // Basis points (out of 10,000)
    }

    Recipient[] public recipients;

    // Tracking
    uint256 public principalLocked;
    uint256 public previousBalance;
    uint256 public lastTransferBlock;
    uint256 public lastRewardRate;
    uint256 public lastPaymentAmount;
    uint256 public lastValidatorCheckBlock; // Track when we last checked validator status

    // Emergency drain
    address public immutable emergencyOperator;
    bytes32 public immutable drainSs58Address;
    uint256 public emergencyDrainRequestedAt;

    // Reentrancy protection
    bool private locked;

    // Enhanced principal tracking
    uint256 public cumulativeBalanceIncrease;
    uint256 public lastBalanceCheckBlock;

    // ========== Events ==========
    event StakeTransferred(uint256 totalAmount, uint256 newBalance);
    event RecipientTransfer(bytes32 indexed coldkey, uint256 amount, uint256 proportion);
    event PrincipalDetected(uint256 amount, uint256 totalPrincipal);
    event EmergencyDrainExecuted(bytes32 indexed drainAddress, uint256 amount);
    event TransferFailed(bytes32 indexed coldkey, uint256 amount, string reason);
    event EmergencyDrainRequested(uint256 executionTime);
    event EmergencyDrainCancelled();
    event ValidatorSwitched(bytes32 indexed oldHotkey, bytes32 indexed newHotkey, uint16 newUid, string reason);
    event ValidatorCheckFailed(string reason);

    // ========== Custom Errors ==========
    error NotEmergencyOperator();
    error InvalidAddress();
    error InvalidHotkey();
    error InvalidProportion();
    error ProportionsMismatch();
    error TransferTooSoon();
    error NoBalance();
    error ReentrancyGuard();
    error TimelockNotExpired();
    error NoPendingRequest();
    error NoValidValidatorFound();
    error StakeMoveFailure();

    // ========== Modifiers ==========
    modifier onlyEmergencyOperator() {
        if (msg.sender != emergencyOperator) revert NotEmergencyOperator();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert ReentrancyGuard();
        locked = true;
        _;
        locked = false;
    }

    // ========== Constructor ==========
    constructor(
        address _emergencyOperator,
        bytes32 _drainSs58Address,
        bytes32 _validatorHotkey,
        uint16 _validatorUid,
        bytes32 _thisSs58PublicKey,
        uint16 _netuid,
        bytes32[] memory _recipientColdkeys,
        uint256[] memory _proportions
    ) {
        if (_emergencyOperator == address(0)) revert InvalidAddress();
        if (_drainSs58Address == bytes32(0)) revert InvalidAddress();
        if (_validatorHotkey == bytes32(0)) revert InvalidHotkey();
        if (_thisSs58PublicKey == bytes32(0)) revert InvalidAddress();
        if (_recipientColdkeys.length != _proportions.length) revert ProportionsMismatch();
        if (_recipientColdkeys.length != 16) revert ProportionsMismatch();

        emergencyOperator = _emergencyOperator;
        drainSs58Address = _drainSs58Address;
        currentValidatorHotkey = _validatorHotkey;
        currentValidatorUid = _validatorUid;
        thisSs58PublicKey = _thisSs58PublicKey;
        netuid = _netuid;
        staking = IStaking(ISTAKING_ADDRESS);
        metagraph = IMetagraph(IMETAGRAPH_ADDRESS);

        // Validate proportions sum to 10000
        uint256 totalProportions = 0;
        for (uint256 i = 0; i < _proportions.length; i++) {
            if (_recipientColdkeys[i] == bytes32(0)) revert InvalidAddress();
            if (_proportions[i] == 0) revert InvalidProportion();
            totalProportions += _proportions[i];

            recipients.push(Recipient({coldkey: _recipientColdkeys[i], proportion: _proportions[i]}));
        }
        if (totalProportions != BASIS_POINTS) revert ProportionsMismatch();

        // Initialize tracking
        lastTransferBlock = block.number;
        lastValidatorCheckBlock = block.number;

        // Get initial balance and set as principal
        principalLocked = _getStakedBalance();
        previousBalance = principalLocked;
    }

    // ========== Core Functions ==========

    /**
     * @notice Execute daily yield distribution to all recipients
     * @dev Can be called by anyone when conditions are met
     * @dev Checks validator status and switches if necessary
     */
    function executeTransfer() external nonReentrant {
        if (!canExecuteTransfer()) revert TransferTooSoon();

        // Check and switch validator if needed (every 100 blocks ~ 20 minutes)
        if (block.number >= lastValidatorCheckBlock + 100) {
            _checkAndSwitchValidator();
        }

        uint256 currentBalance = _getStakedBalance();
        uint256 availableYield;

        // If balance hasn't changed, use last payment amount as fallback
        if (currentBalance <= principalLocked) {
            if (lastPaymentAmount > 0) {
                availableYield = lastPaymentAmount;
            } else {
                // No yield and no previous payment to fall back to
                lastTransferBlock = block.number;
                previousBalance = currentBalance;
                return;
            }
        } else {
            availableYield = currentBalance - principalLocked;
        }

        // Enhanced principal detection with cumulative tracking
        if (lastPaymentAmount > 0 && previousBalance > 0 && currentBalance > principalLocked) {
            uint256 blocksSinceLastTransfer = block.number - lastTransferBlock;
            uint256 currentRate = (availableYield * 1e18) / blocksSinceLastTransfer;

            // Track cumulative balance increases
            if (currentBalance > previousBalance) {
                uint256 increase = currentBalance - previousBalance;
                cumulativeBalanceIncrease += increase;
            }

            // Enhanced principal detection: check both rate multiplier and absolute threshold
            bool rateBasedDetection = lastRewardRate > 0 && currentRate > lastRewardRate * RATE_MULTIPLIER_THRESHOLD;
            bool absoluteDetection = availableYield > lastPaymentAmount * 3; // Detect if yield is 3x previous payment

            if (rateBasedDetection || absoluteDetection) {
                // Principal addition detected
                uint256 detectedPrincipal = availableYield - lastPaymentAmount;
                principalLocked += detectedPrincipal;
                availableYield = lastPaymentAmount; // Use previous payment amount

                emit PrincipalDetected(detectedPrincipal, principalLocked);
            }

            lastRewardRate = currentRate;
        } else if (currentBalance > principalLocked) {
            // First transfer or establishing baseline rate
            uint256 blocksSinceLastTransfer = block.number - lastTransferBlock;
            if (blocksSinceLastTransfer > 0) {
                lastRewardRate = (availableYield * 1e18) / blocksSinceLastTransfer;
            }
        }

        lastBalanceCheckBlock = block.number;

        // Check if yield is below existential amount
        if (availableYield < EXISTENTIAL_AMOUNT) {
            lastTransferBlock = block.number;
            previousBalance = currentBalance;
            return;
        }

        // Calculate and execute transfers
        uint256 totalTransferred = 0;
        uint256 remainingYield = availableYield;

        // Gas optimization - cache recipients length
        uint256 recipientsLength = recipients.length;

        for (uint256 i = 0; i < recipientsLength; i++) {
            uint256 recipientAmount;

            // Improved precision handling for last recipient
            if (i == recipientsLength - 1) {
                // Give remaining amount to last recipient to avoid dust
                recipientAmount = remainingYield;
            } else {
                recipientAmount = (availableYield * recipients[i].proportion) / BASIS_POINTS;
                remainingYield -= recipientAmount;
            }

            if (recipientAmount > 0) {
                try staking.transferStake(
                    recipients[i].coldkey, currentValidatorHotkey, netuid, netuid, recipientAmount
                ) {
                    totalTransferred += recipientAmount;
                    emit RecipientTransfer(recipients[i].coldkey, recipientAmount, recipients[i].proportion);
                } catch Error(string memory reason) {
                    emit TransferFailed(recipients[i].coldkey, recipientAmount, reason);
                } catch {
                    emit TransferFailed(recipients[i].coldkey, recipientAmount, "Unknown error");
                }
            }
        }

        // Update tracking
        lastTransferBlock = block.number;
        lastPaymentAmount = totalTransferred;
        previousBalance = _getStakedBalance();

        emit StakeTransferred(totalTransferred, previousBalance);
    }

    /**
     * @notice Check current validator status and switch if necessary
     * @dev Internal function that checks metagraph and moves stake if needed
     */
    function _checkAndSwitchValidator() internal {
        lastValidatorCheckBlock = block.number;

        try metagraph.getValidatorStatus(netuid, currentValidatorUid) returns (bool isValidator) {
            if (!isValidator) {
                // Current validator lost permit, find new one
                _switchToNewValidator("Validator lost permit");
                return;
            }
        } catch {
            emit ValidatorCheckFailed("Failed to check validator status");
            return;
        }

        // Also check if the UID still has the same hotkey
        try metagraph.getHotkey(netuid, currentValidatorUid) returns (bytes32 uidHotkey) {
            if (uidHotkey != currentValidatorHotkey) {
                // UID has different hotkey, need to find new validator
                _switchToNewValidator("Validator UID hotkey mismatch");
                return;
            }
        } catch {
            emit ValidatorCheckFailed("Failed to check UID hotkey");
            return;
        }

        // Check if validator is still active
        try metagraph.getIsActive(netuid, currentValidatorUid) returns (bool isActive) {
            if (!isActive) {
                _switchToNewValidator("Validator is inactive");
                return;
            }
        } catch {
            emit ValidatorCheckFailed("Failed to check validator active status");
        }
    }

    /**
     * @notice Switch to a new validator
     * @param reason The reason for switching
     */
    function _switchToNewValidator(string memory reason) internal {
        bytes32 oldHotkey = currentValidatorHotkey;

        // Find best validator: highest stake + dividend among validators with permits
        uint16 uidCount;
        try metagraph.getUidCount(netuid) returns (uint16 count) {
            uidCount = count;
        } catch {
            emit ValidatorCheckFailed("Failed to get UID count");
            return;
        }

        uint16 bestUid = 0;
        bytes32 bestHotkey;
        uint256 bestScore = 0;
        bool foundValid = false;

        for (uint16 uid = 0; uid < uidCount; uid++) {
            try metagraph.getValidatorStatus(netuid, uid) returns (bool isValidator) {
                if (!isValidator) continue;

                try metagraph.getIsActive(netuid, uid) returns (bool isActive) {
                    if (!isActive) continue;

                    // Get stake and dividend to calculate score
                    uint64 stake = metagraph.getStake(netuid, uid);
                    uint16 dividend = metagraph.getDividends(netuid, uid);

                    // Score = stake * (1 + dividend/65535)
                    // Using dividend as a percentage of max uint16
                    uint256 score = uint256(stake) * (65535 + uint256(dividend)) / 65535;

                    if (score > bestScore) {
                        try metagraph.getHotkey(netuid, uid) returns (bytes32 hotkey) {
                            bestScore = score;
                            bestUid = uid;
                            bestHotkey = hotkey;
                            foundValid = true;
                        } catch {
                            continue;
                        }
                    }
                } catch {
                    continue;
                }
            } catch {
                continue;
            }
        }

        if (!foundValid) {
            emit ValidatorCheckFailed("No valid validator found");
            return;
        }

        // Move stake to new validator
        uint256 currentStake = _getStakedBalance();
        if (currentStake > 0) {
            try staking.moveStake(currentValidatorHotkey, bestHotkey, netuid, netuid, currentStake) {
                currentValidatorHotkey = bestHotkey;
                currentValidatorUid = bestUid;
                emit ValidatorSwitched(oldHotkey, bestHotkey, bestUid, reason);
            } catch {
                emit ValidatorCheckFailed("Failed to move stake to new validator");
            }
        }
    }

    /**
     * @notice Manually trigger validator check and switch
     * @dev Can be called by anyone to force a validator check
     */
    function checkAndSwitchValidator() external {
        _checkAndSwitchValidator();
    }

    /**
     * @notice Request emergency drain with timelock (emergency operator only)
     * @dev Added timelock mechanism for emergency drain
     */
    function requestEmergencyDrain() external onlyEmergencyOperator {
        emergencyDrainRequestedAt = block.timestamp;
        emit EmergencyDrainRequested(block.timestamp + EMERGENCY_TIMELOCK);
    }

    /**
     * @notice Execute emergency drain after timelock expires
     * @dev Can only be executed after timelock period
     */
    function executeEmergencyDrain() external onlyEmergencyOperator nonReentrant {
        if (emergencyDrainRequestedAt == 0) revert NoPendingRequest();
        if (block.timestamp < emergencyDrainRequestedAt + EMERGENCY_TIMELOCK) revert TimelockNotExpired();

        uint256 balance = _getStakedBalance();
        if (balance == 0) revert NoBalance();

        try staking.transferStake(drainSs58Address, currentValidatorHotkey, netuid, netuid, balance) {
            // Reset the request timestamp
            emergencyDrainRequestedAt = 0;
            emit EmergencyDrainExecuted(drainSs58Address, balance);
        } catch {
            revert StakeMoveFailure();
        }
    }

    /**
     * @notice Cancel pending emergency drain request
     * @dev Can be called by anyone to cancel a pending drain after double the timelock period
     */
    function cancelEmergencyDrain() external {
        if (emergencyDrainRequestedAt == 0) revert NoPendingRequest();

        // Allow anyone to cancel if double the timelock has passed (48 hours)
        require(
            msg.sender == emergencyOperator || block.timestamp >= emergencyDrainRequestedAt + (EMERGENCY_TIMELOCK * 2),
            "Not authorized to cancel yet"
        );

        emergencyDrainRequestedAt = 0;
        emit EmergencyDrainCancelled();
    }

    // ========== View Functions ==========

    /**
     * @notice Get the current staked balance
     * @return The total staked balance
     */
    function getStakedBalance() public view returns (uint256) {
        return _getStakedBalance();
    }

    /**
     * @notice Internal helper to get staked balance
     */
    function _getStakedBalance() internal view returns (uint256) {
        return staking.getStake(currentValidatorHotkey, thisSs58PublicKey, netuid);
    }

    /**
     * @notice Get the amount that will be transferred in the next distribution
     * @return The next transfer amount
     */
    function getNextTransferAmount() external view returns (uint256) {
        uint256 currentBalance = _getStakedBalance();
        if (currentBalance <= principalLocked) {
            return 0;
        }
        return currentBalance - principalLocked;
    }

    /**
     * @notice Check if transfer can be executed
     * @return True if transfer conditions are met
     */
    function canExecuteTransfer() public view returns (bool) {
        return block.number >= lastTransferBlock + MIN_BLOCK_INTERVAL;
    }

    /**
     * @notice Get blocks until next transfer is allowed
     * @return Number of blocks remaining
     */
    function blocksUntilNextTransfer() external view returns (uint256) {
        uint256 nextTransferBlock = lastTransferBlock + MIN_BLOCK_INTERVAL;
        if (block.number >= nextTransferBlock) {
            return 0;
        }
        return nextTransferBlock - block.number;
    }

    /**
     * @notice Get available rewards for distribution
     * @return The available yield amount
     */
    function getAvailableRewards() external view returns (uint256) {
        uint256 currentBalance = _getStakedBalance();
        if (currentBalance <= principalLocked) {
            return 0;
        }
        return currentBalance - principalLocked;
    }

    /**
     * @notice Get current validator info
     * @return hotkey The current validator hotkey
     * @return uid The current validator UID
     * @return isValid Whether the current validator still has a permit
     */
    function getCurrentValidatorInfo() external view returns (bytes32 hotkey, uint16 uid, bool isValid) {
        hotkey = currentValidatorHotkey;
        uid = currentValidatorUid;
        try metagraph.getValidatorStatus(netuid, currentValidatorUid) returns (bool status) {
            isValid = status;
        } catch {
            isValid = false;
        }
    }

    /**
     * @notice Get the number of recipients
     * @return The total number of recipients
     */
    function getRecipientCount() external view returns (uint256) {
        return recipients.length;
    }

    /**
     * @notice Get recipient details by index
     * @param index The recipient index
     * @return coldkey The recipient's coldkey
     * @return proportion The recipient's proportion in basis points
     */
    function getRecipient(uint256 index) external view returns (bytes32 coldkey, uint256 proportion) {
        require(index < recipients.length, "Invalid index");
        Recipient memory recipient = recipients[index];
        return (recipient.coldkey, recipient.proportion);
    }

    /**
     * @notice Get all recipients in a single call
     * @dev Gas-efficient way to retrieve all recipients
     * @return coldkeys Array of recipient coldkeys
     * @return proportions Array of recipient proportions
     */
    function getAllRecipients() external view returns (bytes32[] memory coldkeys, uint256[] memory proportions) {
        uint256 length = recipients.length;
        coldkeys = new bytes32[](length);
        proportions = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            coldkeys[i] = recipients[i].coldkey;
            proportions[i] = recipients[i].proportion;
        }

        return (coldkeys, proportions);
    }

    /**
     * @notice Check if emergency drain is pending
     * @return isPending True if emergency drain is pending
     * @return timeRemaining Seconds until drain can be executed (0 if executable)
     */
    function getEmergencyDrainStatus() external view returns (bool isPending, uint256 timeRemaining) {
        isPending = emergencyDrainRequestedAt > 0;
        if (isPending && block.timestamp < emergencyDrainRequestedAt + EMERGENCY_TIMELOCK) {
            timeRemaining = (emergencyDrainRequestedAt + EMERGENCY_TIMELOCK) - block.timestamp;
        } else {
            timeRemaining = 0;
        }
    }
}
