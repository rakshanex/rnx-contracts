// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title AgentRegistry — self-sovereign AI agent identity registry
/// @notice Lets any EOA register one or more AI-agent identities on-chain. Each
///         agent is addressed by a deterministic `agentId` (bytes32) derived
///         from (owner, label). The registry records:
///           - the owning EOA,
///           - an OPTIONAL VERIDEX commitment hash binding (bytes32) so an agent
///             identity can be cryptographically tied to an off-chain VERIDEX
///             commitment,
///           - a metadata URI (e.g. ipfs:// or https:// agent card),
///           - active / revoked status.
///
/// @dev    DESIGN / ROLE MODEL (explicit, documented, no hidden powers):
///           - There is NO contract owner, admin, or operator role.
///           - There is NO backdoor to revoke, re-point, or seize an agent.
///           - ONLY the registering owner EOA may update or revoke ITS OWN
///             agent. This is enforced purely by `msg.sender` checks.
///           - Revocation is one-way and permanent (an agentId cannot be
///             re-activated or re-registered after revocation). This prevents
///             identity recycling / impersonation.
///
///         This contract holds no funds and has no payable functions.
///
///         Written in the OpenZeppelin / Solidity-idiom style. It uses no
///         external libraries and no proprietary code. The ownership-check
///         pattern (per-record `msg.sender == record.owner`) mirrors the
///         well-known OpenZeppelin `Ownable` access-control idiom
///         (https://docs.openzeppelin.com/contracts/5.x/access-control),
///         applied here per-record rather than contract-wide so there is no
///         single privileged account.
contract AgentRegistry {
    // ----------------------------------------------------------------------
    //                                Types
    // ----------------------------------------------------------------------

    /// @dev On-chain record for a single agent identity.
    struct Agent {
        address owner;          // registering EOA; the sole authority over this agent
        bytes32 veridexCommit;  // OPTIONAL VERIDEX commitment hash (bytes32(0) == none)
        string metadataURI;     // off-chain agent descriptor (e.g. ipfs://, https://)
        bool registered;        // true once registered (distinguishes "never existed")
        bool revoked;           // true once revoked (one-way, permanent)
    }

    // ----------------------------------------------------------------------
    //                               Storage
    // ----------------------------------------------------------------------

    /// @notice agentId => Agent record.
    mapping(bytes32 => Agent) private _agents;

    // ----------------------------------------------------------------------
    //                                Events
    // ----------------------------------------------------------------------

    /// @notice Emitted when a new agent identity is registered.
    event AgentRegistered(
        bytes32 indexed agentId,
        address indexed owner,
        bytes32 veridexCommit,
        string metadataURI
    );

    /// @notice Emitted when an agent's VERIDEX commitment binding is set/updated
    ///         by its owner (binding can only be set while active).
    event AgentCommitmentUpdated(bytes32 indexed agentId, bytes32 veridexCommit);

    /// @notice Emitted when an agent's metadata URI is updated by its owner.
    event AgentMetadataUpdated(bytes32 indexed agentId, string metadataURI);

    /// @notice Emitted when an agent is revoked by its owner. One-way.
    event AgentRevoked(bytes32 indexed agentId, address indexed owner);

    // ----------------------------------------------------------------------
    //                              ID derivation
    // ----------------------------------------------------------------------

    /// @notice Deterministically derive the agentId for a given owner + label.
    /// @dev Pure function; callers can precompute the id off-chain. Binding the
    ///      owner into the id means two different EOAs can use the same label
    ///      without colliding, and an EOA cannot squat another EOA's id space.
    function computeAgentId(address owner, bytes32 label) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, label));
    }

    // ----------------------------------------------------------------------
    //                              Registration
    // ----------------------------------------------------------------------

    /// @notice Register a new agent identity owned by `msg.sender`.
    /// @param label        Caller-chosen label; combined with msg.sender to form the id.
    /// @param veridexCommit Optional VERIDEX commitment hash (pass bytes32(0) for none).
    /// @param metadataURI  Off-chain agent descriptor URI.
    /// @return agentId     The derived identifier for the new agent.
    /// @dev Reverts if an agent with the derived id was ever registered (whether
    ///      currently active or already revoked) — ids are never recycled.
    function registerAgent(
        bytes32 label,
        bytes32 veridexCommit,
        string calldata metadataURI
    ) external returns (bytes32 agentId) {
        agentId = computeAgentId(msg.sender, label);
        Agent storage a = _agents[agentId];
        require(!a.registered, "AgentRegistry: already registered");

        a.owner = msg.sender;
        a.veridexCommit = veridexCommit;
        a.metadataURI = metadataURI;
        a.registered = true;
        a.revoked = false;

        emit AgentRegistered(agentId, msg.sender, veridexCommit, metadataURI);
    }

    // ----------------------------------------------------------------------
    //                        Owner-only mutations
    // ----------------------------------------------------------------------

    /// @notice Set or update the VERIDEX commitment binding for an agent.
    /// @dev Only the agent's owner may call; only while the agent is active.
    function setVeridexCommitment(bytes32 agentId, bytes32 veridexCommit) external {
        Agent storage a = _agents[agentId];
        require(a.registered, "AgentRegistry: unknown agent");
        require(a.owner == msg.sender, "AgentRegistry: not agent owner");
        require(!a.revoked, "AgentRegistry: agent revoked");

        a.veridexCommit = veridexCommit;
        emit AgentCommitmentUpdated(agentId, veridexCommit);
    }

    /// @notice Update the off-chain metadata URI for an agent.
    /// @dev Only the agent's owner may call; only while the agent is active.
    function setMetadataURI(bytes32 agentId, string calldata metadataURI) external {
        Agent storage a = _agents[agentId];
        require(a.registered, "AgentRegistry: unknown agent");
        require(a.owner == msg.sender, "AgentRegistry: not agent owner");
        require(!a.revoked, "AgentRegistry: agent revoked");

        a.metadataURI = metadataURI;
        emit AgentMetadataUpdated(agentId, metadataURI);
    }

    /// @notice Revoke an agent identity. One-way and permanent.
    /// @dev ONLY the agent's owner may revoke. There is no admin override. A
    ///      revoked agent can never be re-activated or re-registered.
    function revokeAgent(bytes32 agentId) external {
        Agent storage a = _agents[agentId];
        require(a.registered, "AgentRegistry: unknown agent");
        require(a.owner == msg.sender, "AgentRegistry: not agent owner");
        require(!a.revoked, "AgentRegistry: already revoked");

        a.revoked = true;
        emit AgentRevoked(agentId, msg.sender);
    }

    // ----------------------------------------------------------------------
    //                                 Views
    // ----------------------------------------------------------------------

    /// @notice Return the full record for an agent.
    function getAgent(bytes32 agentId)
        external
        view
        returns (
            address owner,
            bytes32 veridexCommit,
            string memory metadataURI,
            bool registered,
            bool revoked
        )
    {
        Agent storage a = _agents[agentId];
        return (a.owner, a.veridexCommit, a.metadataURI, a.registered, a.revoked);
    }

    /// @notice True iff the agent exists and has NOT been revoked.
    function isActive(bytes32 agentId) external view returns (bool) {
        Agent storage a = _agents[agentId];
        return a.registered && !a.revoked;
    }

    /// @notice Convenience: owner EOA of an agent (address(0) if unknown).
    function ownerOf(bytes32 agentId) external view returns (address) {
        return _agents[agentId].owner;
    }
}
