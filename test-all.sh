#!/bin/bash

# SaintDurbin Complete Test Suite Runner
# This script runs all tests in the correct order

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_header() {
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}========================================${NC}\n"
}

print_status() {
    echo -e "${YELLOW}[STATUS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Main test execution
main() {
    print_header "SaintDurbin Complete Test Suite"
    
    # 1. Run Foundry unit tests
    print_header "Running Foundry Unit Tests"
    print_status "Testing contract logic..."
    forge test -vv || {
        print_error "Foundry tests failed"
        exit 1
    }
    
    # 2. Check contract compilation and sizes
    print_header "Checking Contract Compilation"
    print_status "Building contracts..."
    forge build --sizes || {
        print_error "Contract compilation failed"
        exit 1
    }
    
    # 3. Run JavaScript unit tests
    print_header "Running JavaScript Unit Tests"
    print_status "Testing automation scripts..."
    cd scripts
    
    # Install dependencies if needed
    if [ ! -d "node_modules" ]; then
        print_status "Installing JavaScript dependencies..."
        npm install
    fi
    
    # Run tests
    npm test || {
        print_error "JavaScript tests failed"
        exit 1
    }
    cd ..
    
    # 4. Run security analysis (optional)
    if command -v slither &> /dev/null; then
        print_header "Running Security Analysis"
        print_status "Running Slither..."
        slither . --compile-force-framework foundry 2>/dev/null || true
    fi
    
    # 5. Summary
    print_header "Test Summary"
    echo -e "${GREEN}✓ Foundry unit tests passed${NC}"
    echo -e "${GREEN}✓ Contract compilation successful${NC}"
    echo -e "${GREEN}✓ JavaScript unit tests passed${NC}"
    
    # Optional: Run integration tests if requested
    if [ "$1" == "--integration" ]; then
        print_header "Running Integration Tests"
        print_status "Starting local chain and running integration tests..."
        ./run-integration-tests.sh
    else
        echo -e "\n${YELLOW}Note: Run with --integration flag to include integration tests${NC}"
    fi
    
    print_header "All Tests Completed Successfully!"
}

# Run main function
main "$@"