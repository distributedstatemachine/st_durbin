#!/bin/bash

# SaintDurbin Integration Test Runner
# This script manages the full integration test lifecycle:
# 1. Starts a local Subtensor chain
# 2. Deploys the SaintDurbin contract
# 3. Runs JavaScript integration tests
# 4. Cleans up resources

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SUBTENSOR_DIR="${SCRIPT_DIR}/subtensor_chain"
LOCALNET_PID_FILE="${SCRIPT_DIR}/.localnet.pid"
DEPLOYED_ADDRESS_FILE="${SCRIPT_DIR}/.deployed_address"
export RPC_URL="http://127.0.0.1:9944"
export CHAIN_ENDPOINT="ws://127.0.0.1:9944"

# Test accounts (standard development accounts)
export DEPLOYER_PRIVATE_KEY="0x5fb92d6e98884f76de468fa3f6278f8807c48bebc13595d45af5bdc4da702133" # Alice
export TEST_PRIVATE_KEY_1="0x8075991ce870b93a8870eca0c0f91913d12f47948ca0fd25b49c6fa7cdbeee8b" # Bob
export TEST_PRIVATE_KEY_2="0x0b6e18cafb6ed99687ec547bd28139cafdd2bffe70e6b688025de6b445aa5c5b" # Charlie

# Function to print colored output
print_color() {
    color=$1
    message=$2
    echo -e "${color}${message}${NC}"
}

# Function to cleanup processes
cleanup() {
    print_color $YELLOW "Cleaning up..."
    
    # Stop localnet if running
    if [ -f "$LOCALNET_PID_FILE" ]; then
        PID=$(cat "$LOCALNET_PID_FILE")
        if ps -p $PID > /dev/null; then
            print_color $YELLOW "Stopping localnet (PID: $PID)..."
            kill $PID 2>/dev/null || true
            sleep 2
            kill -9 $PID 2>/dev/null || true
        fi
        rm -f "$LOCALNET_PID_FILE"
    fi
    
    # Clean up temp files
    rm -f "$DEPLOYED_ADDRESS_FILE"
}

# Set up trap for cleanup
trap cleanup EXIT

# Function to wait for RPC endpoint
wait_for_rpc() {
    print_color $YELLOW "Waiting for RPC endpoint at $RPC_URL..."
    max_attempts=60  # Increased to 60 attempts (2 minutes)
    attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            "$RPC_URL" > /dev/null 2>&1; then
            print_color $GREEN "RPC endpoint is ready!"
            return 0
        fi
        
        attempt=$((attempt + 1))
        if [ $((attempt % 10)) -eq 0 ]; then
            print_color $YELLOW "Attempt $attempt/$max_attempts..."
        fi
        sleep 2
    done
    
    print_color $RED "RPC endpoint failed to respond after $max_attempts attempts"
    # Check if the process is still running
    if [ -f "$LOCALNET_PID_FILE" ]; then
        PID=$(cat "$LOCALNET_PID_FILE")
        if ! ps -p $PID > /dev/null; then
            print_color $RED "Localnet process died (PID: $PID)"
            print_color $RED "Last 50 lines of log:"
            tail -50 "${SCRIPT_DIR}/localnet.log"
        fi
    fi
    return 1
}

# Function to start localnet
start_localnet() {
    print_color $YELLOW "Starting Subtensor localnet..."
    
    if [ ! -d "$SUBTENSOR_DIR" ]; then
        print_color $RED "Subtensor directory not found. Please run: git submodule update --init --recursive"
        exit 1
    fi
    
    cd "$SUBTENSOR_DIR"
    
    # Check if localnet.sh exists
    if [ ! -f "scripts/localnet.sh" ]; then
        print_color $RED "localnet.sh not found in subtensor/scripts/"
        exit 1
    fi
    
    # Check if node-subtensor binary exists
    NODE_BINARY="${SUBTENSOR_DIR}/target/fast-blocks/release/node-subtensor"
    if [ ! -f "$NODE_BINARY" ]; then
        print_color $YELLOW "node-subtensor binary not found. Building subtensor..."
        print_color $YELLOW "This may take 5-10 minutes on first run..."
        
        # Build subtensor
        (cd "$SUBTENSOR_DIR" && cargo build --release --features "pow-faucet fast-blocks")
        
        if [ ! -f "$NODE_BINARY" ]; then
            print_color $RED "Failed to build node-subtensor"
            exit 1
        fi
    fi
    
    # Start localnet in background
    print_color $YELLOW "Starting localnet process..."
    bash scripts/localnet.sh > "${SCRIPT_DIR}/localnet.log" 2>&1 &
    LOCALNET_PID=$!
    echo $LOCALNET_PID > "$LOCALNET_PID_FILE"
    
    print_color $GREEN "Localnet started with PID: $LOCALNET_PID"
    
    # Give it a moment to start
    sleep 5
    
    # Wait for RPC to be available
    wait_for_rpc
    
    cd "$SCRIPT_DIR"
}

# Function to deploy contract
deploy_contract() {
    print_color $YELLOW "Deploying SaintDurbin contract..."
    
    # Create deployment config
    cat > "${SCRIPT_DIR}/test-deploy-config.json" << EOF
{
  "emergencyOperator": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "drainSs58Address": "0x0000000000000000000000000000000000000000000000000000000000000001",
  "validatorHotkey": "0x0000000000000000000000000000000000000000000000000000000000000002",
  "validatorUid": 0,
  "thisSs58PublicKey": "0x0000000000000000000000000000000000000000000000000000000000000003",
  "netuid": 0,
  "recipients": [
    {"name": "Sam", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000101", "proportion": 100},
    {"name": "WSL", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000102", "proportion": 100},
    {"name": "Paper", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000103", "proportion": 500},
    {"name": "Florian", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000104", "proportion": 100},
    {"name": "Recipient5", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000105", "proportion": 100},
    {"name": "Recipient6", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000106", "proportion": 300},
    {"name": "Recipient7", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000107", "proportion": 300},
    {"name": "Recipient8", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000108", "proportion": 300},
    {"name": "Recipient9", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000109", "proportion": 1000},
    {"name": "Recipient10", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000110", "proportion": 1000},
    {"name": "Recipient11", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000111", "proportion": 1000},
    {"name": "Recipient12", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000112", "proportion": 1500},
    {"name": "Recipient13", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000113", "proportion": 1500},
    {"name": "Recipient14", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000114", "proportion": 1000},
    {"name": "Recipient15", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000115", "proportion": 1000},
    {"name": "Recipient16", "coldkey": "0x0000000000000000000000000000000000000000000000000000000000000116", "proportion": 2000}
  ]
}
EOF

    # Set environment variables for deployment script
    export EMERGENCY_OPERATOR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    export DRAIN_SS58_ADDRESS="0x0000000000000000000000000000000000000000000000000000000000000001"
    export VALIDATOR_HOTKEY="0x0000000000000000000000000000000000000000000000000000000000000002"
    export VALIDATOR_UID="0"
    export CONTRACT_SS58_KEY="0x0000000000000000000000000000000000000000000000000000000000000003"
    export NETUID="0"
    
    # Set recipient environment variables
    export RECIPIENT_SAM="0x0000000000000000000000000000000000000000000000000000000000000101"
    export RECIPIENT_WSL="0x0000000000000000000000000000000000000000000000000000000000000102"
    export RECIPIENT_PAPER="0x0000000000000000000000000000000000000000000000000000000000000103"
    export RECIPIENT_FLORIAN="0x0000000000000000000000000000000000000000000000000000000000000104"
    export RECIPIENT_4="0x0000000000000000000000000000000000000000000000000000000000000105"
    export RECIPIENT_5="0x0000000000000000000000000000000000000000000000000000000000000106"
    export RECIPIENT_6="0x0000000000000000000000000000000000000000000000000000000000000107"
    export RECIPIENT_7="0x0000000000000000000000000000000000000000000000000000000000000108"
    export RECIPIENT_8="0x0000000000000000000000000000000000000000000000000000000000000109"
    export RECIPIENT_9="0x0000000000000000000000000000000000000000000000000000000000000110"
    export RECIPIENT_10="0x0000000000000000000000000000000000000000000000000000000000000111"
    export RECIPIENT_11="0x0000000000000000000000000000000000000000000000000000000000000112"
    export RECIPIENT_12="0x0000000000000000000000000000000000000000000000000000000000000113"
    export RECIPIENT_13="0x0000000000000000000000000000000000000000000000000000000000000114"
    export RECIPIENT_14="0x0000000000000000000000000000000000000000000000000000000000000115"
    export RECIPIENT_15="0x0000000000000000000000000000000000000000000000000000000000000116"
    
    # Deploy using test script
    print_color $YELLOW "Running forge deployment script..."
    DEPLOY_OUTPUT=$(forge script script/TestDeploy.s.sol:TestDeploy \
        --rpc-url "$RPC_URL" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        --broadcast \
        --slow \
        -vvv 2>&1)
    
    # Extract deployed address from output
    DEPLOYED_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oP "SaintDurbin deployed at: \K(0x[a-fA-F0-9]{40})" | tail -1)
    
    # If not found, try alternative pattern
    if [ -z "$DEPLOYED_ADDRESS" ]; then
        DEPLOYED_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oP "Contract Address: \K(0x[a-fA-F0-9]{40})" | tail -1)
    fi
    
    if [ -z "$DEPLOYED_ADDRESS" ]; then
        print_color $RED "Failed to extract deployed address from forge output"
        print_color $RED "Full output:"
        echo "$DEPLOY_OUTPUT" | head -100
        print_color $RED "Checking for errors:"
        echo "$DEPLOY_OUTPUT" | grep -i "error\|fail\|revert" | head -20 || true
        exit 1
    fi
    
    echo "$DEPLOYED_ADDRESS" > "$DEPLOYED_ADDRESS_FILE"
    export SAINT_DURBIN_ADDRESS="$DEPLOYED_ADDRESS"
    
    print_color $GREEN "SaintDurbin deployed at: $DEPLOYED_ADDRESS"
}

# Function to setup validator on localnet
setup_validator() {
    print_color $YELLOW "Setting up validator on localnet..."
    
    # This is a placeholder - actual implementation would use substrate tools
    # to register a validator on the localnet
    # For now, we'll assume the localnet has validators pre-configured
    
    print_color $GREEN "Validator setup complete (using localnet defaults)"
}

# Function to run JavaScript tests
run_js_tests() {
    print_color $YELLOW "Running JavaScript integration tests..."
    
    # Install dependencies
    cd "${SCRIPT_DIR}/scripts"
    
    if [ ! -d "node_modules" ]; then
        print_color $YELLOW "Installing JavaScript dependencies..."
        npm install
    fi
    
    # Install test dependencies
    npm install --save-dev mocha chai sinon @polkadot/api
    
    # Set environment variables for tests
    export SAINT_DURBIN_ADDRESS=$(cat "$DEPLOYED_ADDRESS_FILE")
    export PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY"
    export RPC_URL="$RPC_URL"
    export CHAIN_ENDPOINT="$CHAIN_ENDPOINT"
    export NODE_ENV="test"
    
    # Run tests
    print_color $YELLOW "Executing JavaScript tests..."
    npm test
    
    cd "$SCRIPT_DIR"
}

# Function to run Foundry tests
run_foundry_tests() {
    print_color $YELLOW "Running Foundry unit tests..."
    forge test -vvv
}

# Main execution
main() {
    print_color $GREEN "=== SaintDurbin Integration Test Suite ==="
    
    # Check prerequisites
    command -v forge >/dev/null 2>&1 || { print_color $RED "forge not found. Please install Foundry."; exit 1; }
    command -v node >/dev/null 2>&1 || { print_color $RED "node not found. Please install Node.js."; exit 1; }
    command -v npm >/dev/null 2>&1 || { print_color $RED "npm not found. Please install npm."; exit 1; }
    
    # Run tests based on arguments
    if [ "$1" == "foundry-only" ]; then
        run_foundry_tests
    elif [ "$1" == "js-only" ]; then
        # For JS-only tests, we still need the localnet and deployed contract
        start_localnet
        deploy_contract
        setup_validator
        run_js_tests
    else
        # Run full test suite
        run_foundry_tests
        start_localnet
        deploy_contract
        setup_validator
        run_js_tests
    fi
    
    print_color $GREEN "=== All tests completed successfully! ==="
}

# Run main function
main "$@"