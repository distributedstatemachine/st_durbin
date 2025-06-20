# SaintDurbin Technical Specification
## Patron Saint of Bittensor - Automatic Yield Distribution with Validator Management

### Table of Contents
1. [Executive Summary](#executive-summary)
2. [System Architecture](#system-architecture)
3. [Contract Overview](#contract-overview)
4. [Core Functionality](#core-functionality)
5. [Security Model](#security-model)
6. [Technical Implementation](#technical-implementation)
7. [Testing Strategy](#testing-strategy)
8. [Deployment & Operations](#deployment--operations)
9. [Risk Analysis](#risk-analysis)
10. [Audit Scope](#audit-scope)

---

## Executive Summary

SaintDurbin is a smart contract designed for the Bittensor EVM network (Subtensor) that manages staking yields distribution to 16 recipients while preserving the principal amount. The contract implements automatic validator switching to maintain optimal staking returns and includes comprehensive security features.

### Key Features:
- **Immutable recipient configuration** with fixed proportions totaling 10,000 basis points
- **Automatic validator management** with fallback mechanisms
- **Principal protection** through rate analysis and yield tracking
- **Emergency drain mechanism** with 24-hour timelock and multisig control
- **Daily distribution enforcement** (7,200 block minimum interval)
- **Reentrancy protection** on critical functions

### Contract Address: `SaintDurbin.sol`
### Deployment Network: Bittensor EVM (Subtensor)
### Solidity Version: 0.8.20
### License: GPL-3.0

---

## System Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Bittensor Subtensor                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌──────────────────┐          ┌──────────────────┐             │
│  │  IStaking (0x805) │          │ IMetagraph (0x802)│             │
│  │                  │          │                   │             │
│  │ - addStake()     │          │ - getUidCount()   │             │
│  │ - removeStake()  │          │ - getStake()      │             │
│  │ - moveStake()    │          │ - getValidatorStatus()          │
│  │ - transferStake()│          │ - getHotkey()     │             │
│  │ - getStake()     │          │ - getDividends()  │             │
│  └──────────────────┘          └──────────────────┘             │
│           ▲                              ▲                       │
│           │                              │                       │
│  ┌────────┴──────────────────────────────┴────────────┐         │
│  │                 SaintDurbin Contract                │         │
│  │                                                     │         │
│  │  State Variables:                                   │         │
│  │  - currentValidatorHotkey (mutable)                 │         │
│  │  - recipients[] (immutable)                         │         │
│  │  - principalLocked                                  │         │
│  │  - emergencyOperator (immutable)                    │         │
│  │                                                     │         │
│  │  Core Functions:                                    │         │
│  │  - executeTransfer()                                │         │
│  │  - checkAndSwitchValidator()                        │         │
│  │  - requestEmergencyDrain()                          │         │
│  │  - executeEmergencyDrain()                          │         │
│  └─────────────────────────────────────────────────────┘         │
│                              ▲                                   │
│                              │                                   │
│  ┌───────────────────────────┴─────────────────────────┐         │
│  │           External Callers & Automation             │         │
│  │                                                     │         │
│  │  - GitHub Actions (daily cron)                      │         │
│  │  - Emergency Operator                               │         │
│  │  - Public (anyone can trigger distribution)         │         │
│  └─────────────────────────────────────────────────────┘         │
└─────────────────────────────────────────────────────────────────┘
```

### Precompile Interfaces

The contract interfaces with two Bittensor precompiles:

1. **IStaking (0x805)**: Manages staking operations
   - `addStake()`: Add stake to a validator
   - `removeStake()`: Remove stake from a validator
   - `moveStake()`: Move stake between validators
   - `transferStake()`: Transfer stake to another coldkey
   - `getStake()`: Query stake amount

2. **IMetagraph (0x802)**: Queries network metadata
   - `getValidatorStatus()`: Check if UID has validator permit
   - `getIsActive()`: Check if validator is active
   - `getHotkey()`: Get hotkey for a UID
   - `getStake()`: Get stake amount for a UID
   - `getDividends()`: Get dividend rate for a UID

---

## Contract Overview

### State Variables

```solidity
// Core Configuration (Immutable)
IStaking public immutable staking;              // 0x805 precompile
IMetagraph public immutable metagraph;          // 0x802 precompile
bytes32 public immutable thisSs58PublicKey;     // Contract's SS58 public key
uint16 public immutable netuid;                 // Subnet ID for operations
address public immutable emergencyOperator;     // Emergency drain initiator
bytes32 public immutable drainSs58Address;      // Emergency drain destination

// Mutable State
bytes32 public currentValidatorHotkey;          // Current validator (can change)
uint16 public currentValidatorUid;              // Current validator UID
uint256 public principalLocked;                 // Protected principal amount
uint256 public emergencyDrainRequestedAt;       // Timelock timestamp

// Tracking Variables
uint256 public previousBalance;                 // Balance at last check
uint256 public lastTransferBlock;               // Block of last distribution
uint256 public lastRewardRate;                  // Reward rate tracking
uint256 public lastPaymentAmount;               // Last distribution amount
uint256 public lastValidatorCheckBlock;         // Last validator check
uint256 public cumulativeBalanceIncrease;       // Cumulative balance tracking
uint256 public lastBalanceCheckBlock;           // Last balance check block

// Recipients Array
Recipient[] public recipients;                  // 16 recipients with proportions

// Constants
uint256 constant MIN_BLOCK_INTERVAL = 7200;     // ~24 hours at 12s blocks
uint256 constant EXISTENTIAL_AMOUNT = 1e9;      // 1 TAO minimum
uint256 constant BASIS_POINTS = 10000;          // 100%
uint256 constant RATE_MULTIPLIER_THRESHOLD = 2; // Principal detection threshold
uint256 constant EMERGENCY_TIMELOCK = 86400;    // 24 hours in seconds
```

### Recipient Structure

```solidity
struct Recipient {
    bytes32 coldkey;      // SS58 public key of recipient
    uint256 proportion;   // Basis points (out of 10,000)
}
```

### Distribution Configuration

Total 16 recipients with proportions summing to exactly 10,000 basis points:
- Sam: 100 (1%)
- WSL: 100 (1%)
- Paper: 500 (5%)
- Florian: 100 (1%)
- 3 wallets: 100 each (1% each)
- 3 wallets: 300 each (3% each)
- 3 wallets: 1000 each (10% each)
- 2 wallets: 1500 each (15% each)
- 1 wallet: 2000 (20%)

---

## Core Functionality

### 1. Yield Distribution (`executeTransfer()`)

The primary function that distributes staking yields to recipients.

**Process Flow:**
1. Check minimum block interval (7,200 blocks)
2. Verify and potentially switch validator (every 100 blocks)
3. Calculate available yield (current balance - principal)
4. Detect principal additions through rate analysis
5. Distribute yield proportionally to all recipients
6. Update tracking variables

**Principal Detection Algorithm:**
```solidity
// Calculate current reward rate
uint256 currentRate = (availableYield * 1e18) / blocksSinceLastTransfer;

// Detect principal addition
bool rateBasedDetection = lastRewardRate > 0 && 
                         currentRate > lastRewardRate * RATE_MULTIPLIER_THRESHOLD;
bool absoluteDetection = availableYield > lastPaymentAmount * 3;

if (rateBasedDetection || absoluteDetection) {
    // Principal detected - adjust and use previous payment amount
    uint256 detectedPrincipal = availableYield - lastPaymentAmount;
    principalLocked += detectedPrincipal;
    availableYield = lastPaymentAmount;
}
```

### 2. Validator Management

**Automatic Switching (`_checkAndSwitchValidator()`):**
- Called automatically during `executeTransfer()` every 100 blocks
- Can be manually triggered via `checkAndSwitchValidator()`

**Switch Triggers:**
1. Current validator loses permit (`getValidatorStatus() == false`)
2. Validator becomes inactive (`getIsActive() == false`)
3. Hotkey/UID mismatch detected

**Selection Algorithm:**
```solidity
// Score = stake * (1 + dividend/65535)
uint256 score = uint256(stake) * (65535 + uint256(dividend)) / 65535;
```

**Reentrancy Protection:**
- State updated before external calls
- Rollback on failure

### 3. Emergency Drain Mechanism

**Three-Stage Process:**

1. **Request Stage** (`requestEmergencyDrain()`):
   - Only callable by `emergencyOperator`
   - Sets `emergencyDrainRequestedAt = block.timestamp`
   - Emits `EmergencyDrainRequested` event

2. **Execution Stage** (`executeEmergencyDrain()`):
   - Requires 24-hour timelock expiry
   - Transfers entire balance to `drainSs58Address`
   - Resets request timestamp
   - Protected by `nonReentrant` modifier

3. **Cancellation** (`cancelEmergencyDrain()`):
   - Emergency operator can cancel anytime
   - Anyone can cancel after 48 hours
   - Resets request timestamp

---

## Security Model

### 1. Access Control

- **No Owner/Admin**: Contract is largely autonomous
- **Emergency Operator**: Limited to emergency drain functions
- **Public Functions**: `executeTransfer()` and `checkAndSwitchValidator()`
- **Immutable Configuration**: Recipients and proportions cannot be changed

### 2. Reentrancy Protection

Applied to critical functions:
- `executeTransfer()`: Protected with `nonReentrant` modifier
- `executeEmergencyDrain()`: Protected with `nonReentrant` modifier
- Validator switching: Uses checks-effects-interactions pattern

### 3. Principal Protection Mechanisms

1. **Rate Analysis**: Detects sudden balance increases
2. **Threshold Detection**: 2x rate change triggers principal lock
3. **Absolute Detection**: 3x previous payment comparison
4. **Fallback Mechanism**: Uses last payment amount when no new yield

### 4. Validator Security

- Automatic monitoring every 100 blocks
- Multiple validation checks before switching
- Score-based selection for optimal validator
- State rollback on failed switches

### 5. Emergency Drain Security

- 24-hour timelock prevents immediate drainage
- Drain address maps to 2/3 Polkadot multisig
- Cannot be executed from EVM side alone
- Cancellation mechanism prevents lockout

---

## Technical Implementation

### Critical Functions Analysis

#### `executeTransfer()`
```solidity
function executeTransfer() external nonReentrant {
    // 1. Time check
    if (!canExecuteTransfer()) revert TransferTooSoon();
    
    // 2. Validator check (every 100 blocks)
    if (block.number >= lastValidatorCheckBlock + 100) {
        _checkAndSwitchValidator();
    }
    
    // 3. Yield calculation with principal protection
    uint256 currentBalance = _getStakedBalance();
    uint256 availableYield = calculateYield(currentBalance);
    
    // 4. Distribution to recipients
    distributeYield(availableYield);
    
    // 5. State updates
    updateTrackingVariables();
}
```

#### `_switchToNewValidator()`
```solidity
function _switchToNewValidator(string memory reason) internal {
    // 1. Find best validator by score
    (uint16 bestUid, bytes32 bestHotkey) = findBestValidator();
    
    // 2. Update state BEFORE external call
    bytes32 previousHotkey = currentValidatorHotkey;
    currentValidatorHotkey = bestHotkey;
    currentValidatorUid = bestUid;
    
    // 3. Execute stake move
    try staking.moveStake(previousHotkey, bestHotkey, netuid, netuid, balance) {
        emit ValidatorSwitched(previousHotkey, bestHotkey, bestUid, reason);
    } catch {
        // 4. Revert state on failure
        currentValidatorHotkey = previousHotkey;
        currentValidatorUid = previousUid;
        emit ValidatorCheckFailed("Failed to move stake");
    }
}
```

### Gas Optimization Strategies

1. **Cached Array Length**: Avoids repeated SLOAD operations
2. **Validator Check Interval**: Only every 100 blocks
3. **Batch State Updates**: Minimize storage writes
4. **Event-Based Monitoring**: Off-chain tracking via events

### Error Handling

Custom errors for gas efficiency:
```solidity
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
```

---

## Testing Strategy

### 1. Unit Tests (Foundry)

**Test Coverage:**
- Constructor validation and initialization
- Distribution logic and proportion accuracy
- Principal detection and protection
- Validator switching scenarios
- Emergency drain mechanism
- View function accuracy
- Edge cases and error conditions

**Test Files:**
- `SaintDurbin.t.sol`: Core functionality
- `SaintDurbinPrincipal.t.sol`: Principal protection
- `SaintDurbinEmergency.t.sol`: Emergency mechanisms
- `SaintDurbinValidatorSwitch.t.sol`: Validator management
- `SaintDurbin_ConstructorTests.sol`: Deployment validation

### 2. Integration Tests

**Local Subtensor Chain:**
- Uses git submodule for `opentensor/subtensor`
- Deploys contract to local chain
- Tests JavaScript automation scripts
- Validates validator switching with real precompiles

**Test Scenarios:**
- Distribution execution via scripts
- Validator status changes and switching
- Multiple distribution cycles
- Emergency drain workflow

### 3. Security Testing

**Static Analysis:**
- Slither for vulnerability detection
- Aderyn for additional security checks
- Manual review of critical paths

**Dynamic Testing:**
- Reentrancy attack scenarios
- Principal manipulation attempts
- Validator switching edge cases
- Timelock bypass attempts

---

## Deployment & Operations

### Deployment Process

1. **Environment Setup:**
   ```bash
   cp .env.example .env
   # Configure all parameters
   ```

2. **Configuration Validation:**
   - Verify recipient addresses and proportions sum to 10,000
   - Confirm emergency operator and drain addresses
   - Validate initial validator hotkey and UID

3. **Deployment Script:**
   ```bash
   forge script script/DeploySaintDurbin.s.sol:DeploySaintDurbin \
     --rpc-url $BITTENSOR_RPC_URL \
     --private-key $PRIVATE_KEY \
     --broadcast \
     --verify
   ```

4. **Post-Deployment Verification:**
   - Confirm initial principal amount
   - Verify all immutable parameters
   - Test view functions

### Operational Procedures

**Daily Operations:**
- GitHub Actions cron job triggers `distribute.js`
- Script checks `canExecuteTransfer()`
- Executes distribution if conditions met
- Logs events and updates

**Monitoring:**
- Event monitoring for distributions
- Validator status tracking
- Principal amount verification
- Emergency drain status

**Emergency Procedures:**
1. Emergency operator initiates drain request
2. Wait 24-hour timelock
3. Execute drain to multisig address
4. Multisig executes on Polkadot side

---

## Risk Analysis

### Technical Risks

1. **Precompile Dependency**
   - Risk: Precompile interface changes
   - Mitigation: Immutable interfaces, comprehensive testing

2. **Validator Availability**
   - Risk: No valid validators available
   - Mitigation: Fallback to last payment amount, manual intervention

3. **Principal Detection False Positives**
   - Risk: Legitimate yield detected as principal
   - Mitigation: Conservative thresholds, manual review capability

### Operational Risks

1. **Key Management**
   - Risk: Emergency operator key compromise
   - Mitigation: 24-hour timelock, multisig control, cancellation mechanism

2. **Distribution Failures**
   - Risk: Individual recipient transfer failures
   - Mitigation: Continue distribution to other recipients, emit failure events

3. **Validator Switching Failures**
   - Risk: Unable to switch to new validator
   - Mitigation: State rollback, manual intervention capability

### Economic Risks

1. **Yield Variability**
   - Risk: Inconsistent staking rewards
   - Mitigation: Fallback mechanisms, rate tracking

2. **Gas Costs**
   - Risk: High gas costs for operations
   - Mitigation: Gas optimizations, batched operations

---

## Audit Scope

### In Scope

1. **Smart Contracts:**
   - `src/SaintDurbin.sol`
   - `src/interfaces/IStakingV2.sol`
   - `src/interfaces/IMetagraph.sol`

2. **Core Functionality:**
   - Yield distribution mechanism
   - Principal protection logic
   - Validator switching algorithm
   - Emergency drain mechanism
   - Access control implementation

3. **Security Features:**
   - Reentrancy protection
   - Input validation
   - State consistency
   - Error handling

### Out of Scope

1. **External Components:**
   - Bittensor precompile implementations
   - Polkadot multisig mechanism
   - GitHub Actions automation

2. **Deployment Scripts:**
   - JavaScript automation scripts
   - Deployment configuration

### Key Areas for Review

1. **Principal Protection:**
   - Rate analysis algorithm correctness
   - Threshold appropriateness
   - Edge case handling

2. **Validator Management:**
   - Selection algorithm security
   - State consistency during switches
   - Failure recovery mechanisms

3. **Distribution Logic:**
   - Proportion calculation accuracy
   - Rounding error handling
   - Gas optimization impact

4. **Emergency Mechanism:**
   - Timelock bypass possibilities
   - Access control effectiveness
   - State management during emergency

### Recommended Audit Tests

1. **Fuzzing:**
   - Distribution amounts
   - Block intervals
   - Validator scores
   - Principal detection thresholds

2. **Invariant Testing:**
   - Principal never decreases
   - Proportions always sum to 10,000
   - Recipients always receive correct amounts
   - Validator state consistency

3. **Attack Scenarios:**
   - Reentrancy attempts
   - Principal extraction attempts
   - Validator manipulation
   - Timelock bypass attempts

---

## Appendix

### Event Definitions

```solidity
event StakeTransferred(uint256 totalAmount, uint256 newBalance);
event RecipientTransfer(bytes32 indexed coldkey, uint256 amount, uint256 proportion);
event PrincipalDetected(uint256 amount, uint256 totalPrincipal);
event EmergencyDrainExecuted(bytes32 indexed drainAddress, uint256 amount);
event TransferFailed(bytes32 indexed coldkey, uint256 amount, string reason);
event EmergencyDrainRequested(uint256 executionTime);
event EmergencyDrainCancelled();
event ValidatorSwitched(bytes32 indexed oldHotkey, bytes32 indexed newHotkey, uint16 newUid, string reason);
event ValidatorCheckFailed(string reason);
```

### View Functions

```solidity
function getStakedBalance() public view returns (uint256)
function getNextTransferAmount() external view returns (uint256)
function canExecuteTransfer() public view returns (bool)
function blocksUntilNextTransfer() external view returns (uint256)
function getAvailableRewards() external view returns (uint256)
function getCurrentValidatorInfo() external view returns (bytes32, uint16, bool)
function getRecipientCount() external view returns (uint256)
function getRecipient(uint256 index) external view returns (bytes32, uint256)
function getAllRecipients() external view returns (bytes32[] memory, uint256[] memory)
function getEmergencyDrainStatus() external view returns (bool, uint256)
```

### External Dependencies

1. **Bittensor Precompiles:**
   - IStaking (0x805): Staking operations
   - IMetagraph (0x802): Network metadata

2. **External Automation:**
   - GitHub Actions for daily distribution
   - Monitoring services for events

3. **Multisig Control:**
   - Polkadot 2/3 multisig for emergency drain execution

---

*End of Technical Specification*