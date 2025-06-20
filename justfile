# Justfile for Foundry project

# Default recipe to display help
default:
  @just --list

# Build the project
build:
  forge build

# Format code
format:
  forge fmt

# Run tests
test:
  forge test

# Run tests with verbosity
test-v:
  forge test -vvv

# Run Slither static analysis
slither:
  slither .

# Run all checks (format, build, test, slither)
check: format build test slither

# Clean build artifacts
clean:
  forge clean

# Run integration tests
integration:
  ./test-all.sh --integration