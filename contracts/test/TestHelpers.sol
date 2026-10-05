// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// =============================================================================
// Test-only helper contracts for the RNX AMM hardhat suite.
//
// These are NOT part of the production economy. They exist solely to exercise
// the AMM in local in-process tests (freely mintable ERC-20s, and a token that
// attempts to re-enter the pair to prove the reentrancy guard holds).
//
// SCOPE: local testing ONLY. No deployment, no keys, no live transactions.
// =============================================================================

import {RnxPair} from "../RnxPair.sol";

/// @dev A freely-mintable 18-decimal ERC-20 used to construct arbitrary test
///      pairs. Standard OpenZeppelin-idiom implementation, no proprietary deps.
contract TestERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
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
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "TestERC20: INSUFFICIENT_ALLOWANCE");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "TestERC20: TO_ZERO");
        require(balanceOf[from] >= amount, "TestERC20: INSUFFICIENT_BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @dev A flash-swap recipient that attempts to re-enter swap() during the
///      pair's `rnxCall` callback (invoked WHILE the lock is held). The lock
///      modifier must force the re-entry to revert with "RnxPair: LOCKED",
///      which the attacker catches. The attacker then REPAYS the flash loan so
///      the OUTER swap succeeds and commits — this lets the test assert, on a
///      successful transaction, both that the re-entry was observed and that it
///      was rejected (reentryReverted == true). If the guard were missing, the
///      inner swap would have drained the pair instead of reverting.
contract ReentrantCallee {
    RnxPair public target;
    IRnxERC20Min public repayToken;
    uint256 public repayAmount;
    bool public reentryReverted;
    bool public reentryObserved;

    event ReentryAttempted(bool reverted);

    function setTarget(RnxPair _target) external {
        target = _target;
    }

    /// @notice Configure which token / how much to send back to the pair during
    ///         the callback so the outer swap's K-invariant check passes.
    function setRepayment(IRnxERC20Min _repayToken, uint256 _repayAmount) external {
        repayToken = _repayToken;
        repayAmount = _repayAmount;
    }

    /// @notice Flash-swap callback invoked by the pair during swap().
    function rnxCall(address, uint256, uint256, bytes calldata) external {
        reentryObserved = true;
        // Attempt to re-enter swap() while the pair lock is held.
        try target.swap(0, 1, address(this), new bytes(0)) {
            reentryReverted = false; // reached only if the guard FAILED to block
            emit ReentryAttempted(false);
        } catch {
            reentryReverted = true; // guard held and reverted the re-entry
            emit ReentryAttempted(true);
        }
        // Repay the flash loan so the OUTER swap's K check passes and commits.
        if (address(repayToken) != address(0) && repayAmount > 0) {
            repayToken.transfer(address(target), repayAmount);
        }
    }
}

/// @dev Tiny ERC-20 surface used by the attacker to repay the flash loan.
interface IRnxERC20Min {
    function transfer(address to, uint256 value) external returns (bool);
}
