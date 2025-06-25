#!/usr/bin/env node

// Standalone script to generate SS58 public key from an EVM address
// Usage: node generate-ss58-key.js <eth-address> [nonce]

import { blake2AsU8a } from '@polkadot/util-crypto';
import { hexToU8a } from '@polkadot/util';
import { getCreateAddress } from 'ethers';

/**
 * Calculates the Substrate-compatible public key (bytes32) from an EVM H160 address.
 * @param {string} ethAddress - The H160 EVM address (e.g., "0x123...").
 * @returns {Uint8Array} The 32-byte public key.
 */
function convertH160ToPublicKey(ethAddress) {
    const prefix = "evm:";
    const prefixBytes = new TextEncoder().encode(prefix);
    const addressBytes = hexToU8a(
        ethAddress.startsWith("0x") ? ethAddress : `0x${ethAddress}`
    );
    const combined = new Uint8Array(prefixBytes.length + addressBytes.length);

    combined.set(prefixBytes);
    combined.set(addressBytes, prefixBytes.length);

    return blake2AsU8a(combined); // This is a 32-byte hash
}

/**
 * Helper to get the SS58 public key as a hex string
 * @param {string} ethAddress - The H160 EVM address
 * @returns {string} The SS58 public key as a hex string
 */
function convertH160ToPublicKeyHex(ethAddress) {
    const pubKeyBytes = convertH160ToPublicKey(ethAddress);
    return '0x' + Buffer.from(pubKeyBytes).toString('hex');
}

// Main execution
async function main() {
    const args = process.argv.slice(2);
    
    if (args.length === 0) {
        console.error('Usage: node generate-ss58-key.js <eth-address-or-deployer> [nonce]');
        console.error('Examples:');
        console.error('  node generate-ss58-key.js 0x123...abc           # Convert existing address');
        console.error('  node generate-ss58-key.js 0x456...def 5         # Calculate from deployer + nonce');
        process.exit(1);
    }

    let ethAddress = args[0];
    const nonce = args[1] ? parseInt(args[1]) : null;

    // If nonce is provided, calculate the contract address
    if (nonce !== null) {
        const deployerAddress = ethAddress;
        ethAddress = getCreateAddress({ from: deployerAddress, nonce });
        console.log(`Deployer Address: ${deployerAddress}`);
        console.log(`Nonce: ${nonce}`);
        console.log(`Predicted Contract Address: ${ethAddress}`);
    } else {
        console.log(`Contract Address: ${ethAddress}`);
    }

    const ss58PublicKeyHex = convertH160ToPublicKeyHex(ethAddress);
    console.log(`SS58 Public Key (bytes32): ${ss58PublicKeyHex}`);
    
    // Also output as environment variable format
    console.log('\nFor deployment script:');
    console.log(`export CONTRACT_SS58_KEY="${ss58PublicKeyHex}"`);
}

main().catch(error => {
    console.error('Error:', error);
    process.exit(1);
});