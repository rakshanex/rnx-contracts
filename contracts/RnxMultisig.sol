// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title RnxMultisig — M-of-N owner multisignature wallet for the RNX economy
/// @notice A classic Gnosis/consensys-style M-of-N multisig. A transaction must
///         be submitted by an owner, confirmed by at least `threshold` (M) of
///         the `N` owners, and only then executed. It is intended to OWN the
///         privileged roles of the RNX economy contracts, e.g.:
///           - RnxStaking.owner / RnxStaking.rewardsDistribution
///           - QuoteUSD.minter
///         (AuditAnchor exposes no mutable admin role, so it is N/A.)
///
/// @dev    Written in the OpenZeppelin idiom and self-contained (no external
///         imports) to match the rest of the RNX economy codebase. The owner
///         set and threshold model follow the well-known multisig pattern and
///         the governance conventions in OpenZeppelin's `AccessControl` /
///         `Governor` families (members tracked in a set; mutating membership
///         requires passing through the contract's own authorization path).
///
///         Security properties:
///           - A transaction CANNOT execute with fewer than `threshold`
///             confirmations.
///           - A single owner alone CANNOT execute (when threshold > 1).
///           - Only owners may submit/confirm/revoke.
///           - Owner add/remove and threshold change are "self-calls": they can
///             ONLY be performed by the multisig executing a transaction whose
///             target is the multisig itself — i.e. they too require M-of-N.
///           - Reentrancy-safe execution (CEI + nonReentrant); a tx is marked
///             executed before the external call to prevent replay.
contract RnxMultisig {
    // ----------------------------------------------------------------------
    //                           Reentrancy guard
    // ----------------------------------------------------------------------
    // OZ ReentrancyGuard pattern.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_reentrancyStatus == _NOT_ENTERED, "RnxMultisig: reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ----------------------------------------------------------------------
    //                              Owner set
    // ----------------------------------------------------------------------

    address[] private _owners;
    mapping(address => bool) public isOwner;

    /// @notice Number of confirmations required to execute (M in M-of-N).
    uint256 public threshold;

    // ----------------------------------------------------------------------
    //                           Transaction store
    // ----------------------------------------------------------------------

    struct Transaction {
        address target; // destination contract/EOA
        uint256 value; // native value to forward
        bytes data; // calldata
        bool executed; // execution flag (replay guard)
        uint256 numConfirmations; // cached confirmation count
    }

    Transaction[] private _transactions;

    /// @notice txId => owner => confirmed?
    mapping(uint256 => mapping(address => bool)) public confirmations;

    // ----------------------------------------------------------------------
    //                               Events
    // ----------------------------------------------------------------------

    event Submit(uint256 indexed txId, address indexed proposer, address indexed target, uint256 value, bytes data);
    event Confirm(uint256 indexed txId, address indexed owner);
    event Revoke(uint256 indexed txId, address indexed owner);
    event Execute(uint256 indexed txId, address indexed target, uint256 value, bytes data);

    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);
    event Deposit(address indexed sender, uint256 amount);

    // ----------------------------------------------------------------------
    //                             Constructor
    // ----------------------------------------------------------------------

    /// @param owners_    The initial owner set (N owners). Must be non-empty,
    ///                    free of duplicates and zero addresses.
    /// @param threshold_ The confirmation threshold M, with 1 <= M <= N.
    constructor(address[] memory owners_, uint256 threshold_) {
        require(owners_.length > 0, "RnxMultisig: owners required");
        require(
            threshold_ > 0 && threshold_ <= owners_.length,
            "RnxMultisig: invalid threshold"
        );

        for (uint256 i = 0; i < owners_.length; i++) {
            address owner = owners_[i];
            require(owner != address(0), "RnxMultisig: owner is zero");
            require(!isOwner[owner], "RnxMultisig: duplicate owner");
            isOwner[owner] = true;
            _owners.push(owner);
            emit OwnerAdded(owner);
        }

        threshold = threshold_;
        emit ThresholdChanged(0, threshold_);
    }

    // ----------------------------------------------------------------------
    //                            Modifiers
    // ----------------------------------------------------------------------

    modifier onlyOwner() {
        require(isOwner[msg.sender], "RnxMultisig: not an owner");
        _;
    }

    /// @dev Guards owner/threshold administration: these may ONLY be invoked by
    ///      the multisig itself (i.e. as the target of an executed transaction,
    ///      which required M-of-N confirmations). No single owner can call them.
    modifier onlySelf() {
        require(msg.sender == address(this), "RnxMultisig: only via multisig");
        _;
    }

    modifier txExists(uint256 txId) {
        require(txId < _transactions.length, "RnxMultisig: tx does not exist");
        _;
    }

    modifier notExecuted(uint256 txId) {
        require(!_transactions[txId].executed, "RnxMultisig: tx already executed");
        _;
    }

    /// @notice Accept native deposits (e.g. to fund value-bearing transactions).
    receive() external payable {
        if (msg.value > 0) emit Deposit(msg.sender, msg.value);
    }

    // ----------------------------------------------------------------------
    //                               Views
    // ----------------------------------------------------------------------

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function ownerCount() external view returns (uint256) {
        return _owners.length;
    }

    function transactionCount() external view returns (uint256) {
        return _transactions.length;
    }

    function getTransaction(uint256 txId)
        external
        view
        txExists(txId)
        returns (address target, uint256 value, bytes memory data, bool executed, uint256 numConfirmations)
    {
        Transaction storage t = _transactions[txId];
        return (t.target, t.value, t.data, t.executed, t.numConfirmations);
    }

    function isConfirmed(uint256 txId, address owner) external view returns (bool) {
        return confirmations[txId][owner];
    }

    // ----------------------------------------------------------------------
    //                          Transaction flow
    // ----------------------------------------------------------------------

    /// @notice Submit a new transaction. Only owners may submit. The submitter
    ///         is NOT auto-confirmed; they must call `confirm` explicitly, so
    ///         confirmation counts are always explicit and auditable.
    /// @return txId The id of the newly created transaction.
    function submit(address target, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (uint256 txId)
    {
        require(target != address(0), "RnxMultisig: target is zero");
        txId = _transactions.length;
        _transactions.push(
            Transaction({target: target, value: value, data: data, executed: false, numConfirmations: 0})
        );
        emit Submit(txId, msg.sender, target, value, data);
    }

    /// @notice Confirm a pending transaction. Only owners; one confirmation per
    ///         owner per tx.
    function confirm(uint256 txId)
        external
        onlyOwner
        txExists(txId)
        notExecuted(txId)
    {
        require(!confirmations[txId][msg.sender], "RnxMultisig: already confirmed");
        confirmations[txId][msg.sender] = true;
        _transactions[txId].numConfirmations += 1;
        emit Confirm(txId, msg.sender);
    }

    /// @notice Revoke a previous confirmation on a not-yet-executed transaction.
    function revoke(uint256 txId)
        external
        onlyOwner
        txExists(txId)
        notExecuted(txId)
    {
        require(confirmations[txId][msg.sender], "RnxMultisig: not confirmed");
        confirmations[txId][msg.sender] = false;
        _transactions[txId].numConfirmations -= 1;
        emit Revoke(txId, msg.sender);
    }

    /// @notice Execute a transaction once it has at least `threshold`
    ///         confirmations. Only owners may trigger execution, but the actual
    ///         authorization is the M-of-N confirmation count — a single owner
    ///         cannot execute below threshold. Reverts below threshold.
    /// @dev CEI + nonReentrant: `executed` is set before the external call to
    ///      prevent replay/reentrancy.
    function execute(uint256 txId)
        external
        onlyOwner
        txExists(txId)
        notExecuted(txId)
        nonReentrant
    {
        Transaction storage t = _transactions[txId];
        require(t.numConfirmations >= threshold, "RnxMultisig: insufficient confirmations");

        // EFFECTS first
        t.executed = true;

        // INTERACTIONS
        (bool ok, bytes memory ret) = t.target.call{value: t.value}(t.data);
        if (!ok) {
            if (ret.length > 0) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            revert("RnxMultisig: underlying call reverted");
        }

        emit Execute(txId, t.target, t.value, t.data);
    }

    // ----------------------------------------------------------------------
    //                     Owner / threshold administration
    // ----------------------------------------------------------------------
    // All of the following are `onlySelf`: they can only run as the target of a
    // transaction the multisig itself executed, which required M-of-N. There is
    // no owner-only or deployer backdoor to change membership or threshold.

    /// @notice Add a new owner. Only via multisig self-call.
    function addOwner(address owner) external onlySelf {
        require(owner != address(0), "RnxMultisig: owner is zero");
        require(!isOwner[owner], "RnxMultisig: already an owner");
        isOwner[owner] = true;
        _owners.push(owner);
        emit OwnerAdded(owner);
    }

    /// @notice Remove an existing owner. Only via multisig self-call. Keeps the
    ///         invariant threshold <= ownerCount so the wallet never becomes
    ///         unusable.
    function removeOwner(address owner) external onlySelf {
        require(isOwner[owner], "RnxMultisig: not an owner");
        require(_owners.length - 1 >= threshold, "RnxMultisig: threshold too high after removal");
        require(_owners.length - 1 >= 1, "RnxMultisig: cannot remove last owner");

        isOwner[owner] = false;
        // swap-and-pop
        uint256 len = _owners.length;
        for (uint256 i = 0; i < len; i++) {
            if (_owners[i] == owner) {
                _owners[i] = _owners[len - 1];
                _owners.pop();
                break;
            }
        }
        emit OwnerRemoved(owner);
    }

    /// @notice Change the confirmation threshold. Only via multisig self-call.
    function changeThreshold(uint256 newThreshold) external onlySelf {
        require(newThreshold > 0 && newThreshold <= _owners.length, "RnxMultisig: invalid threshold");
        emit ThresholdChanged(threshold, newThreshold);
        threshold = newThreshold;
    }
}
