# SaintDurbin Deployment Guide

This guide explains how to deploy the SaintDurbin contract with the correct SS58 public key configuration.

## Pre-Deployment Steps

### 1. Generate the Contract's SS58 Public Key

The contract requires its own SS58 public key (`thisSs58PublicKey`) to be passed as a constructor argument. This key MUST be pre-calculated based on the contract's future deployment address.

#### Using Standard CREATE Deployment:

1. First, determine your deployer address and current nonce:
   ```bash
   # Get deployer address and nonce from your wallet or chain
   DEPLOYER_ADDRESS="0x..." # Your deployer address
   NONCE=5                  # Your current nonce
   ```

2. Generate the SS58 key:
   ```bash
   cd scripts
   npm install  # Install dependencies if not already done
   node generate-ss58-key.js $DEPLOYER_ADDRESS $NONCE
   ```

   This will output:
   ```
   Deployer Address: 0x...
   Nonce: 5
   Predicted Contract Address: 0x...
   SS58 Public Key (bytes32): 0x...
   
   For deployment script:
   export CONTRACT_SS58_KEY="0x..."
   ```

3. Copy the `CONTRACT_SS58_KEY` value for use in deployment.

#### Using CREATE2 Deployment:

If using CREATE2, you'll need to calculate the address differently and then convert it:
```bash
# If you know the CREATE2 address already:
node generate-ss58-key.js 0x<create2-address>
```

### 2. Set Environment Variables

Create a `.env` file or export the following environment variables:

```bash
# Contract configuration
export CONTRACT_SS58_KEY="0x..."  # From step 1
export EMERGENCY_OPERATOR="0x..."  # EVM address of emergency operator
export DRAIN_SS58_ADDRESS="0x..."  # SS58 public key for emergency drain
export VALIDATOR_HOTKEY="0x..."    # Initial validator's SS58 hotkey
export VALIDATOR_UID=123           # Initial validator's UID
export NETUID=1                    # Subnet ID

# Recipients (SS58 public keys)
export RECIPIENT_SAM="0x..."
export RECIPIENT_WSL="0x..."
export RECIPIENT_PAPER="0x..."
export RECIPIENT_FLORIAN="0x..."
export RECIPIENT_4="0x..."
# ... continue for all 16 recipients
export RECIPIENT_15="0x..."
```

### 3. Deploy the Contract

```bash
# Deploy using Foundry
forge script script/DeploySaintDurbin.s.sol:DeploySaintDurbin \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

## Important Notes

1. **SS58 Key Generation**: The `CONTRACT_SS58_KEY` MUST be generated from the contract's deployment address using the Blake2b-256 hash of `"evm:" + contract_address`. This is how the Bittensor precompiles identify the contract.

2. **Address Types**: 
   - `EMERGENCY_OPERATOR`: Standard EVM address (20 bytes)
   - All other addresses: SS58 public keys (32 bytes)

3. **Immutability**: Once deployed, the contract configuration cannot be changed. Double-check all values before deployment.

## Verification

After deployment, verify:
1. The contract's `thisSs58PublicKey` matches your pre-calculated value
2. The contract can successfully call `getStakedBalance()` 
3. All recipients are correctly configured

## Troubleshooting

- **"Precompile call failed: getStake"**: Likely means the SS58 key is incorrect. Verify you calculated it from the correct contract address.
- **Invalid recipient addresses**: Ensure all recipient coldkeys are 32-byte SS58 public keys, not EVM addresses.