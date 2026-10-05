// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title RnxTimelock — delayed-execution governance queue for the RNX economy
/// @notice A TimelockController-style delay queue that enforces a mandatory
///         `minDelay` between the moment an operation is scheduled and the
///         moment it may be executed. It is intended to OWN the privileged
///         roles of the RNX economy contracts, e.g.:
///           - RnxStaking.owner / RnxStaking.rewardsDistribution
///           - QuoteUSD.minter
///
///         By routing all privileged mutations through this contract, no single
///         privileged action can take effect instantly: every call must first be
///         `schedule`d, then wait out `minDelay`, then be `execute`d. This gives
///         observers a guaranteed reaction window.
///
/// @dev    This contract is written in the OpenZeppelin idiom and deliberately
///         mirrors the public interface and semantics of OpenZeppelin's
///         `TimelockController`
///         (openzeppelin-contracts/contracts/governance/TimelockController.sol):
///           - Role-gated proposing (PROPOSER_ROLE) and executing (EXECUTOR_ROLE).
///           - Operations keyed by a deterministic id = keccak256(target,value,
///             data,predecessor,salt).
///           - A per-operation timestamp acting as both "scheduled" marker and
///             ETA; `_DONE_TIMESTAMP = 1` marks completion (as in OZ).
///         It is self-contained (no external imports) to match the rest of the
///         RNX economy codebase, but the access-control and lifecycle logic is
///         the OpenZeppelin AccessControl + TimelockController pattern.
///
///         Reentrancy safety: `execute` follows checks-effects-interactions and
///         is additionally guarded by a nonReentrant mutex. The operation is
///         marked DONE *before* the external call, so a malicious target cannot
///         re-execute the same operation.
contract RnxTimelock {
    // ----------------------------------------------------------------------
    //                               Roles
    // ----------------------------------------------------------------------
    // OZ AccessControl pattern: roles are bytes32 identifiers mapped to member
    // sets. We keep a minimal implementation (grant/revoke are themselves only
    // reachable through the timelock via the admin role held by this contract).

    /// @notice Role allowed to schedule (propose) and cancel operations.
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    /// @notice Role allowed to execute ready operations.
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    /// @notice Admin role able to grant/revoke the above roles. Granted to this
    ///         contract itself so that role management is also time-locked.
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");

    /// @dev role => account => isMember
    mapping(bytes32 => mapping(address => bool)) private _roles;

    // ----------------------------------------------------------------------
    //                           Operation state
    // ----------------------------------------------------------------------
    // Mirrors OZ TimelockController._timestamps. Value semantics:
    //   0                 => operation is unset (never scheduled)
    //   1 (_DONE_TIMESTAMP) => operation already executed
    //   > 1               => operation scheduled; value is the ETA timestamp
    uint256 internal constant _DONE_TIMESTAMP = uint256(1);

    mapping(bytes32 => uint256) private _timestamps;

    /// @notice Minimum delay (in seconds) enforced between schedule and execute.
    uint256 public minDelay;

    // ----------------------------------------------------------------------
    //                          Reentrancy guard
    // ----------------------------------------------------------------------
    // OZ ReentrancyGuard pattern.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_reentrancyStatus == _NOT_ENTERED, "RnxTimelock: reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ----------------------------------------------------------------------
    //                               Events
    // ----------------------------------------------------------------------

    /// @notice Emitted when an operation is scheduled.
    event CallScheduled(
        bytes32 indexed id,
        address indexed target,
        uint256 value,
        bytes data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 eta
    );

    /// @notice Emitted when an operation is executed.
    event CallExecuted(bytes32 indexed id, address indexed target, uint256 value, bytes data);

    /// @notice Emitted when a scheduled (not-yet-executed) operation is cancelled.
    event Cancelled(bytes32 indexed id);

    /// @notice Emitted when `minDelay` is changed (only reachable via the timelock itself).
    event MinDelayChange(uint256 oldDuration, uint256 newDuration);

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    // ----------------------------------------------------------------------
    //                             Constructor
    // ----------------------------------------------------------------------

    /// @param _minDelay   Minimum delay in seconds for all operations.
    /// @param proposers   Accounts granted PROPOSER_ROLE.
    /// @param executors   Accounts granted EXECUTOR_ROLE.
    /// @dev The contract grants TIMELOCK_ADMIN_ROLE to itself only, matching the
    ///      OZ TimelockController self-administration model: after construction,
    ///      role changes must themselves pass through the delay queue.
    constructor(uint256 _minDelay, address[] memory proposers, address[] memory executors) {
        // Self-administration: only this contract (via a scheduled op) can
        // grant/revoke roles afterwards.
        _grantRole(TIMELOCK_ADMIN_ROLE, address(this));

        for (uint256 i = 0; i < proposers.length; i++) {
            require(proposers[i] != address(0), "RnxTimelock: proposer is zero");
            _grantRole(PROPOSER_ROLE, proposers[i]);
        }
        for (uint256 i = 0; i < executors.length; i++) {
            require(executors[i] != address(0), "RnxTimelock: executor is zero");
            _grantRole(EXECUTOR_ROLE, executors[i]);
        }

        minDelay = _minDelay;
        emit MinDelayChange(0, _minDelay);
    }

    // ----------------------------------------------------------------------
    //                          Access control
    // ----------------------------------------------------------------------

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "RnxTimelock: missing role");
        _;
    }

    /// @notice This contract must be able to receive native value callbacks for
    ///         operations that carry value; also allows funding for execution.
    receive() external payable {}

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    function _revokeRole(bytes32 role, address account) internal {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    /// @notice Grant a role. Only callable by TIMELOCK_ADMIN_ROLE, which is held
    ///         solely by this contract — so a grant must itself be scheduled and
    ///         executed through the timelock.
    function grantRole(bytes32 role, address account) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        _grantRole(role, account);
    }

    /// @notice Revoke a role. Only callable by TIMELOCK_ADMIN_ROLE (this contract).
    function revokeRole(bytes32 role, address account) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        _revokeRole(role, account);
    }

    /// @notice Update the minimum delay. Only reachable via the timelock itself
    ///         (msg.sender == address(this)), mirroring OZ's `updateDelay`.
    function updateDelay(uint256 newDelay) external {
        require(msg.sender == address(this), "RnxTimelock: caller must be timelock");
        emit MinDelayChange(minDelay, newDelay);
        minDelay = newDelay;
    }

    // ----------------------------------------------------------------------
    //                        Operation identity
    // ----------------------------------------------------------------------

    /// @notice Compute the deterministic id of an operation (OZ `hashOperation`).
    function hashOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, predecessor, salt));
    }

    // ----------------------------------------------------------------------
    //                          Status helpers
    // ----------------------------------------------------------------------

    /// @notice True if the operation id has ever been scheduled (pending or done).
    function isOperation(bytes32 id) public view returns (bool) {
        return _timestamps[id] > 0;
    }

    /// @notice True if the operation is scheduled but not yet executed.
    function isOperationPending(bytes32 id) public view returns (bool) {
        return _timestamps[id] > _DONE_TIMESTAMP;
    }

    /// @notice True if the operation is scheduled and its ETA has passed.
    function isOperationReady(bytes32 id) public view returns (bool) {
        uint256 ts = _timestamps[id];
        return ts > _DONE_TIMESTAMP && ts <= block.timestamp;
    }

    /// @notice True if the operation has already been executed.
    function isOperationDone(bytes32 id) public view returns (bool) {
        return _timestamps[id] == _DONE_TIMESTAMP;
    }

    /// @notice Returns the ETA timestamp of a pending operation (0 if unset,
    ///         1 if done).
    function getTimestamp(bytes32 id) public view returns (uint256) {
        return _timestamps[id];
    }

    // ----------------------------------------------------------------------
    //                              Schedule
    // ----------------------------------------------------------------------

    /// @notice Schedule an operation for later execution.
    /// @dev Only PROPOSER_ROLE. Enforces `eta >= block.timestamp + minDelay`,
    ///      so no operation can be made executable before the mandatory delay.
    ///      Mirrors OZ `schedule`, but takes an explicit absolute `eta` rather
    ///      than a relative delay, per the task interface schedule(target,data,eta).
    /// @param target      Contract to call.
    /// @param value       Native value to forward.
    /// @param data        Calldata for the call.
    /// @param predecessor Optional dependency op id that must be done first (0 = none).
    /// @param salt        Disambiguation salt for otherwise-identical operations.
    /// @param eta         Absolute earliest execution timestamp.
    /// @return id The operation id.
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 eta
    ) external onlyRole(PROPOSER_ROLE) returns (bytes32 id) {
        require(target != address(0), "RnxTimelock: target is zero");
        id = hashOperation(target, value, data, predecessor, salt);
        require(_timestamps[id] == 0, "RnxTimelock: operation already scheduled");
        require(eta >= block.timestamp + minDelay, "RnxTimelock: insufficient delay");

        _timestamps[id] = eta;
        emit CallScheduled(id, target, value, data, predecessor, salt, eta);
    }

    // ----------------------------------------------------------------------
    //                               Cancel
    // ----------------------------------------------------------------------

    /// @notice Cancel a scheduled (not-yet-executed) operation.
    /// @dev Only PROPOSER_ROLE, mirroring OZ `cancel`. A done operation cannot
    ///      be cancelled.
    function cancel(bytes32 id) external onlyRole(PROPOSER_ROLE) {
        require(isOperationPending(id), "RnxTimelock: operation cannot be cancelled");
        delete _timestamps[id];
        emit Cancelled(id);
    }

    // ----------------------------------------------------------------------
    //                              Execute
    // ----------------------------------------------------------------------

    /// @notice Execute a ready operation.
    /// @dev Only EXECUTOR_ROLE. Reverts if the operation is not ready (delay not
    ///      elapsed) or if a declared predecessor has not completed. Follows
    ///      checks-effects-interactions: the operation is marked DONE before the
    ///      external call, and the whole function is nonReentrant, so a malicious
    ///      target cannot replay the same operation.
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external payable onlyRole(EXECUTOR_ROLE) nonReentrant returns (bytes32 id) {
        id = hashOperation(target, value, data, predecessor, salt);

        // CHECKS
        require(isOperationReady(id), "RnxTimelock: operation is not ready");
        if (predecessor != bytes32(0)) {
            require(isOperationDone(predecessor), "RnxTimelock: missing dependency");
        }

        // EFFECTS — mark done before interaction (replay/reentrancy protection).
        _timestamps[id] = _DONE_TIMESTAMP;

        // INTERACTIONS
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            // bubble up revert reason if present
            if (ret.length > 0) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            revert("RnxTimelock: underlying call reverted");
        }

        emit CallExecuted(id, target, value, data);
    }
}
