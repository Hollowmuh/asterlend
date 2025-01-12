// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";

/**
 * @title ProtocolGovernance 
 * @notice Handles protocol governance with timelock and voting
 * @dev Integrates with NGNI token for voting power
 */
contract ProtocolGovernance is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    // Proposal states for easier tracking
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    // Proposal details struct
    struct ProposalDetails {
        address proposer;
        uint256 votingPower;
        uint256 startBlock;
        uint256 endBlock;
        string description;
        bool executed;
    }

    // Storage
    mapping(uint256 => ProposalDetails) public proposalDetails;
    
    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description
    );
    event ProposalExecuted(uint256 indexed proposalId);

    constructor(
        IVotes _token,
        TimelockController _timelock,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _quorumPercentage
    )
        Governor("ProtocolGovernance")
        GovernorSettings(
            _votingDelay,    // blocks before voting starts
            _votingPeriod,   // blocks voting stays open
            0                // minimum tokens to propose
        )
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(_quorumPercentage)
        GovernorTimelockControl(_timelock)
    {}

    /**
     * @notice Create a new proposal
     * @dev Overrides the governor propose function to add custom logic
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override returns (uint256) {
        uint256 proposalId = super.propose(
            targets,
            values,
            calldatas,
            description
        );

        proposalDetails[proposalId] = ProposalDetails({
            proposer: msg.sender,
            votingPower: getVotes(msg.sender, block.number - 1),
            startBlock: block.number + votingDelay(),
            endBlock: block.number + votingDelay() + votingPeriod(),
            description: description,
            executed: false
        });

        emit ProposalCreated(proposalId, msg.sender, description);
        return proposalId;
    }

    /**
     * @notice Execute a successful proposal
     * @dev Adds custom execution logic on top of base implementation
     */
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable override returns (uint256) {
        uint256 proposalId = super.execute(
            targets,
            values,
            calldatas,
            descriptionHash
        );
        
        ProposalDetails storage details = proposalDetails[proposalId];
        details.executed = true;
        
        emit ProposalExecuted(proposalId);
        return proposalId;
    }

    // Required overrides
    function votingDelay()
        public
        view
        override(IGovernor, GovernorSettings)
        returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public
        view
        override(IGovernor, GovernorSettings)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(IGovernor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return ProposalState(uint8(super.state(proposalId)));
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    )
        public
        override(Governor, IGovernor)
        returns (uint256)
    {
        return super.propose(targets, values, calldatas, description);
    }

    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._execute(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}