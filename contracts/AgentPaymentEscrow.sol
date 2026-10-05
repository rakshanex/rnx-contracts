// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @dev Minimal ERC-20 surface used by the escrow. WRNX (the existing 1:1
///      native wrapper in this repo) satisfies this interface. Declared locally
///      so the contract pulls in no external/proprietary dependency.
interface IERC20Min {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title AgentPaymentEscrow — agent-to-agent (M2M) WRNX payment escrow
/// @notice Escrows WRNX for a single logical payment keyed by
///         (fromAgent, toAgent, ref). The payer funds the escrow, and the funds
///         can be settled in exactly one of two mutually-exclusive ways:
///           1. RELEASE  — the payer confirms, crediting the payee's pull-balance.
///           2. REFUND   — after the deadline passes, anyone may trigger a refund
///                         crediting the payer's pull-balance.
///         Payouts use the PULL-PAYMENT pattern: settlement only moves funds into
///         an internal `withdrawable` ledger; recipients later `withdraw()` to
///         actually receive WRNX. This isolates the fund-moving external call
///         from state changes and avoids push-payment griefing.
///
/// @dev    SECURITY MODEL (explicit, documented, no hidden powers):
///           - NO owner / admin / operator role anywhere in this contract.
///           - NO mint: the escrow can only ever pay out WRNX that was actually
///             deposited into it. It never creates balance from nothing.
///           - NO drain: there is no function that lets any party sweep the
///             contract's token balance. Every WRNX leaving the contract is
///             attributable to a specific (payer deposit -> payee/payer pull).
///           - Reentrancy: a classic non-reentrant guard (OpenZeppelin
///             `ReentrancyGuard` idiom,
///             https://docs.openzeppelin.com/contracts/5.x/api/utils#ReentrancyGuard)
///             protects `deposit`, `release`, `refund`, and `withdraw`. Combined
///             with checks-effects-interactions and the pull pattern, a malicious
///             token/recipient cannot re-enter to double-spend.
///           - Settlement is one-shot per escrow: Funded -> (Released|Refunded).
///
///         Accounting is per-token internal (`withdrawable[token][account]`), so
///         the contract never relies on its own raw token balance for authorization.
contract AgentPaymentEscrow {
    // ----------------------------------------------------------------------
    //                           Reentrancy guard
    // ----------------------------------------------------------------------
    // OpenZeppelin ReentrancyGuard idiom, inlined to avoid an external import.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    modifier nonReentrant() {
        require(_status != _ENTERED, "Escrow: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor() {
        _status = _NOT_ENTERED;
    }

    // ----------------------------------------------------------------------
    //                                Types
    // ----------------------------------------------------------------------

    enum Status {
        None,     // never created
        Funded,   // payer deposited; awaiting release or refund
        Released, // settled to payee's pull-balance
        Refunded  // returned to payer's pull-balance
    }

    /// @dev One escrow entry. `payer`/`payee` are the EOAs that fund / receive;
    ///      `fromAgent`/`toAgent` are the logical agent identities (as used in
    ///      AgentRegistry) that the payment is "between".
    struct Escrow {
        address token;      // ERC-20 being escrowed (WRNX)
        address payer;      // EOA that deposited and may release/refund
        address payee;      // EOA credited on release
        bytes32 fromAgent;  // paying agent identity
        bytes32 toAgent;    // receiving agent identity
        uint256 amount;     // escrowed amount
        uint64 deadline;    // unix time after which refund is allowed
        Status status;      // lifecycle state
    }

    /// @notice escrowId => Escrow.
    mapping(bytes32 => Escrow) private _escrows;

    /// @notice Pull-payment ledger: token => account => amount withdrawable.
    mapping(address => mapping(address => uint256)) public withdrawable;

    // ----------------------------------------------------------------------
    //                                Events
    // ----------------------------------------------------------------------

    event EscrowDeposited(
        bytes32 indexed escrowId,
        address indexed payer,
        address indexed payee,
        address token,
        bytes32 fromAgent,
        bytes32 toAgent,
        bytes32 ref,
        uint256 amount,
        uint64 deadline
    );
    event EscrowReleased(bytes32 indexed escrowId, address indexed payee, uint256 amount);
    event EscrowRefunded(bytes32 indexed escrowId, address indexed payer, uint256 amount);
    event Withdrawn(address indexed token, address indexed account, uint256 amount);

    // ----------------------------------------------------------------------
    //                              ID derivation
    // ----------------------------------------------------------------------

    /// @notice Deterministic escrow id for a (fromAgent, toAgent, ref) tuple.
    /// @dev `ref` lets the same agent pair run many independent escrows (e.g.
    ///      per-invoice). The tuple is unique per logical payment.
    function computeEscrowId(
        bytes32 fromAgent,
        bytes32 toAgent,
        bytes32 ref
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(fromAgent, toAgent, ref));
    }

    // ----------------------------------------------------------------------
    //                               Deposit
    // ----------------------------------------------------------------------

    /// @notice Fund a new escrow. Pulls `amount` of `token` from `msg.sender`
    ///         (the payer) via transferFrom; caller must have approved first.
    /// @param token     ERC-20 to escrow (WRNX).
    /// @param payee     EOA that will be credited on release.
    /// @param fromAgent Paying agent identity.
    /// @param toAgent   Receiving agent identity.
    /// @param ref       Caller-chosen reference (e.g. invoice id).
    /// @param amount    Amount to escrow (must be > 0).
    /// @param deadline  Unix time after which a refund becomes allowed.
    /// @return escrowId The derived escrow identifier.
    /// @dev Measures the actual received amount (balance delta) so that any
    ///      transfer tax / fee-on-transfer behaviour cannot desync internal
    ///      accounting from real holdings. State is written before no external
    ///      interaction follows the transfer (CEI respected; transferFrom is the
    ///      only external call and the entry is finalized from its measured result).
    function deposit(
        address token,
        address payee,
        bytes32 fromAgent,
        bytes32 toAgent,
        bytes32 ref,
        uint256 amount,
        uint64 deadline
    ) external nonReentrant returns (bytes32 escrowId) {
        require(token != address(0), "Escrow: token=0");
        require(payee != address(0), "Escrow: payee=0");
        require(amount > 0, "Escrow: amount=0");
        require(deadline > block.timestamp, "Escrow: deadline in past");

        escrowId = computeEscrowId(fromAgent, toAgent, ref);
        Escrow storage e = _escrows[escrowId];
        require(e.status == Status.None, "Escrow: already exists");

        uint256 balBefore = IERC20Min(token).balanceOf(address(this));
        bool ok = IERC20Min(token).transferFrom(msg.sender, address(this), amount);
        require(ok, "Escrow: transferFrom failed");
        uint256 received = IERC20Min(token).balanceOf(address(this)) - balBefore;
        require(received == amount, "Escrow: amount mismatch");

        e.token = token;
        e.payer = msg.sender;
        e.payee = payee;
        e.fromAgent = fromAgent;
        e.toAgent = toAgent;
        e.amount = amount;
        e.deadline = deadline;
        e.status = Status.Funded;

        emit EscrowDeposited(
            escrowId, msg.sender, payee, token, fromAgent, toAgent, ref, amount, deadline
        );
    }

    // ----------------------------------------------------------------------
    //                          Release (payer confirm)
    // ----------------------------------------------------------------------

    /// @notice Payer confirms the work/goods; credits the payee's pull-balance.
    /// @dev ONLY the payer may release. Moves funds to the internal ledger only
    ///      (no token transfer here) — payee pulls via `withdraw()`.
    function release(bytes32 escrowId) external nonReentrant {
        Escrow storage e = _escrows[escrowId];
        require(e.status == Status.Funded, "Escrow: not funded");
        require(msg.sender == e.payer, "Escrow: not payer");

        e.status = Status.Released;
        uint256 amount = e.amount;
        withdrawable[e.token][e.payee] += amount;

        emit EscrowReleased(escrowId, e.payee, amount);
    }

    // ----------------------------------------------------------------------
    //                          Refund (expiry)
    // ----------------------------------------------------------------------

    /// @notice After the deadline, return escrowed funds to the payer's pull-balance.
    /// @dev Permissionless trigger (anyone may call) but funds can ONLY ever go
    ///      back to the original payer — there is no way to redirect them. This
    ///      lets a keeper unstick an abandoned escrow without being able to steal.
    function refund(bytes32 escrowId) external nonReentrant {
        Escrow storage e = _escrows[escrowId];
        require(e.status == Status.Funded, "Escrow: not funded");
        require(block.timestamp >= e.deadline, "Escrow: not expired");

        e.status = Status.Refunded;
        uint256 amount = e.amount;
        withdrawable[e.token][e.payer] += amount;

        emit EscrowRefunded(escrowId, e.payer, amount);
    }

    // ----------------------------------------------------------------------
    //                          Withdraw (pull payment)
    // ----------------------------------------------------------------------

    /// @notice Withdraw all WRNX credited to the caller for `token`.
    /// @dev Checks-Effects-Interactions: zero the ledger entry BEFORE the token
    ///      transfer, under the reentrancy guard. A reentrant token callback thus
    ///      finds a zero balance and cannot double-withdraw.
    function withdraw(address token) external nonReentrant returns (uint256 amount) {
        amount = withdrawable[token][msg.sender];
        require(amount > 0, "Escrow: nothing to withdraw");

        withdrawable[token][msg.sender] = 0;

        bool ok = IERC20Min(token).transfer(msg.sender, amount);
        require(ok, "Escrow: transfer failed");

        emit Withdrawn(token, msg.sender, amount);
    }

    // ----------------------------------------------------------------------
    //                                 Views
    // ----------------------------------------------------------------------

    function getEscrow(bytes32 escrowId)
        external
        view
        returns (
            address token,
            address payer,
            address payee,
            bytes32 fromAgent,
            bytes32 toAgent,
            uint256 amount,
            uint64 deadline,
            Status status
        )
    {
        Escrow storage e = _escrows[escrowId];
        return (
            e.token, e.payer, e.payee, e.fromAgent, e.toAgent, e.amount, e.deadline, e.status
        );
    }
}
