// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/AgentPaymentEscrow.sol";
import "../contracts/test/TestHelpers.sol";

/// @title AgentPaymentEscrow fuzz / property tests
/// @notice Properties under test for the pull-payment escrow:
///   1. FUNDS CONSERVATION — while an escrow is Funded, the escrow contract's
///      token balance equals the sum of unsettled escrowed amounts. Nothing is
///      minted or lost; every token in the contract is attributable.
///   2. RELEASE PAYS EXACTLY THE PAYEE — on release + withdraw, the payee
///      receives exactly `amount`, the payer receives nothing.
///   3. REFUND PAYS EXACTLY THE PAYER — after deadline, refund + withdraw pays
///      the payer exactly `amount`, the payee receives nothing.
///   4. STATE-MACHINE EXCLUSIVITY — an escrow can be settled in exactly ONE
///      terminal way: once Released it cannot be refunded, once Refunded it
///      cannot be released. Never both.
///
/// Uses the WRNX-compatible TestHelpers.TestERC20 as the escrowed TEST asset.
/// No deploy, no keys, no real value.
contract EscrowFuzz is Test {
    AgentPaymentEscrow escrow;
    TestERC20 token; // escrowed TEST asset (WRNX-like)

    address payer = address(0xA11);
    address payee = address(0xB22);

    bytes32 constant FROM_AGENT = keccak256("fromAgent");
    bytes32 constant TO_AGENT = keccak256("toAgent");

    function setUp() public {
        escrow = new AgentPaymentEscrow();
        token = new TestERC20("EscrowTok", "ETK");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _deposit(uint256 amount, uint64 deadline, bytes32 ref)
        internal
        returns (bytes32 escrowId)
    {
        token.mint(payer, amount);
        vm.startPrank(payer);
        token.approve(address(escrow), amount);
        escrowId = escrow.deposit(
            address(token), payee, FROM_AGENT, TO_AGENT, ref, amount, deadline
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // PROPERTY 1 + 2: funds conserved while funded; release pays exactly payee
    // ------------------------------------------------------------------

    function testFuzz_fundsConserved_and_releasePaysPayee(uint96 amount, uint64 deadlineOffset)
        public
    {
        amount = uint96(bound(amount, 1, 1e27));
        // deadline must be strictly in the future at deposit time.
        uint256 offset = bound(deadlineOffset, 1, 365 days);
        uint64 deadline = uint64(block.timestamp + offset);

        bytes32 id = _deposit(amount, deadline, keccak256("ref-release"));

        // CONSERVATION: while Funded, escrow holds exactly the escrowed amount.
        assertEq(
            token.balanceOf(address(escrow)),
            amount,
            "escrow balance != unsettled escrowed amount while funded"
        );

        // Payer releases to payee's pull-balance.
        vm.prank(payer);
        escrow.release(id);

        // Pull ledger credited to payee for exactly `amount`.
        assertEq(escrow.withdrawable(address(token), payee), amount, "payee not credited amount");
        assertEq(escrow.withdrawable(address(token), payer), 0, "payer wrongly credited");

        // Payee withdraws — receives exactly amount; payer receives nothing.
        uint256 payeeBefore = token.balanceOf(payee);
        uint256 payerBefore = token.balanceOf(payer);
        vm.prank(payee);
        escrow.withdraw(address(token));

        assertEq(token.balanceOf(payee) - payeeBefore, amount, "payee did not receive exact amount");
        assertEq(token.balanceOf(payer), payerBefore, "payer balance changed on release path");

        // Escrow fully drained — no residue.
        assertEq(token.balanceOf(address(escrow)), 0, "escrow retained funds after settlement");
    }

    // ------------------------------------------------------------------
    // PROPERTY 3: refund pays exactly the payer (after deadline)
    // ------------------------------------------------------------------

    function testFuzz_refundPaysPayer(uint96 amount, uint64 deadlineOffset) public {
        amount = uint96(bound(amount, 1, 1e27));
        uint256 offset = bound(deadlineOffset, 1, 365 days);
        uint64 deadline = uint64(block.timestamp + offset);

        bytes32 id = _deposit(amount, deadline, keccak256("ref-refund"));

        assertEq(token.balanceOf(address(escrow)), amount, "conservation broken pre-refund");

        // Warp to/after the deadline so refund is permitted.
        vm.warp(uint256(deadline));

        // Permissionless trigger — anyone may refund, but only to the payer.
        escrow.refund(id);

        assertEq(escrow.withdrawable(address(token), payer), amount, "payer not credited on refund");
        assertEq(escrow.withdrawable(address(token), payee), 0, "payee wrongly credited on refund");

        uint256 payeeBefore = token.balanceOf(payee);
        uint256 payerBefore = token.balanceOf(payer);
        vm.prank(payer);
        escrow.withdraw(address(token));

        assertEq(token.balanceOf(payer) - payerBefore, amount, "payer did not receive exact refund");
        assertEq(token.balanceOf(payee), payeeBefore, "payee balance changed on refund path");
        assertEq(token.balanceOf(address(escrow)), 0, "escrow retained funds after refund");
    }

    // ------------------------------------------------------------------
    // PROPERTY 4: state-machine exclusivity — never both release AND refund
    // ------------------------------------------------------------------

    /// @notice Once released, a refund (even after deadline) must revert.
    function testFuzz_cannotRefundAfterRelease(uint96 amount, uint64 deadlineOffset) public {
        amount = uint96(bound(amount, 1, 1e27));
        uint256 offset = bound(deadlineOffset, 1, 365 days);
        uint64 deadline = uint64(block.timestamp + offset);

        bytes32 id = _deposit(amount, deadline, keccak256("ref-excl-1"));

        vm.prank(payer);
        escrow.release(id);

        // Warp well past the deadline; refund must still be rejected.
        vm.warp(uint256(deadline) + 1);
        vm.expectRevert(bytes("Escrow: not funded"));
        escrow.refund(id);

        // Payee got credited, payer never did.
        assertEq(escrow.withdrawable(address(token), payee), amount, "payee credit lost");
        assertEq(escrow.withdrawable(address(token), payer), 0, "payer must never be credited");
    }

    /// @notice Once refunded, a release must revert.
    function testFuzz_cannotReleaseAfterRefund(uint96 amount, uint64 deadlineOffset) public {
        amount = uint96(bound(amount, 1, 1e27));
        uint256 offset = bound(deadlineOffset, 1, 365 days);
        uint64 deadline = uint64(block.timestamp + offset);

        bytes32 id = _deposit(amount, deadline, keccak256("ref-excl-2"));

        vm.warp(uint256(deadline));
        escrow.refund(id);

        vm.prank(payer);
        vm.expectRevert(bytes("Escrow: not funded"));
        escrow.release(id);

        assertEq(escrow.withdrawable(address(token), payer), amount, "payer credit lost");
        assertEq(escrow.withdrawable(address(token), payee), 0, "payee must never be credited");
    }

    /// @notice Exactly-one-settlement across the full lifecycle: the total paid
    ///         out to (payer + payee) always equals the single escrowed amount —
    ///         never zero (lost) and never 2x (double-pay), regardless of which
    ///         terminal branch a fuzzed boolean selects.
    function testFuzz_exactlyOneSettlement(uint96 amount, uint64 deadlineOffset, bool doRelease)
        public
    {
        amount = uint96(bound(amount, 1, 1e27));
        uint256 offset = bound(deadlineOffset, 1, 365 days);
        uint64 deadline = uint64(block.timestamp + offset);

        bytes32 id = _deposit(amount, deadline, keccak256("ref-exactly-one"));

        uint256 payerBefore = token.balanceOf(payer);
        uint256 payeeBefore = token.balanceOf(payee);

        if (doRelease) {
            vm.prank(payer);
            escrow.release(id);
            vm.prank(payee);
            escrow.withdraw(address(token));
        } else {
            vm.warp(uint256(deadline));
            escrow.refund(id);
            vm.prank(payer);
            escrow.withdraw(address(token));
        }

        uint256 payerDelta = token.balanceOf(payer) - payerBefore;
        uint256 payeeDelta = token.balanceOf(payee) - payeeBefore;

        // Exactly `amount` was paid out in total — conservation, no mint/loss.
        assertEq(payerDelta + payeeDelta, amount, "total settled != escrowed amount");

        // Mutual exclusivity: exactly one party received funds, not both.
        assertTrue(
            (payerDelta == amount && payeeDelta == 0) ||
                (payeeDelta == amount && payerDelta == 0),
            "settlement was not mutually exclusive"
        );

        assertEq(token.balanceOf(address(escrow)), 0, "escrow retained funds post-settlement");
    }
}
