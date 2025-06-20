# SaintDurbin Audit Guide

## Quick Start for Auditors

This guide provides a focused overview for security auditors reviewing the SaintDurbin smart contract system.

### Contract Overview

**Purpose**: Distribute Bittensor staking yields to 16 fixed recipients while protecting principal and managing validator selection.

**Key Contract**: `src/SaintDurbin.sol` (567 lines)
**Network**: Bittensor EVM (Subtensor)
**Dependencies**: Two precompile interfaces at fixed addresses

### Critical Security Features

1. **No Admin Functions**: Contract is largely autonomous post-deployment
2. **Immutable Recipients**: 16 recipients with fixed proportions (cannot be changed)
3. **Principal Protection**: Multiple mechanisms to prevent principal distribution
4. **Validator Management**: Automatic switching with state rollback on failure
5. **Emergency Drain**: 24-hour timelock with multisig destination

### High-Risk Areas to Review

#### 1. Principal Protection Logic (Lines 178-209)
```solidity
// Rate-based detection
bool rateBasedDetection = lastRewardRate > 0 && 
                         currentRate * 1 > lastRewardRate * RATE_MULTIPLIER_THRESHOLD;

// Absolute detection  
bool absoluteDetection = availableYield > lastPaymentAmount * 3;

if (rateBasedDetection || absoluteDetection) {
    // Lock additional principal
    principalLocked += (availableYield - lastPaymentAmount);
    availableYield = lastPaymentAmount;
}
```

**Audit Focus**: 
- Can principal be extracted through manipulation?
- Are detection thresholds appropriate?
- Edge cases around first distribution

#### 2. Validator Switching (Lines 307-380)
```solidity
// State updated BEFORE external call
currentValidatorHotkey = bestHotkey;
currentValidatorUid = bestUid;

try staking.moveStake(previousHotkey, bestHotkey, netuid, netuid, currentStake) {
    emit ValidatorSwitched(oldHotkey, bestHotkey, bestUid, reason);
} catch {
    // Rollback on failure
    currentValidatorHotkey = previousHotkey;
    currentValidatorUid = previousUid;
}
```

**Audit Focus**:
- Reentrancy during validator switch
- State consistency on failures
- DoS through validator manipulation

#### 3. Distribution Logic (Lines 227-251)
```solidity
for (uint256 i = 0; i < recipientsLength; i++) {
    if (i == recipientsLength - 1) {
        // Last recipient gets remainder (dust handling)
        recipientAmount = remainingYield;
    } else {
        recipientAmount = (availableYield * recipients[i].proportion) / BASIS_POINTS;
        remainingYield -= recipientAmount;
    }
    // Transfer with try/catch
}
```

**Audit Focus**:
- Rounding errors
- Failed transfer handling
- Gas optimization impact

#### 4. Emergency Drain (Lines 394-437)
```solidity
// Three-stage process:
// 1. Request (sets timestamp)
// 2. Wait 24 hours
// 3. Execute (or cancel)

// State updated BEFORE external call
emergencyDrainRequestedAt = 0;

try staking.transferStake(drainSs58Address, currentValidatorHotkey, netuid, netuid, balance) {
    emit EmergencyDrainExecuted(drainSs58Address, balance);
} catch {
    // Restore timestamp on failure
    emergencyDrainRequestedAt = block.timestamp - EMERGENCY_TIMELOCK;
    revert StakeMoveFailure();
}
```

**Audit Focus**:
- Timelock bypass possibilities
- Timestamp manipulation
- State handling on failure

### Testing Instructions

```bash
# Clone with submodules
git clone --recursive https://github.com/distributedstatemachine/st_durbin
cd st_durbin

# Run all tests
forge test -vvv

# Run specific security tests
forge test --match-contract SaintDurbinEmergency -vvv
forge test --match-contract SaintDurbinPrincipal -vvv
forge test --match-contract SaintDurbinValidatorSwitch -vvv

# Gas analysis
forge test --gas-report

# Coverage
forge coverage

# Static analysis
slither src/SaintDurbin.sol
```

### Key Invariants to Verify

1. **Principal Never Decreases**
   ```solidity
   assert(principalLocked >= initialPrincipal)
   ```

2. **Proportions Sum to 10,000**
   ```solidity
   assert(sumOfProportions == BASIS_POINTS)
   ```

3. **Distribution Interval Enforced**
   ```solidity
   assert(block.number >= lastTransferBlock + MIN_BLOCK_INTERVAL)
   ```

4. **Emergency Drain Timelock**
   ```solidity
   assert(block.timestamp >= emergencyDrainRequestedAt + EMERGENCY_TIMELOCK)
   ```

### External Dependencies

1. **IStaking (0x805)**: Precompile for staking operations
   - `moveStake()`: Used for validator switching
   - `transferStake()`: Used for distributions
   - `getStake()`: Used for balance queries

2. **IMetagraph (0x802)**: Precompile for network metadata
   - `getValidatorStatus()`: Check validator permits
   - `getIsActive()`: Check validator activity
   - `getHotkey()`: Get validator identifiers

### Attack Vectors to Test

1. **Reentrancy Attacks**
   - During distribution
   - During validator switching
   - During emergency drain

2. **Principal Extraction**
   - Rate manipulation
   - First distribution edge case
   - Integer overflow/underflow

3. **DoS Attacks**
   - Validator unavailability
   - Failed transfers
   - Gas exhaustion

4. **Access Control**
   - Emergency operator privileges
   - Public function abuse
   - Timelock manipulation

### Recommended Fuzzing Targets

```solidity
// Fuzz distribution amounts
function testFuzz_Distribution(uint256 amount) public {
    // Bound: EXISTENTIAL_AMOUNT to reasonable max
    amount = bound(amount, EXISTENTIAL_AMOUNT, 1000000e9);
    // Test distribution logic
}

// Fuzz validator scores
function testFuzz_ValidatorSelection(uint64 stake, uint16 dividend) public {
    // Test selection algorithm
}

// Fuzz time intervals
function testFuzz_BlockIntervals(uint256 blocks) public {
    blocks = bound(blocks, 1, MIN_BLOCK_INTERVAL * 2);
    // Test timing constraints
}
```

### Quick Security Checklist

- [ ] No owner/admin functions that can change critical parameters
- [ ] Recipients and proportions are immutable
- [ ] Principal can only increase, never decrease
- [ ] Validator switching has proper state management
- [ ] Emergency drain has 24-hour timelock
- [ ] All external calls have reentrancy protection
- [ ] Failed transfers don't block other recipients
- [ ] Gas optimization doesn't compromise security
- [ ] Events provide sufficient monitoring capability
- [ ] No reliance on block.timestamp for critical logic (except timelock)

### Additional Resources

- [Full Technical Specification](./SPEC.md)
- [Detailed README](./README.md)
- [Test Suite Documentation](./test/README.md)
- [Bittensor Precompile Docs](https://docs.bittensor.com)

---

*This guide is specifically prepared for the security audit of SaintDurbin v1.0*