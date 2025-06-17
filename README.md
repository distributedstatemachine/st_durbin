# SaintDurbin - Patron Saint of Bittensor

SaintDurbin is a smart contract for distributing staking yields to multiple recipients while preserving the principal. The contract includes an emergency drain mechanism with a 2/3 multisig requirement on the Polkadot side.

## Features

- **Principal Protection**: Never distributes the principal amount, only staking rewards
- **Rate Analysis**: Detects principal additions through reward rate analysis
- **Daily Distribution**: Automated yield distribution with 7,200 block minimum interval
- **Emergency Drain**: Protected mechanism requiring both EVM trigger and Polkadot multisig
- **Immutable Recipients**: 16 recipients with fixed proportions set at deployment

## Architecture

```
src/
├── SaintDurbin.sol          # Main contract
└── interfaces/
    └── IStakingV2.sol       # Bittensor staking precompile interface

test/
├── SaintDurbin.t.sol        # Main contract tests
├── SaintDurbinPrincipal.t.sol  # Principal detection tests
├── SaintDurbinEmergency.t.sol  # Emergency drain tests
└── mocks/
    └── MockStaking.sol      # Mock staking precompile

script/
└── DeploySaintDurbin.s.sol  # Deployment script

scripts/
├── distribute.js            # Distribution automation script
├── package.json            # Node dependencies
└── config.json             # Configuration
```

## Recipient Configuration

The contract distributes to 16 recipients with the following proportions:
- Sam: 1% (100 basis points)
- WSL: 1% (100 basis points)
- Paper: 5% (500 basis points)
- Florian: 1% (100 basis points)
- Remaining 12 wallets: ~7.67% each (evenly distributed)

Total: 10,000 basis points (100%)

## Deployment

1. Set up environment variables:
```bash
cp .env.example .env
# Edit .env with your configuration
```

2. Deploy the contract:
```bash
forge script script/DeploySaintDurbin.s.sol:DeploySaintDurbin --rpc-url $BITTENSOR_RPC_URL --broadcast
```

3. After deployment, the owner must set the contract's SS58 public key:
```solidity
saintDurbin.setThisSs58PublicKey(contractSs58Key);
```

## GitHub Actions Setup

The repository includes a GitHub Actions workflow for automated daily yield distribution.

### Required Secrets:
- `DISTRIBUTOR_PRIVATE_KEY`: Private key of the distribution executor
- `BITTENSOR_RPC_URL`: Bittensor EVM RPC endpoint
- `SAINTDURBIN_CONTRACT_ADDRESS`: Deployed contract address

### Manual Trigger:
You can manually trigger the distribution workflow from the Actions tab using the "workflow_dispatch" event.

## Testing

Run all tests:
```bash
forge test
```

Run specific test suite:
```bash
forge test --match-contract SaintDurbinPrincipalTest
```

## Security Features

1. **Immutable Configuration**: Recipients and proportions cannot be changed after deployment
2. **Access Control**: Strict separation between owner and emergency operator roles
3. **Principal Safety**: Multiple checks prevent principal distribution
4. **Rate Analysis**: Detects unusual balance increases as principal additions
5. **Emergency Mechanism**: Requires both EVM trigger and Polkadot-side multisig

## License

GPL-3.0
