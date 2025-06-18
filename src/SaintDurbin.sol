// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "./interfaces/IStakingV2.sol";

/**
 * @title SaintDurbin
 * @notice Patron Saint of Bittensor
 * @dev Distributes staking rewards to recipients while preserving the principal amount
 */
contract SaintDurbin {
    // ========== Constants ==========
    address constant ISTAKING_ADDRESS = address(0x808);
    uint256 constant MIN_BLOCK_INTERVAL = 7200; // ~24 hours at 12s blocks
    uint256 constant EXISTENTIAL_AMOUNT = 1e9; // 1 TAO in rao (9 decimals)
    uint256 constant BASIS_POINTS = 10000;
    uint256 constant RATE_MULTIPLIER_THRESHOLD = 2;
    uint256 constant MIN_VALIDATOR_STAKE = 1000e9; // 1000 TAO

    // ========== State Variables ==========
    
    // Core configuration
    IStakingV2 public immutable staking;
    bytes32 public validatorHotkey;
    bytes32 public thisSs58PublicKey;
    uint16 public immutable netuid;
    address public immutable owner;
    
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
    bool public ss58KeySet;
    
    // Emergency drain
    address public immutable emergencyOperator;
    bytes32 public immutable drainSs58Address;
    
    // ========== Events ==========
    event StakeTransferred(uint256 totalAmount, uint256 newBalance);
    event RecipientTransfer(bytes32 indexed coldkey, uint256 amount, uint256 proportion);
    event PrincipalDetected(uint256 amount, uint256 totalPrincipal);
    event ValidatorHotkeyChanged(bytes32 indexed oldHotkey, bytes32 indexed newHotkey);
    event EmergencyDrainExecuted(bytes32 indexed drainAddress, uint256 amount);
    event TransferFailed(bytes32 indexed coldkey, uint256 amount, string reason);
    event Ss58PublicKeySet(bytes32 publicKey);
    
    // ========== Modifiers ==========
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }
    
    modifier onlyEmergencyOperator() {
        require(msg.sender == emergencyOperator, "Only emergency operator");
        _;
    }
    
    // ========== Constructor ==========
    constructor(
        address _owner,
        address _emergencyOperator,
        bytes32 _drainSs58Address,
        bytes32 _validatorHotkey,
        uint16 _netuid,
        bytes32[] memory _recipientColdkeys,
        uint256[] memory _proportions
    ) {
        require(_owner != address(0), "Invalid owner");
        require(_emergencyOperator != address(0), "Invalid emergency operator");
        require(_drainSs58Address != bytes32(0), "Invalid drain address");
        require(_validatorHotkey != bytes32(0), "Invalid validator hotkey");
        require(_recipientColdkeys.length == _proportions.length, "Mismatched arrays");
        require(_recipientColdkeys.length == 16, "Must have 16 recipients");
        
        owner = _owner;
        emergencyOperator = _emergencyOperator;
        drainSs58Address = _drainSs58Address;
        validatorHotkey = _validatorHotkey;
        netuid = _netuid;
        staking = IStakingV2(ISTAKING_ADDRESS);
        
        // Validate proportions sum to 10000
        uint256 totalProportions = 0;
        for (uint256 i = 0; i < _proportions.length; i++) {
            require(_recipientColdkeys[i] != bytes32(0), "Invalid recipient");
            require(_proportions[i] > 0, "Invalid proportion");
            totalProportions += _proportions[i];
            
            recipients.push(Recipient({
                coldkey: _recipientColdkeys[i],
                proportion: _proportions[i]
            }));
        }
        require(totalProportions == BASIS_POINTS, "Proportions must sum to 10000");
        
        // Initialize tracking
        lastTransferBlock = block.number;
        // Principal will be set when SS58 key is configured
        principalLocked = 0;
        previousBalance = 0;
    }
    
    // ========== Core Functions ==========
    
    /**
     * @notice Execute daily yield distribution to all recipients
     * @dev Can be called by anyone when conditions are met
     */
    function executeTransfer() external {
        require(canExecuteTransfer(), "Cannot execute transfer yet");
        
        uint256 currentBalance = getStakedBalance();
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
        
        // Rate analysis for principal detection
        if (lastPaymentAmount > 0 && previousBalance > 0 && currentBalance > principalLocked) {
            uint256 blocksSinceLastTransfer = block.number - lastTransferBlock;
            uint256 currentRate = (availableYield * 1e18) / blocksSinceLastTransfer;
            
            if (lastRewardRate > 0 && currentRate > lastRewardRate * RATE_MULTIPLIER_THRESHOLD) {
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
        
        // Check if yield is below existential amount
        if (availableYield < EXISTENTIAL_AMOUNT) {
            lastTransferBlock = block.number;
            previousBalance = currentBalance;
            return;
        }
        
        // Calculate and execute transfers
        uint256 totalTransferred = 0;
        
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 recipientAmount = (availableYield * recipients[i].proportion) / BASIS_POINTS;
            
            if (recipientAmount > 0) {
                try staking.transferStake(
                    thisSs58PublicKey,
                    recipients[i].coldkey,
                    recipientAmount,
                    netuid
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
        previousBalance = getStakedBalance();
        
        emit StakeTransferred(totalTransferred, previousBalance);
    }

    /**
     * @notice Change the validator hotkey (owner only)
     * @param newHotkey The new validator hotkey
     */
    function changeValidatorHotkey(bytes32 newHotkey) external onlyOwner {
        require(newHotkey != bytes32(0), "Invalid hotkey");
        require(isValidator(newHotkey), "Not a validator");
        
        bytes32 oldHotkey = validatorHotkey;
        validatorHotkey = newHotkey;
        
        emit ValidatorHotkeyChanged(oldHotkey, newHotkey);
    }
    
    /**
     * @notice Set the contract's SS58 public key (owner only, one-time)
     * @param publicKey The SS58 public key for this contract
     */
    function setThisSs58PublicKey(bytes32 publicKey) external onlyOwner {
        require(!ss58KeySet, "SS58 key already set");
        require(publicKey != bytes32(0), "Invalid public key");
        
        thisSs58PublicKey = publicKey;
        ss58KeySet = true;
        
        // Initialize principal with current balance
        principalLocked = getStakedBalance();
        previousBalance = principalLocked;
        
        emit Ss58PublicKeySet(publicKey);
    }
    
    /**
     * @notice Emergency drain entire balance to designated address
     * @dev Only callable by emergency operator
     */
    function emergencyDrain() external onlyEmergencyOperator {
        uint256 balance = getStakedBalance();
        require(balance > 0, "No balance to drain");
        
        staking.transferStake(
            thisSs58PublicKey,
            drainSs58Address,
            balance,
            netuid
        );
        
        emit EmergencyDrainExecuted(drainSs58Address, balance);
    }
    
    // ========== View Functions ==========
    
    /**
     * @notice Get the current staked balance
     * @return The total staked balance
     */
    function getStakedBalance() public view returns (uint256) {
        return staking.getStake(thisSs58PublicKey, validatorHotkey, netuid);
    }
    
    /**
     * @notice Get the amount that will be transferred in the next distribution
     * @return The next transfer amount
     */
    function getNextTransferAmount() external view returns (uint256) {
        uint256 currentBalance = getStakedBalance();
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
        return block.number >= lastTransferBlock + MIN_BLOCK_INTERVAL && ss58KeySet;
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
        uint256 currentBalance = getStakedBalance();
        if (currentBalance <= principalLocked) {
            return 0;
        }
        return currentBalance - principalLocked;
    }
    
    /**
     * @notice Check if a hotkey is a validator
     * @param hotkey The hotkey to check
     * @return True if the hotkey is a validator
     */
    function isValidator(bytes32 hotkey) public view returns (bool) {
        uint256 totalStake = staking.getTotalStake(hotkey, netuid);
        return totalStake >= MIN_VALIDATOR_STAKE;
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
}
