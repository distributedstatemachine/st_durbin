#!/bin/bash

# SaintDurbin Integration Test Runner

set -e

echo "🚀 SaintDurbin Integration Test Runner"
echo "======================================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
SUBTENSOR_PID=""
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$SCRIPT_DIR/../.."
SUBTENSOR_DIR="$PROJECT_ROOT/subtensor_chain"

# Cleanup function
cleanup() {
    if [ ! -z "$SUBTENSOR_PID" ]; then
        echo -e "\n${YELLOW}Stopping subtensor chain...${NC}"
        kill $SUBTENSOR_PID 2>/dev/null || true
        wait $SUBTENSOR_PID 2>/dev/null || true
    fi
}

# Set up trap to cleanup on exit
trap cleanup EXIT INT TERM

# Function to check if subtensor chain is running
check_chain() {
    echo -n "Checking if subtensor chain is running... "
    if curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"system_health","params":[],"id":1}' \
        http://127.0.0.1:9944 > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
        return 0
    else
        echo -e "${RED}✗${NC}"
        return 1
    fi
}

# Function to start subtensor chain
start_chain() {
    echo -e "${BLUE}Starting local subtensor chain...${NC}"
    
    if [ ! -d "$SUBTENSOR_DIR" ]; then
        echo -e "${RED}Error: Subtensor chain directory not found at $SUBTENSOR_DIR${NC}"
        exit 1
    fi
    
    cd "$SUBTENSOR_DIR"
    
    # Check if localnet.sh exists
    if [ ! -f "scripts/localnet.sh" ]; then
        echo -e "${RED}Error: localnet.sh script not found${NC}"
        exit 1
    fi
    
    # Start the chain in background
    echo "Starting chain (this may take a moment)..."
    ./scripts/localnet.sh > /tmp/subtensor.log 2>&1 &
    SUBTENSOR_PID=$!
    
    # Wait for chain to be ready
    echo -n "Waiting for chain to be ready"
    for i in {1..60}; do
        if check_chain > /dev/null 2>&1; then
            echo -e " ${GREEN}✓${NC}"
            echo -e "${GREEN}Subtensor chain started successfully!${NC}"
            cd "$SCRIPT_DIR"
            return 0
        fi
        echo -n "."
        sleep 2
    done
    
    echo -e " ${RED}✗${NC}"
    echo -e "${RED}Failed to start subtensor chain. Check /tmp/subtensor.log for details${NC}"
    cd "$SCRIPT_DIR"
    return 1
}

# Function to compile contracts
compile_contracts() {
    echo -n "Compiling contracts... "
    cd "$PROJECT_ROOT"
    if forge build > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
        cd "$SCRIPT_DIR"
        return 0
    else
        echo -e "${RED}✗${NC}"
        echo "Failed to compile contracts"
        cd "$SCRIPT_DIR"
        return 1
    fi
}

# Function to install dependencies
install_deps() {
    echo -e "${BLUE}Installing dependencies...${NC}"
    
    # Install subtensor chain dependencies if needed
    if [ -d "$SUBTENSOR_DIR/evm-tests" ]; then
        echo -n "  Checking subtensor chain test dependencies... "
        cd "$SUBTENSOR_DIR/evm-tests"
        if [ ! -d "node_modules" ]; then
            echo -e "${YELLOW}Installing...${NC}"
            npm install
            echo -e "  ${GREEN}✓ Subtensor test dependencies installed${NC}"
        else
            echo -e "${GREEN}✓${NC}"
        fi
    fi
    
    # Install integration test dependencies
    cd "$SCRIPT_DIR"
    echo -n "  Checking integration test dependencies... "
    if [ ! -d "node_modules" ]; then
        echo -e "${YELLOW}Installing...${NC}"
        npm install
        echo -e "  ${GREEN}✓ Integration test dependencies installed${NC}"
    else
        echo -e "${GREEN}✓${NC}"
    fi
}

# Main execution
main() {
    cd "$SCRIPT_DIR"
    
    # Parse command line arguments
    local TEST_TYPE="$1"
    local AUTO_START=true
    
    # Check for --no-auto-start flag
    if [[ "$*" == *"--no-auto-start"* ]]; then
        AUTO_START=false
    fi
    
    # Install dependencies first
    install_deps
    
    # Check if chain is running
    if ! check_chain > /dev/null 2>&1; then
        if [ "$AUTO_START" = true ]; then
            if ! start_chain; then
                echo -e "${RED}Failed to start subtensor chain${NC}"
                exit 1
            fi
        else
            echo -e "${RED}Subtensor chain is not running${NC}"
            echo -e "${YELLOW}Start it manually or remove --no-auto-start flag${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}Using existing subtensor chain${NC}"
    fi
    
    # Compile contracts
    if ! compile_contracts; then
        exit 1
    fi
    
    # Generate polkadot-api descriptors
    echo -e "${BLUE}Generating chain metadata...${NC}"
    cd "$SUBTENSOR_DIR/evm-tests"
    if [ -f "get-metadata.sh" ]; then
        echo -n "  Generating polkadot-api descriptors... "
        if bash get-metadata.sh > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
            echo -e "${RED}Failed to generate metadata${NC}"
            cd "$SCRIPT_DIR"
            exit 1
        fi
    fi
    cd "$SCRIPT_DIR"
    
    echo ""
    echo "Running tests..."
    echo ""
    
    # Run tests based on argument
    case "$TEST_TYPE" in
        "deployment")
            echo "🔧 Running deployment tests..."
            npm run test:deployment
            ;;
        "transfer")
            echo "💰 Running transfer tests..."
            npm run test:transfer
            ;;
        "validator")
            echo "🔄 Running validator switching tests..."
            npm run test:validator
            ;;
        "emergency")
            echo "🚨 Running emergency drain tests..."
            npm run test:emergency
            ;;
        "all"|"")
            echo "🧪 Running all tests..."
            npm test
            ;;
        *)
            echo "Usage: $0 [deployment|transfer|validator|emergency|all] [--no-auto-start]"
            echo ""
            echo "Options:"
            echo "  --no-auto-start    Don't automatically start the subtensor chain"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"