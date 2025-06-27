# SaintDurbin Integration Tests

This directory contains live integration tests for the SaintDurbin contract that interact with a running subtensor chain.

## Quick Start

The test runner script handles all setup automatically:

```bash
# Run all tests (automatically starts chain, installs deps, compiles contracts)
./run-tests.sh

# Run specific test suite
./run-tests.sh deployment
./run-tests.sh transfer
./run-tests.sh validator
./run-tests.sh emergency
```

## Manual Setup (Optional)

If you prefer to manage the setup manually:

1. **Start Subtensor Chain**: 
   ```bash
   cd subtensor_chain
   ./scripts/localnet.sh
   ```

2. **Compile Contracts**: 
   ```bash
   forge build
   ```

3. **Install Dependencies**: 
   ```bash
   cd test/integration
   npm install
   ```

4. **Run Tests with --no-auto-start flag**:
   ```bash
   ./run-tests.sh all --no-auto-start
   ```

## Test Runner Features

The `run-tests.sh` script provides:

- **Automatic Chain Management**: Starts local subtensor if not running
- **Dependency Installation**: Installs all npm dependencies automatically
- **Contract Compilation**: Compiles Solidity contracts before testing
- **Cleanup on Exit**: Stops the chain when tests complete
- **Progress Tracking**: Shows status of each setup step

### Options

- `--no-auto-start`: Disable automatic chain startup (useful if managing chain manually)

## Test Structure

### Main Test File
- `SaintDurbin.integration.test.ts` - Contains all integration tests organized by feature:
  - Contract Deployment
  - Yield Distribution
  - Validator Switching
  - Emergency Drain
  - Principal Detection

### Helper Functions
- `helpers/saintDurbinHelpers.ts` - Utility functions for:
  - Waiting for blocks
  - Getting validator information
  - Calculating expected distributions
  - Simulating yield generation
  - Verifying recipient balances
  - Fast-forwarding time for timelocks
  - Setting up test environments

## Test Scenarios

### 1. Contract Deployment
- Deploys SaintDurbin with 16 recipients
- Verifies all parameters are set correctly
- Checks initial stake balance equals principal

### 2. Yield Distribution
- Waits for yield generation
- Executes transfer when conditions are met
- Verifies recipients receive correct proportions
- Checks events are emitted properly

### 3. Validator Switching
- Removes current validator's permit
- Triggers validator check
- Verifies contract switches to new validator
- Confirms stake is moved to new validator

### 4. Emergency Drain
- Tests timelock mechanism
- Verifies drain cannot execute before timelock
- Tests cancellation functionality
- Checks proper access control

### 5. Principal Detection
- Adds additional stake (simulating principal)
- Executes transfer
- Verifies principal detection logic
- Confirms principal is preserved

## Configuration

The tests use the following configuration:
- 16 recipients with 6.25% proportion each
- 24-hour minimum block interval (7200 blocks)
- 1 TAO existential amount threshold
- 24-hour emergency drain timelock

## Troubleshooting

### Chain Connection Issues
- Ensure the subtensor chain is running on `http://127.0.0.1:8545`
- Check that the chain has EVM support enabled

### Test Timeouts
- Integration tests can take time due to block confirmation
- Increase timeout in package.json if needed

### Missing Dependencies
- Run `npm install` in the integration test directory
- Ensure the subtensor_chain directory has its dependencies installed

## Writing New Tests

When adding new integration tests:

1. Use the helper functions for common operations
2. Always clean up test state in `afterEach` hooks
3. Use meaningful timeout values for async operations
4. Verify both on-chain state and contract events
5. Test both success and failure scenarios

Example:
```typescript
it("Should handle new scenario", async function() {
    this.timeout(60000); // Set appropriate timeout
    
    // Setup
    const initialState = await contract.someGetter();
    
    // Action
    const tx = await contract.someAction();
    const receipt = await tx.wait();
    
    // Verify
    expect(receipt.status).to.equal(1);
    const newState = await contract.someGetter();
    expect(newState).to.not.equal(initialState);
});