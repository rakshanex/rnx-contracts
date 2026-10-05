// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// =============================================================================
// RnxFactory — pair registry/deployer for the RNX constant-product AMM.
// =============================================================================
//
// ATTRIBUTION / CITATION
// ----------------------
// The factory pattern below — one canonical pair per unordered token pair,
// address-sorted token0/token1, a getPair mapping and an allPairs array — is
// the well-known design published in Uniswap v2 Core (Adams, Zinsmeister,
// Robinson, 2020; reference impl Uniswap/v2-core, GPL-3.0). This file is an
// independent MIT re-expression of that public design. It intentionally uses
// plain `new`-based deployment plus `initialize` rather than CREATE2, since the
// RNX router discovers pairs via getPair() and does not depend on a
// deterministic init-code-hash address.
//
// SCOPE: compilation + local in-process testing ONLY. No deployment, no keys,
// no live transactions.
// =============================================================================

import {RnxPair} from "./RnxPair.sol";

/// @title RnxFactory
/// @notice Deploys and indexes RnxPair instances. Exactly one pair may exist
///         for any unordered pair of distinct token addresses.
contract RnxFactory {
    /// @notice getPair[tokenA][tokenB] == getPair[tokenB][tokenA] == the pair,
    ///         or address(0) if none exists yet.
    mapping(address => mapping(address => address)) public getPair;

    /// @notice All pairs ever created, in creation order.
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairIndex);

    /// @notice Number of pairs created so far.
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /// @notice Create the canonical pair for (tokenA, tokenB).
    /// @dev Reverts on identical addresses, the zero address, or if the pair
    ///      already exists. Tokens are address-sorted so token0 < token1 and the
    ///      pair is registered symmetrically in getPair.
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "RnxFactory: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "RnxFactory: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "RnxFactory: PAIR_EXISTS");

        RnxPair newPair = new RnxPair();
        newPair.initialize(token0, token1);
        pair = address(newPair);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // symmetric lookup
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length - 1);
    }
}
