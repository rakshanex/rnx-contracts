// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title WRNX — Wrapped RNX
/// @notice A WETH9-style 1:1 wrapper for the native RNX asset (18 decimals).
///         Each wei of native RNX deposited mints exactly one wei of WRNX; each
///         WRNX withdrawn burns one wei of WRNX and returns one wei of native RNX.
/// @dev    This is a faithful, standards-compliant ERC-20 wrapper. It deliberately
///         has:
///           - NO owner / admin role
///           - NO arbitrary mint function
///           - NO pause / freeze / blocklist
///           - NO upgradeability
///         The ONLY way WRNX is created is by depositing native RNX, and the ONLY
///         way it is destroyed is by withdrawing native RNX. This enforces the
///         invariant:
///
///             totalSupply() == address(this).balance
///
///         (holds after every externally-observable state transition).
///
///         The code is written in the OpenZeppelin / WETH9 idiom and uses no
///         proprietary dependencies.
contract WRNX {
    // ----------------------------------------------------------------------
    //                          ERC-20 metadata
    // ----------------------------------------------------------------------

    string public constant name = "Wrapped RNX";
    string public constant symbol = "WRNX";
    uint8 public constant decimals = 18;

    // ----------------------------------------------------------------------
    //                          ERC-20 storage
    // ----------------------------------------------------------------------

    /// @dev Account balances. The sum of all balances always equals totalSupply.
    mapping(address => uint256) public balanceOf;

    /// @dev owner => spender => remaining allowance.
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev Total WRNX in existence. Mirrors the native RNX locked in this
    ///      contract exactly (see contract-level invariant).
    uint256 public totalSupply;

    // ----------------------------------------------------------------------
    //                               Events
    // ----------------------------------------------------------------------

    /// @notice Standard ERC-20 Transfer event. Mint (deposit) is emitted as a
    ///         Transfer from the zero address; burn (withdraw) as a Transfer to
    ///         the zero address.
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Standard ERC-20 Approval event.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Emitted when native RNX is wrapped into WRNX.
    event Deposit(address indexed dst, uint256 wad);

    /// @notice Emitted when WRNX is unwrapped back into native RNX.
    event Withdrawal(address indexed src, uint256 wad);

    // ----------------------------------------------------------------------
    //                        Wrap / unwrap logic
    // ----------------------------------------------------------------------

    /// @notice Wrap native RNX sent with the call into WRNX at a 1:1 ratio.
    receive() external payable {
        deposit();
    }

    /// @notice Wrap native RNX sent with the call into WRNX at a 1:1 ratio.
    /// @dev Mints `msg.value` WRNX to `msg.sender`. Preserves the invariant
    ///      totalSupply == address(this).balance because both increase by
    ///      msg.value in the same transaction.
    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Unwrap `wad` WRNX back into native RNX at a 1:1 ratio.
    /// @param wad Amount of WRNX to burn / native RNX to receive.
    /// @dev Burns first, then transfers native RNX. The balance check guarantees
    ///      the caller cannot withdraw more than it holds, and because every WRNX
    ///      is backed 1:1 by locked native RNX the contract always has the funds.
    function withdraw(uint256 wad) public {
        require(balanceOf[msg.sender] >= wad, "WRNX: insufficient balance");
        balanceOf[msg.sender] -= wad;
        totalSupply -= wad;
        emit Transfer(msg.sender, address(0), wad);
        emit Withdrawal(msg.sender, wad);

        (bool ok, ) = payable(msg.sender).call{value: wad}("");
        require(ok, "WRNX: RNX transfer failed");
    }

    // ----------------------------------------------------------------------
    //                           ERC-20 logic
    // ----------------------------------------------------------------------

    /// @notice Approve `spender` to transfer up to `wad` of the caller's WRNX.
    function approve(address spender, uint256 wad) public returns (bool) {
        allowance[msg.sender][spender] = wad;
        emit Approval(msg.sender, spender, wad);
        return true;
    }

    /// @notice Transfer `wad` WRNX from the caller to `dst`.
    function transfer(address dst, uint256 wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    /// @notice Transfer `wad` WRNX from `src` to `dst`, consuming allowance when
    ///         the caller is not `src`.
    /// @dev Reverts on insufficient balance, insufficient allowance, or transfer
    ///      to the zero address (burning may only happen via withdraw()).
    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        require(dst != address(0), "WRNX: transfer to zero address");
        require(balanceOf[src] >= wad, "WRNX: insufficient balance");

        if (src != msg.sender) {
            uint256 allowed = allowance[src][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= wad, "WRNX: insufficient allowance");
                allowance[src][msg.sender] = allowed - wad;
            }
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);
        return true;
    }
}
