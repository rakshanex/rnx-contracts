// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title QuoteUSD — RNX Quote USD (test)
/// @notice An explicitly-labelled TEST USD quote token for the RNX economy.
///
///         THIS IS NOT A REAL STABLECOIN. It is not USDT, not USDC, and is not
///         backed by, affiliated with, or redeemable for any fiat currency or
///         real-world asset. It exists solely so that RNX-economy pricing and
///         quoting logic can be exercised against an 18-decimal "USD-like" unit
///         in test and public-mainnet-staging environments.
///
/// @dev    Transparency guarantees of this contract:
///           - There is exactly ONE mint authority: the `minter` role.
///           - Every mint emits BOTH the standard ERC-20 `Transfer(0 -> to)`
///             event AND a dedicated `Minted(minter, to, amount)` event, so all
///             issuance is fully auditable on-chain. There is NO hidden mint path.
///           - The minter role is explicit and transferable only by the current
///             minter, with a `MinterTransferred` event on every change.
///           - There is NO owner, NO pause, NO blocklist, NO upgradeability, and
///             NO function that creates tokens without emitting `Minted`.
///         Written in the OpenZeppelin idiom with no proprietary dependencies.
contract QuoteUSD {
    // ----------------------------------------------------------------------
    //                          ERC-20 metadata
    // ----------------------------------------------------------------------

    /// @dev Name and symbol are intentionally explicit that this is a TEST unit
    ///      and NOT USDT/USDC or any production stablecoin.
    string public constant name = "RNX Quote USD (test)";
    string public constant symbol = "qUSD";
    uint8 public constant decimals = 18;

    // ----------------------------------------------------------------------
    //                          ERC-20 storage
    // ----------------------------------------------------------------------

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    // ----------------------------------------------------------------------
    //                         Mint authority
    // ----------------------------------------------------------------------

    /// @notice The single, documented account allowed to mint qUSD.
    address public minter;

    // ----------------------------------------------------------------------
    //                               Events
    // ----------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Emitted on EVERY mint, in addition to the ERC-20 Transfer event,
    ///         so that all issuance is explicitly auditable.
    event Minted(address indexed minter, address indexed to, uint256 amount);

    /// @notice Emitted whenever the minter role is handed to a new account.
    event MinterTransferred(address indexed previousMinter, address indexed newMinter);

    // ----------------------------------------------------------------------
    //                           Constructor
    // ----------------------------------------------------------------------

    /// @param initialMinter The sole account granted mint authority at deploy time.
    constructor(address initialMinter) {
        require(initialMinter != address(0), "qUSD: minter is zero address");
        minter = initialMinter;
        emit MinterTransferred(address(0), initialMinter);
    }

    // ----------------------------------------------------------------------
    //                         Access control
    // ----------------------------------------------------------------------

    modifier onlyMinter() {
        require(msg.sender == minter, "qUSD: caller is not the minter");
        _;
    }

    /// @notice Transfer the single mint authority to a new account.
    /// @dev Only the current minter may call this. Set to a burn address to
    ///      permanently disable further minting if desired.
    function transferMinter(address newMinter) external onlyMinter {
        require(newMinter != address(0), "qUSD: new minter is zero address");
        address previous = minter;
        minter = newMinter;
        emit MinterTransferred(previous, newMinter);
    }

    // ----------------------------------------------------------------------
    //                              Minting
    // ----------------------------------------------------------------------

    /// @notice Mint `amount` qUSD to `to`. The ONLY issuance path in this
    ///         contract. Emits both Transfer(0 -> to) and Minted(...).
    function mint(address to, uint256 amount) external onlyMinter {
        require(to != address(0), "qUSD: mint to zero address");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
        emit Minted(msg.sender, to, amount);
    }

    // ----------------------------------------------------------------------
    //                           ERC-20 logic
    // ----------------------------------------------------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "qUSD: insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    /// @dev Shared transfer logic. Reverts on zero-address destination or
    ///      insufficient balance. There is no burn path and no fee-on-transfer.
    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "qUSD: transfer to zero address");
        require(balanceOf[from] >= amount, "qUSD: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
