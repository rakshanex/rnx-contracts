// SPDX-License-Identifier: MIT
// Hardhat configuration for the RNX economy contracts.
//
// SCOPE: compilation + local in-process testing ONLY.
//   - No deployment accounts.
//   - No private keys.
//   - No live RPC endpoints with signing capability.
//   - No deployment scripts are wired in here.
//
// The RNX Public Mainnet (chainId 194151 / 0x2F667) is described here as
// REFERENCE METADATA so that artifacts carry the correct target identity, but
// the network entry has NO `accounts` and defaults to the Hardhat in-memory
// network for tests. Deployment is intentionally out of scope.
//
// Legacy private chain 12345 is recorded for historical recognition only and is
// NOT a target of any economy work. Do not deploy economy contracts there.

require("@nomicfoundation/hardhat-toolbox");

const RNX_PUBLIC_MAINNET_CHAIN_ID = 194151; // 0x2F667
const LEGACY_PRIVATE_CHAIN_ID = 12345;       // historical anchor chain, out of scope

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    // Default test network — in-process, ephemeral, no persistence.
    hardhat: {
      chainId: 31337,
    },
    // NOTE: The RNX Public Mainnet (chainId 194151 / 0x2F667) is intentionally
    // NOT defined as a connectable network here. Defining it would require a
    // live `url` (and, to deploy, `accounts`/keys). Per the files-only policy we
    // record its identity under `rnxMeta` below instead, so no accidental live
    // connection, signing, or deployment is possible from this config.
  },
  // Reference metadata only; not used to connect, sign, or deploy anywhere.
  rnxMeta: {
    nativeSymbol: "RNX",
    nativeDecimals: 18,
    publicMainnetChainId: RNX_PUBLIC_MAINNET_CHAIN_ID,
    publicMainnetChainIdHex: "0x2F667",
    legacyPrivateChainId: LEGACY_PRIVATE_CHAIN_ID,
    deploymentPolicy: "files-only; no deploy; no keys; no transactions",
  },
};
