// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title AuditAnchor — AgentTrace audit-trail anchor for the RNX economy
/// @notice Minimal, append-only anchor store for AgentTrace batch commitments.
///         AgentTrace produces a tamper-evident chain of AI-agent events
///         off-chain. Periodically a batch of those events is reduced to a single
///         Merkle root (`batchRoot`) and anchored here together with the previous
///         anchored root (`prevRoot`) and a strictly increasing sequence number
///         (`seq`). The on-chain record is EVIDENCE ONLY — it lets any independent
///         verifier prove (a) that a given batch root existed at/after a given
///         block, and (b) that batches form an unbroken hash-linked chain.
///
///         Explicit scope / non-goals (documented roles):
///           - This contract is NOT the source of truth. The canonical event log
///             lives off-chain in AgentTrace; this is a one-way commitment sink.
///           - It stores ONLY hashes (32-byte roots). It never stores raw agent
///             logs, prompts, outputs, or any PII. Privacy is preserved by design:
///             nothing here can be reversed into event content.
///           - It performs NO access control over AgentTrace itself, NO DNS/registry
///             mutation, NO token movement, NO ownership transfer. An anchor is
///             evidence, not control.
///
///         Security properties (NO backdoors):
///           - Single `writer`, set once at construction, `immutable`, and NOT
///             transferable. There is no owner, no admin, no pause, no upgrade,
///             no selfdestruct, and no function that can mutate or delete a
///             previously anchored record. To rotate the writer key you MUST
///             redeploy — a deliberate, auditable, HUMAN-GATED action.
///           - No hidden mint / no drain: this contract holds no tokens and has
///             no payable or value-moving path.
///           - No reentrancy surface: all state writes are to local storage and
///             there are NO external calls, so no reentrancy guard is required
///             (documented explicitly rather than adding dead code). The
///             strictly-increasing `seq` check additionally prevents replay.
///
/// @dev    Pattern source / attribution:
///           - Hash-linked append-only log (`prevRoot` chaining) follows the
///             classic tamper-evident / hash-chain construction described by
///             Haber & Stornetta, "How to Time-Stamp a Digital Document" (1991),
///             and the Certificate-Transparency Merkle-log model (RFC 6962).
///           - The immutable-single-writer anchor shape mirrors this repo's own
///             BiharDomainRegistry.sol (contracts/BiharDomainRegistry.sol).
///           - Merkle-proof verification helper uses the standard OpenZeppelin
///             MerkleProof pair-hashing convention (sorted pairs, keccak256);
///             re-implemented inline here to avoid an external dependency. See
///             OpenZeppelin Contracts `utils/cryptography/MerkleProof.sol` (MIT).
///
///         Target chain identity (reference only — NOT deployed by this repo):
///           - New AgentTrace anchors target RNX Public Mainnet chainId 194151
///             (0x2F667), which is a FUTURE mainnet and not live.
///           - Legacy private chain 12345 is historical and unchanged; economy /
///             AgentTrace work does NOT target it.
contract AuditAnchor {
    /// @notice The single authorized anchor writer (the AgentTrace anchor service
    ///         account). Set once at construction; NOT transferable. Redeploy to
    ///         rotate — a HUMAN-GATED operation. There is intentionally no admin.
    address public immutable writer;

    struct Batch {
        bytes32 batchRoot;   // Merkle root of the AgentTrace event batch
        bytes32 prevRoot;    // root of the immediately preceding anchored batch
        uint256 blockNumber; // block at which this batch was anchored
    }

    /// @dev Monotonic sequence counter. The next accepted anchor MUST use
    ///      exactly `nextSeq`. Starts at 0 for the genesis batch.
    uint256 public nextSeq;

    /// @dev The most recently anchored batch root (zero before genesis). Used to
    ///      enforce the hash-link: each new anchor must cite this as `prevRoot`.
    bytes32 public latestRoot;

    /// @dev Full chain of anchored batches, indexed by sequence number. History
    ///      is append-only and never overwritten; the Anchored event log mirrors
    ///      it for cheap off-chain reconstruction.
    mapping(uint256 => Batch) private _batches;

    /// @notice Emitted for every accepted anchor. Fully indexed for log queries.
    /// @dev Signature: Anchored(uint256,bytes32,bytes32,uint256)
    event Anchored(
        uint256 indexed seq,
        bytes32 indexed batchRoot,
        bytes32 indexed prevRoot,
        uint256 blockNumber
    );

    error NotWriter();
    error ZeroBatchRoot();
    error NonMonotonicSeq(uint256 provided, uint256 expected);
    error PrevRootMismatch(bytes32 provided, bytes32 expected);

    constructor(address writer_) {
        require(writer_ != address(0), "writer=0");
        writer = writer_;
    }

    /// @notice Anchor one AgentTrace batch. Writer-only, append-only.
    /// @param batchRoot Merkle root over the batch's canonical event hashes.
    /// @param prevRoot  Root of the previous anchored batch; MUST equal the
    ///                  current `latestRoot` (bytes32(0) for the genesis batch).
    /// @param seq       Sequence number; MUST equal the current `nextSeq`.
    /// @dev Enforces: writer authorization, non-zero batchRoot, strictly
    ///      increasing seq (replay/reorder guard), and an unbroken prevRoot
    ///      hash-link. No external calls => no reentrancy path.
    function anchor(bytes32 batchRoot, bytes32 prevRoot, uint256 seq) external {
        if (msg.sender != writer) revert NotWriter();
        if (batchRoot == bytes32(0)) revert ZeroBatchRoot();
        if (seq != nextSeq) revert NonMonotonicSeq(seq, nextSeq);
        if (prevRoot != latestRoot) revert PrevRootMismatch(prevRoot, latestRoot);

        _batches[seq] = Batch({
            batchRoot: batchRoot,
            prevRoot: prevRoot,
            blockNumber: block.number
        });

        latestRoot = batchRoot;
        unchecked {
            nextSeq = seq + 1; // bounded by uint256; practically unreachable
        }

        emit Anchored(seq, batchRoot, prevRoot, block.number);
    }

    /// @notice Read an anchored batch by sequence number (read-only).
    /// @return batchRoot stored Merkle root (zero if seq not yet anchored)
    /// @return prevRoot  cited previous root
    /// @return blockNumber block of the anchor
    function getBatch(uint256 seq)
        external
        view
        returns (bytes32 batchRoot, bytes32 prevRoot, uint256 blockNumber)
    {
        Batch storage b = _batches[seq];
        return (b.batchRoot, b.prevRoot, b.blockNumber);
    }

    /// @notice Pure Merkle-proof check: is `leaf` contained under `root`?
    /// @dev Convenience/evidence helper for on-chain verifiers. Uses the standard
    ///      sorted-pair keccak256 convention (OpenZeppelin MerkleProof, MIT). The
    ///      caller is responsible for computing `leaf` from the canonical event
    ///      hash the same way the batch builder did. This function stores nothing
    ///      and moves no value.
    function verifyInclusion(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) external pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            computed = computed <= p
                ? keccak256(abi.encodePacked(computed, p))
                : keccak256(abi.encodePacked(p, computed));
        }
        return computed == root;
    }
}
