// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// =============================================================================
// Test-only helper contracts for the AI Agent economy hardhat suite.
//
// These are NOT part of the production economy. They exist solely to exercise
// AgentPaymentEscrow's reentrancy guard and pull-payment accounting in local
// in-process tests.
//
// SCOPE: local testing ONLY. No deployment, no keys, no live transactions.
// =============================================================================

/// @dev Minimal escrow surface the attacker re-enters during a token callback.
interface IEscrowReenter {
    function withdraw(address token) external returns (uint256);
    function release(bytes32 escrowId) external;
}

/// @dev A malicious ERC-20 whose `transfer` re-enters the escrow's `withdraw`
///      while the escrow is mid-call. A standard ERC-20 otherwise (freely
///      mintable for test setup). The reentrancy guard in AgentPaymentEscrow
///      must force the re-entrant `withdraw` to revert; this token records
///      whether the re-entry was rejected so the test can assert on it.
contract ReentrantToken {
    string public name = "ReentrantToken";
    string public symbol = "REENT";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // --- attack config ---
    IEscrowReenter public escrow;
    bool public attackOnTransfer;
    bool public reentryAttempted;
    bool public reentryReverted;

    function setEscrow(IEscrowReenter _escrow) external {
        escrow = _escrow;
    }

    function setAttackOnTransfer(bool on) external {
        attackOnTransfer = on;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        // Re-entrancy attempt: when the escrow pays us out via transfer(), try
        // to re-enter withdraw() to double-spend. The guard must block it.
        if (attackOnTransfer && address(escrow) != address(0)) {
            reentryAttempted = true;
            try escrow.withdraw(address(this)) {
                reentryReverted = false; // guard FAILED (should not happen)
            } catch {
                reentryReverted = true; // guard held
            }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "REENT: INSUFFICIENT_ALLOWANCE");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "REENT: TO_ZERO");
        require(balanceOf[from] >= amount, "REENT: INSUFFICIENT_BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
