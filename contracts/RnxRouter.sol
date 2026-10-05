// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// =============================================================================
// RnxRouter — periphery router for the RNX constant-product AMM.
// =============================================================================
//
// ATTRIBUTION / CITATION
// ----------------------
// The library math (quote, getAmountOut, getAmountIn with the 0.3% fee) and the
// addLiquidity / removeLiquidity / swapExactTokensForTokens /
// swapTokensForExactTokens flows below are the well-known periphery mechanics
// published in Uniswap v2 (Adams, Zinsmeister, Robinson, 2020; reference impls
// Uniswap/v2-core and Uniswap/v2-periphery, GPL-3.0). This file is an
// independent MIT re-expression of those public formulas, targeting Solidity
// 0.8.x checked arithmetic.
//
// Differences from the reference periphery, by design:
//   - No WETH/native-token convenience wrappers here (WRNX is handled as a plain
//     ERC-20 by callers that want wrapping).
//   - No fee-on-transfer swap variants (RNX economy tokens are not fee-on-transfer).
//
// SCOPE: compilation + local in-process testing ONLY. No deployment, no keys,
// no live transactions, no pre-seeded liquidity, no hard-coded price.
// =============================================================================

import {RnxFactory} from "./RnxFactory.sol";
import {RnxPair} from "./RnxPair.sol";

/// @dev Minimal ERC-20 surface the router needs from WRNX / qUSD / etc.
interface IRnxERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

/// @title RnxRouter
/// @notice Stateless periphery for adding/removing liquidity and swapping across
///         RnxPair pools, with deadline and slippage (min/max amount) guards.
contract RnxRouter {
    /// @notice The factory this router routes through.
    address public immutable factory;

    constructor(address _factory) {
        require(_factory != address(0), "RnxRouter: ZERO_FACTORY");
        factory = _factory;
    }

    /// @dev Reverts once the current block timestamp passes `deadline`.
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "RnxRouter: EXPIRED");
        _;
    }

    // ======================================================================
    //                        Pure AMM library math
    // ======================================================================

    /// @notice Sort two token addresses, reverting on identical/zero inputs.
    function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        require(tokenA != tokenB, "RnxRouter: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "RnxRouter: ZERO_ADDRESS");
    }

    /// @notice Reserves of (tokenA, tokenB) for an existing pair, oriented to the
    ///         caller's token order.
    function getReserves(address tokenA, address tokenB)
        public
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0, ) = sortTokens(tokenA, tokenB);
        address pair = RnxFactory(factory).getPair(tokenA, tokenB);
        require(pair != address(0), "RnxRouter: PAIR_NOT_FOUND");
        (uint112 reserve0, uint112 reserve1, ) = RnxPair(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
    }

    /// @notice Given an amount of asset A and the pool reserves, return the
    ///         equivalent amount of asset B at the current ratio (no fee; used
    ///         for liquidity provisioning).
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256 amountB) {
        require(amountA > 0, "RnxRouter: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "RnxRouter: INSUFFICIENT_LIQUIDITY");
        amountB = (amountA * reserveB) / reserveA;
    }

    /// @notice Maximum output for an exact input, applying the 0.3% fee.
    /// @dev amountOut = (amountIn*997*reserveOut) / (reserveIn*1000 + amountIn*997)
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "RnxRouter: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "RnxRouter: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Minimum input required to receive an exact output, applying the
    ///         0.3% fee (rounded up).
    /// @dev amountIn = (reserveIn*amountOut*1000) / ((reserveOut-amountOut)*997) + 1
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "RnxRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "RnxRouter: INSUFFICIENT_LIQUIDITY");
        require(amountOut < reserveOut, "RnxRouter: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    // ======================================================================
    //                              Liquidity
    // ======================================================================

    /// @dev Compute how much of each token to actually deposit, respecting the
    ///      current ratio and the caller's minimums. Creates the pair on first
    ///      provision if it does not yet exist.
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        if (RnxFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            RnxFactory(factory).createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB) = getReserves(tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "RnxRouter: INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, "RnxRouter: INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    /// @notice Add liquidity to the (tokenA, tokenB) pool and mint LP tokens to
    ///         `to`. Pulls tokens from the caller via transferFrom.
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = RnxFactory(factory).getPair(tokenA, tokenB);
        require(IRnxERC20(tokenA).transferFrom(msg.sender, pair, amountA), "RnxRouter: A_PULL_FAILED");
        require(IRnxERC20(tokenB).transferFrom(msg.sender, pair, amountB), "RnxRouter: B_PULL_FAILED");
        liquidity = RnxPair(pair).mint(to);
    }

    /// @notice Remove liquidity by burning `liquidity` LP tokens and returning
    ///         both underlying tokens to `to`, subject to minimum-out slippage
    ///         bounds. Pulls LP tokens from the caller via transferFrom.
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = RnxFactory(factory).getPair(tokenA, tokenB);
        require(pair != address(0), "RnxRouter: PAIR_NOT_FOUND");
        require(RnxPair(pair).transferFrom(msg.sender, pair, liquidity), "RnxRouter: LP_PULL_FAILED");
        (uint256 amount0, uint256 amount1) = RnxPair(pair).burn(to);
        (address token0, ) = sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, "RnxRouter: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "RnxRouter: INSUFFICIENT_B_AMOUNT");
    }

    // ======================================================================
    //                               Swaps
    // ======================================================================

    /// @notice Swap an exact `amountIn` of `tokenIn` for as much `tokenOut` as
    ///         possible, reverting if the output is below `amountOutMin`.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn,
        address tokenOut,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountOut) {
        (uint256 reserveIn, uint256 reserveOut) = getReserves(tokenIn, tokenOut);
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        require(amountOut >= amountOutMin, "RnxRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        _swap(amountIn, amountOut, tokenIn, tokenOut, to);
    }

    /// @notice Receive an exact `amountOut` of `tokenOut`, spending at most
    ///         `amountInMax` of `tokenIn` (reverts otherwise).
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address tokenIn,
        address tokenOut,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountIn) {
        (uint256 reserveIn, uint256 reserveOut) = getReserves(tokenIn, tokenOut);
        amountIn = getAmountIn(amountOut, reserveIn, reserveOut);
        require(amountIn <= amountInMax, "RnxRouter: EXCESSIVE_INPUT_AMOUNT");
        _swap(amountIn, amountOut, tokenIn, tokenOut, to);
    }

    /// @dev Pull `amountIn` of tokenIn from the caller into the pair, then call
    ///      pair.swap to push `amountOut` of tokenOut to `to`.
    function _swap(uint256 amountIn, uint256 amountOut, address tokenIn, address tokenOut, address to) internal {
        address pair = RnxFactory(factory).getPair(tokenIn, tokenOut);
        require(pair != address(0), "RnxRouter: PAIR_NOT_FOUND");
        require(IRnxERC20(tokenIn).transferFrom(msg.sender, pair, amountIn), "RnxRouter: IN_PULL_FAILED");
        (address token0, ) = sortTokens(tokenIn, tokenOut);
        (uint256 amount0Out, uint256 amount1Out) =
            tokenIn == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        RnxPair(pair).swap(amount0Out, amount1Out, to, new bytes(0));
    }
}
