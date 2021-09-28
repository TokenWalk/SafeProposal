// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity ^0.8.6;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "../interfaces/IProposal.sol";

/// @title OpenZeppelin Linear Voting Strategy - A Seele module that enables compount like voting.
/// @author Nathan Ginnever - <team@tokenwalk.org>
contract OZLinearVoting is EIP712 {
    bytes32 public constant VOTE_TYPEHASH =
        keccak256("Vote(uint256 proposalId,uint8 vote)");

    enum VoteType {
        Against,
        For,
        Abstain
    }

    struct ProposalVoting {
        uint256 yesVotes; // the total number of YES votes for this proposal
        uint256 noVotes; // the total number of NO votes for this proposal
        uint256 abstainVotes; // introduce abstain votes
        uint256 deadline; // voting deadline TODO: consider using block number
        uint256 startBlock; // the starting block of the proposal
        mapping(address => bool) hasVoted;
    }

    ERC20Votes public immutable governanceToken;
    uint256 public votingPeriod; // the length of time voting is valid for a proposal
    address public seeleModule;
    uint256 public quorumThreshold; // minimum number of votes for proposal to succeed
    /// @dev Address that this module will pass transactions to.
    address public avatar;
    string private _name;

    mapping(address => uint256) public nonces;
    mapping(uint256 => ProposalVoting) public proposals;

    modifier onlyAvatar() {
        require(msg.sender == avatar, "TW001");
        _;
    }

    modifier onlySeele() {
        require(msg.sender == seeleModule, "only seele module may enter");
        _;
    }

    constructor(
        uint256 _votingPeriod,
        ERC20Votes _governanceToken,
        address _seeleModule,
        uint256 _quorumThreshold,
        address _avatar,
        string memory name_
    ) EIP712(name_, version()) {
        votingPeriod = _votingPeriod * 1 seconds; // switch to hours in prod
        governanceToken = _governanceToken;
        seeleModule = _seeleModule;
        quorumThreshold = _quorumThreshold;
        avatar = _avatar;
        _name = name_;
    }

    /// @dev ERC712 name.
    function name() public view virtual returns (string memory) {
        return _name;
    }

    ///@dev ERC712 version.
    function version() public view virtual returns (string memory) {
        return "1";
    }

    function getThreshold() external view returns (uint256) {
        return quorumThreshold;
    }

    /// @dev Sets the executor to a new account (`newExecutor`).
    /// @notice Can only be called by the current owner.
    function setAvatar(address _avatar) public onlyAvatar {
        avatar = _avatar;
    }

    /// @dev Updates the quorum needed to pass a proposal, only executor.
    /// @param _quorumThreshold the voting quorum threshold.
    function updateThreshold(uint256 _quorumThreshold) external onlyAvatar {
        quorumThreshold = _quorumThreshold;
    }

    /// @dev Updates the time that proposals are active for voting.
    /// @return votingPeriod time window.
    function getVotingPeriod() public view returns (uint256) {
        return votingPeriod;
    }

    /// @dev Updates the time that proposals are active for voting.
    /// @param newPeriod the voting window.
    function updateVotingPeriod(uint256 newPeriod) external onlyAvatar {
        votingPeriod = newPeriod;
    }

    /// @dev Returns true if an account has voted on a specific proposal.
    /// @param proposalId the proposal to inspect.
    /// @param account the account to inspect.
    /// @return boolean.
    function hasVoted(uint256 proposalId, address account)
        public
        view
        returns (bool)
    {
        return proposals[proposalId].hasVoted[account];
    }

    /// @dev Submits a vote for a proposal.
    /// @param proposalId the proposal to vote for.
    /// @param support against, for, or abstain.
    function vote(uint256 proposalId, uint8 support) external {
        _vote(proposalId, msg.sender, support);
    }

    /// @dev Submits a vote for a proposal by ERC712 signature.
    /// @param proposalId the proposal to vote for.
    /// @param support against, for, or abstain.
    /// @param v the Signature v value.
    /// @param r the Signature r value.
    /// @param s the Signature s value.
    function voteSignature(
        uint256 proposalId,
        uint8 support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        address voter = ECDSA.recover(
            _hashTypedDataV4(
                keccak256(abi.encode(VOTE_TYPEHASH, proposalId, support))
            ),
            v,
            r,
            s
        );
        _vote(proposalId, voter, support);
    }

    function _vote(
        uint256 proposalId,
        address voter,
        uint8 support
    ) internal {
        require(
            block.timestamp <= proposals[proposalId].deadline,
            "voting period has passed"
        );
        require(!hasVoted(proposalId, voter), "voter has already voted");
        uint256 weight = calculateWeight(
            msg.sender,
            proposals[proposalId].startBlock
        );
        proposals[proposalId].hasVoted[voter] = true;
        if (support == uint8(VoteType.Against)) {
            proposals[proposalId].noVotes =
                proposals[proposalId].noVotes +
                weight;
        } else if (support == uint8(VoteType.For)) {
            proposals[proposalId].yesVotes =
                proposals[proposalId].yesVotes +
                weight;
        } else if (support == uint8(VoteType.Abstain)) {
            proposals[proposalId].abstainVotes =
                proposals[proposalId].abstainVotes +
                weight;
        } else {
            revert("invalid value for enum VoteType");
        }
    }

    /// @dev Called by the proposal module, this notifes the strategy of a new proposal.
    /// @param proposalId the proposal to vote for.
    function receiveProposal(uint256 proposalId) public onlySeele {
        proposals[proposalId].deadline = votingPeriod + block.timestamp;
        proposals[proposalId].startBlock = block.number;
    }

    /// @dev Calls the proposal module to notify that a quorum has been reached.
    /// @param proposalId the proposal to vote for.
    function finalizeVote(uint256 proposalId) public {
        if (isPassed(proposalId)) {
            IProposal(seeleModule).startTimeLock(proposalId);
        }
    }

    /// @dev Determines if a proposal has succeeded.
    /// @param proposalId the proposal to vote for.
    /// @return boolean.
    function isPassed(uint256 proposalId) public view returns (bool) {
        require(
            proposals[proposalId].yesVotes > proposals[proposalId].noVotes,
            "the yesVotes must be strictly over the noVotes"
        );
        require(
            proposals[proposalId].yesVotes +
                proposals[proposalId].abstainVotes >=
                quorumThreshold,
            "a quorum has not been reached for the proposal"
        );
        require(
            proposals[proposalId].deadline < block.timestamp,
            "voting period has not passed yet"
        );
        return true;
    }

    function calculateWeight(address delegatee, uint256 blockNumber)
        public
        view
        returns (uint256)
    {
        return governanceToken.getPastVotes(delegatee, blockNumber);
    }

    /// @dev Returns the chain id used by this contract.
    function getChainId() public view returns (uint256) {
        uint256 id;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            id := chainid()
        }
        return id;
    }
}