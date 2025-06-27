// Utility functions for converting between EVM and Substrate addresses
// These utilities implement the Frontier HashedAddressMapping logic

/**
 * Calculates the Substrate-compatible public key (bytes32) from an EVM H160 address.
 * This is used to determine the contract's own SS58 public key for precompile interactions.
 * @param {string} ethAddress - The H160 EVM address (e.g., "0x123...").
 * @returns {Promise<Uint8Array>} The 32-byte public key.
 */
export async function convertH160ToPublicKey(ethAddress) {
    // Dynamic import for ESM modules
    const { blake2AsU8a } = await import('@polkadot/util-crypto');
    const { hexToU8a } = await import('@polkadot/util');
    
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
 * Helper to get the SS58 public key as a hex string for Forge script environment variables
 * @param {string} ethAddress - The H160 EVM address
 * @returns {string} The SS58 public key as a hex string
 */
export async function convertH160ToPublicKeyHex(ethAddress) {
    const pubKeyBytes = await convertH160ToPublicKey(ethAddress);
    return '0x' + Buffer.from(pubKeyBytes).toString('hex');
}

/**
 * Calculate the expected contract address for a standard CREATE deployment
 * @param {string} deployerAddress - The deployer's address
 * @param {number} nonce - The deployer's nonce
 * @returns {Promise<string>} The predicted contract address
 */
export async function calculateContractAddress(deployerAddress, nonce) {
    const { getCreateAddress } = await import('ethers');
    return getCreateAddress({ from: deployerAddress, nonce });
}

/**
 * Calculate the expected contract address for a CREATE2 deployment
 * @param {string} factoryAddress - The factory contract address
 * @param {string} salt - The salt for CREATE2
 * @param {string} initCodeHash - The hash of the contract init code
 * @returns {Promise<string>} The predicted contract address
 */
export async function calculateCreate2Address(factoryAddress, salt, initCodeHash) {
    const { getCreate2Address } = await import('ethers');
    return getCreate2Address(factoryAddress, salt, initCodeHash);
}