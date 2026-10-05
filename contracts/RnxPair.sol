// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// =============================================================================
// RnxPair — Uniswap-v2-style constant-product AMM pair for the RNX economy.
// =============================================================================
//
// ATTRIBUTION / CITATION
// ----------------------
// The constant-product automated market maker (x * y = k), the 0.3% fee model,
// the MINIMUM_LIQUIDITY lock, the geometric-mean initial LP mint, the
// price-cumulative oracle accumulators, and the lock/sync/skim mechanics below
// are the well-known, widely-reimplemented mechanics first published in:
//
//   Hayden Adams, Noah Zinsmeister, Dan Robinson,
//   "Uniswap v2 Core" (March 2020).
//   Reference implementation: Uniswap/v2-core (Uniswap Labs).
//
// Uniswap v2-core itself is licensed GPL-3.0. The code in THIS file is an
// independent, clean-room re-expression of those publicly documented formulas,
// written for Solidity 0.8.x (which has built-in checked arithmetic, so the
// original SafeMath is dropped) and released under the MIT license to match the
// rest of the RNX economy package. No Uniswap source was copied verbatim; the
// mathematics it implements is standard and in the public domain.
//
// SCOPE: compilation + local in-process testing ONLY. No deployment, no keys,
// no live transactions, no pre-seeded liquidity, no hard-coded price.
// =============================================================================

/// @dev Minimal ERC-20 interface used by the pair to move the two underlying
///      tokens (WRNX, qUSD, etc.). Matches the surface exposed by the RNX
///      economy's WRNX.sol and QuoteUSD.sol.
interface IRnxERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @dev Callback interface for the optional flash-swap style `data` path on
///      swap(). Kept for parity with the reference design; the RNX router never
///      uses it (it always passes empty `data`).
interface IRnxCallee {
    function rnxCall(address sender, uint256 amount0Out, uint256 amount1Out, bytes calldata data) external;
}

/// @title RnxPair
/// @notice Constant-product (x*y=k) liquidity pair with an ERC-20 LP token.
/// @dev One RnxPair instance holds reserves of exactly two tokens, `token0` and
///      `token1`, ordered by address by the factory. It is itself an ERC-20
///      whose balance represents a pro-rata claim on those reserves.
contract RnxPair {
    // ----------------------------------------------------------------------
    //                         LP token (ERC-20) metadata
    // ----------------------------------------------------------------------

    string public constant name = "RNX LP Token";
    string public constant symbol = "RNX-LP";
    uint8 public constant decimals = 18;

    // ----------------------------------------------------------------------
    //                         LP token (ERC-20) storage
    // ----------------------------------------------------------------------

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ----------------------------------------------------------------------
    //                              Pair state
    // ----------------------------------------------------------------------

    /// @notice The factory that created this pair.
    address public factory;
    /// @notice First underlying token (address-sorted: token0 < token1).
    address public token0;
    /// @notice Second underlying token.
    address public token1;

    /// @dev Cached reserves. Updated on every mint/burn/swap/sync via _update.
    uint112 private reserve0;
    uint112 private reserve1;
    /// @dev Block timestamp (mod 2**32) of the last reserve update, used by the
    ///      price-cumulative oracle accumulators.
    uint32 private blockTimestampLast;

    /// @notice Cumulative price accumulators (UQ112x112 fixed point summed over
    ///         elapsed seconds), usable as a TWAP oracle input. These are
    ///         accumulators only — the contract never asserts any external price.
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    /// @notice The first MINIMUM_LIQUIDITY LP tokens are permanently burned to
    ///         the zero address on the first mint, so the pool can never be
    ///         fully drained and LP-share rounding cannot be gamed to zero.
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;

    // ----------------------------------------------------------------------
    //                          Reentrancy guard
    // ----------------------------------------------------------------------

    /// @dev 1 = unlocked, 2 = locked. Starts unlocked.
    uint256 private unlocked = 1;

    /// @notice Reentrancy guard. Any state-mutating external entry point that
    ///         moves tokens is wrapped in this lock.
    modifier lock() {
        require(unlocked == 1, "RnxPair: LOCKED");
        unlocked = 2;
        _;
        unlocked = 1;
    }

    // ----------------------------------------------------------------------
    //                               Events
    // ----------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    // ----------------------------------------------------------------------
    //                            Construction
    // ----------------------------------------------------------------------

    /// @dev The deployer (factory) is recorded so only it may initialize the
    ///      token pair exactly once.
    constructor() {
        factory = msg.sender;
    }

    /// @notice One-time initializer called by the factory immediately after
    ///         deployment to bind the two underlying tokens.
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, "RnxPair: FORBIDDEN");
        require(token0 == address(0) && token1 == address(0), "RnxPair: ALREADY_INIT");
        token0 = _token0;
        token1 = _token1;
    }

    // ----------------------------------------------------------------------
    //                             Reserves view
    // ----------------------------------------------------------------------

    /// @notice Current cached reserves and the timestamp of their last update.
    function getReserves()
        public
        view
        returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast)
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // ----------------------------------------------------------------------
    //                        LP token (ERC-20) logic
    // ----------------------------------------------------------------------

    function _mint(address to, uint256 value) private {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) private {
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transferLP(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "RnxPair: INSUFFICIENT_ALLOWANCE");
            allowance[from][msg.sender] = allowed - value;
        }
        _transferLP(from, to, value);
        return true;
    }

    function _transferLP(address from, address to, uint256 value) private {
        require(to != address(0), "RnxPair: LP_TO_ZERO");
        require(balanceOf[from] >= value, "RnxPair: INSUFFICIENT_LP_BALANCE");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    // ----------------------------------------------------------------------
    //                          Oracle / reserve update
    // ----------------------------------------------------------------------

    /// @dev Updates cached reserves and, when time has elapsed and both reserves
    ///      are non-zero, advances the price-cumulative accumulators. The price
    ///      is encoded as UQ112x112: (reserveOther << 112) / reserveThis.
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "RnxPair: OVERFLOW");

        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        unchecked {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast; // wraps intentionally
            if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
                // price0 = reserve1/reserve0, price1 = reserve0/reserve1, both UQ112x112.
                price0CumulativeLast += ((uint256(_reserve1) << 112) / _reserve0) * timeElapsed;
                price1CumulativeLast += ((uint256(_reserve0) << 112) / _reserve1) * timeElapsed;
            }
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // ----------------------------------------------------------------------
    //                      Core AMM: mint / burn / swap
    // ----------------------------------------------------------------------

    /// @notice Mint LP tokens to `to` for whatever extra token0/token1 was sent
    ///         to this pair since the last reserve sync.
    /// @dev The caller (router) must transfer the input tokens to the pair
    ///      BEFORE calling mint. Liquidity minted is:
    ///        - first provision: sqrt(amount0*amount1) - MINIMUM_LIQUIDITY
    ///          (MINIMUM_LIQUIDITY permanently locked to address(0)); or
    ///        - subsequent:    min(amount0*supply/reserve0, amount1*supply/reserve1).
    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        uint256 balance0 = IRnxERC20(token0).balanceOf(address(this));
        uint256 balance1 = IRnxERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first tokens
        } else {
            uint256 l0 = (amount0 * _totalSupply) / _reserve0;
            uint256 l1 = (amount1 * _totalSupply) / _reserve1;
            liquidity = l0 < l1 ? l0 : l1;
        }
        require(liquidity > 0, "RnxPair: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice Burn the LP tokens held by this pair (sent in by the router) and
    ///         return the proportional share of both reserves to `to`.
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IRnxERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IRnxERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        uint256 _totalSupply = totalSupply;
        amount0 = (liquidity * balance0) / _totalSupply; // pro-rata, favours the pool
        amount1 = (liquidity * balance1) / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "RnxPair: INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liquidity);
        require(IRnxERC20(_token0).transfer(to, amount0), "RnxPair: T0_TRANSFER_FAILED");
        require(IRnxERC20(_token1).transfer(to, amount1), "RnxPair: T1_TRANSFER_FAILED");

        balance0 = IRnxERC20(_token0).balanceOf(address(this));
        balance1 = IRnxERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice Swap out `amount0Out` of token0 and/or `amount1Out` of token1 to
    ///         `to`. The caller must have already sent the corresponding input
    ///         amount(s) to the pair. Enforces the constant-product invariant
    ///         with a 0.3% fee: the fee-adjusted balances must satisfy
    ///         k_after >= k_before, i.e.
    ///
    ///             (balance0*1000 - amount0In*3) * (balance1*1000 - amount1In*3)
    ///                 >= reserve0 * reserve1 * 1000^2
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, "RnxPair: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "RnxPair: INSUFFICIENT_LIQUIDITY");

        uint256 balance0;
        uint256 balance1;
        {
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "RnxPair: INVALID_TO");
            if (amount0Out > 0) require(IRnxERC20(_token0).transfer(to, amount0Out), "RnxPair: T0_OUT_FAILED");
            if (amount1Out > 0) require(IRnxERC20(_token1).transfer(to, amount1Out), "RnxPair: T1_OUT_FAILED");
            if (data.length > 0) IRnxCallee(to).rnxCall(msg.sender, amount0Out, amount1Out, data);
            balance0 = IRnxERC20(_token0).balanceOf(address(this));
            balance1 = IRnxERC20(_token1).balanceOf(address(this));
        }

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "RnxPair: INSUFFICIENT_INPUT_AMOUNT");

        {
            // Apply the 0.3% fee and check the constant-product invariant.
            uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
            uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
            require(
                balance0Adjusted * balance1Adjusted >= uint256(_reserve0) * uint256(_reserve1) * (1000 ** 2),
                "RnxPair: K"
            );
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // ----------------------------------------------------------------------
    //                              skim / sync
    // ----------------------------------------------------------------------

    /// @notice Force balances to match reserves by sending any surplus tokens
    ///         to `to`. Recovery valve for tokens sent in excess of reserves.
    function skim(address to) external lock {
        address _token0 = token0;
        address _token1 = token1;
        require(
            IRnxERC20(_token0).transfer(to, IRnxERC20(_token0).balanceOf(address(this)) - reserve0),
            "RnxPair: SKIM0_FAILED"
        );
        require(
            IRnxERC20(_token1).transfer(to, IRnxERC20(_token1).balanceOf(address(this)) - reserve1),
            "RnxPair: SKIM1_FAILED"
        );
    }

    /// @notice Force reserves to match current balances.
    function sync() external lock {
        _update(
            IRnxERC20(token0).balanceOf(address(this)),
            IRnxERC20(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }

    // ----------------------------------------------------------------------
    //                           Math helper
    // ----------------------------------------------------------------------

    /// @dev Integer square root via the Babylonian method (standard, public
    ///      domain). Used only for the first-provision geometric-mean mint.
    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
