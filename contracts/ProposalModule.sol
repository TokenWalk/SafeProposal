// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import "./common/Enum.sol";

interface ISafe {
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation
    ) external returns (bool success);
}

interface IVoting {
    function calculateWeight(
        address delegate
    ) external view returns (uint);
}

contract ProposalModule {

    struct Proposal {
        uint256 value;
        uint256 yesVotes; // the total number of YES votes for this proposal
        uint256 noVotes; // the total number of NO votes for this proposal        
        bool executed;
        bool queued;
        uint deadline;
        address proposer;
        bool canceled;
        uint gracePeriod;
        mapping(address => bool) hasVoted;
        address targetAddress;
        bytes data;
        Enum.Operation operation;
    }

    uint private _totalProposalCount;
    uint private _proposalTime;
    uint private _gracePeriod = 60 seconds; //3 days;
    uint private _threshold;
    uint private _minimumProposalAmount; // amount of gov tokens needed to participate
    address private _safe;
    address private _votingModule;

    mapping(uint => Proposal) public proposals;
    mapping(address => bool) private _activeProposal;

    modifier onlySafe {
        require(msg.sender == _safe, "TW001");
        _;
    }

    modifier isPassed(uint proposalId) {
        require(proposals[proposalId].canceled == false, "TW002");
        require(proposals[proposalId].executed == false, "TW003");
        require(proposals[proposalId].yesVotes >= _threshold, "TW004");
        require(proposals[proposalId].yesVotes >= proposals[proposalId].noVotes, "TW005");
    	_;
    }

    event ProposalCreated(uint number);
    event GracePeriodStarted(uint endDate);
    event ProposalExecuted(uint id);

    constructor(
        address governanceToken_,
        address safe_,
        uint proposalTime_,
        uint threshold_,
        uint minimumProposalAmount_
    ) {
        _safe = safe_;
        _proposalTime = proposalTime_ * 1 minutes;//days;
        _threshold = threshold_;
        _minimumProposalAmount = minimumProposalAmount_;
    }

    // getters
    function threshold() public view virtual returns (uint) {
        return _threshold;
    }

    function totalProposalCount() public view virtual returns (uint) {
        return _totalProposalCount;
    }

    function gracePeriod() public view virtual returns (uint) {
        return _gracePeriod;
    }

    function proposalTime() public view virtual returns (uint) {
        return _proposalTime;
    }

    function minimumProposalAmount() public view virtual returns (uint) {
        return _minimumProposalAmount;
    }

    function safe() public view virtual returns(address) {
        return _safe;
    }

    function votingModule() public view virtual returns(address) {
        return _votingModule;
    }

    function registerVoteModule(address module) onlySafe external {
        _votingModule = module;
    }


    function vote(uint proposalId, bool vote) external {
        require(_votingModule != address(0), "TW006");
        require(proposals[proposalId].hasVoted[msg.sender] == false, "TW007");
        require(proposals[proposalId].canceled == false, "TW008");
        require(proposals[proposalId].executed == false, "TW009");
        require(proposals[proposalId].deadline >= block.timestamp, "TW010");

        // require voting module is registered
        proposals[proposalId].hasVoted[msg.sender] = true;

        if(vote == false){
            proposals[proposalId].noVotes = IVoting(_votingModule).calculateWeight(msg.sender);
        } else {
            proposals[proposalId].noVotes = IVoting(_votingModule).calculateWeight(msg.sender);
        }
    }

    // for now allow heads of house to update threshold
    function updateThreshold(uint threshold) onlySafe external {
    	_threshold = threshold;
    }

    // for now allow heads of house to update minimumProposalAmount
    function updateMinimumProposalAmount(uint minimumProposalAmount) onlySafe external {
    	_minimumProposalAmount = minimumProposalAmount;
    }

    // for now allow heads of house to update proposalTime
    function updateProposalTime(uint newTime) onlySafe external {
        _proposalTime = newTime;
    }

    // for now allow heads of house to update gracePeriod
    function updateGracePeriod(uint gracePeriod) onlySafe external {
        _gracePeriod = gracePeriod;
    }

    function submitModularProposal(
        address to,
        uint256 value,
        bytes memory data
        //Enum.Operation _operation
    ) public {
        uint total = IVoting(_votingModule).calculateWeight(msg.sender);
        require(_activeProposal[msg.sender] = false, "TW011");
        require(total >= _minimumProposalAmount, "TW012");
        // store calldata for tx to be executed
        proposals[_totalProposalCount].value = value;
        proposals[_totalProposalCount].yesVotes = total; // the total number of YES votes for this proposal    
        proposals[_totalProposalCount].deadline = block.timestamp + _proposalTime;
        proposals[_totalProposalCount].proposer = msg.sender;
        proposals[_totalProposalCount].hasVoted[msg.sender] = true;
        proposals[_totalProposalCount].targetAddress = to; // can switch target to contract and provide call data
        proposals[_totalProposalCount].data = data;
        proposals[_totalProposalCount].operation = Enum.Operation.Call;

        _activeProposal[msg.sender] = true;
        _totalProposalCount++;
        emit ProposalCreated(_totalProposalCount-1);
    }

    // Execute proposals
    function startModularQueue(uint proposalId) isPassed(proposalId) external {
        require(proposals[proposalId].gracePeriod == 0, "TW013");
        require(proposals[proposalId].deadline <= block.timestamp, "TW014");
        proposals[proposalId].gracePeriod = block.timestamp + _gracePeriod;
        emit GracePeriodStarted(proposals[proposalId].gracePeriod);
    }

    function executeModularProposal(uint proposalId) isPassed(proposalId) external {
        require(block.timestamp >= proposals[proposalId].gracePeriod && proposals[proposalId].gracePeriod != 0, "TW015");
        proposals[proposalId].executed = true;
        _activeProposal[proposals[proposalId].proposer] = false;
        ISafe(_safe).execTransactionFromModule(
            proposals[proposalId].targetAddress,
            proposals[proposalId].value,
            proposals[proposalId].data,
            proposals[proposalId].operation
        );
    }

    function cancelProposal(uint proposalId) external {
        require(proposals[proposalId].canceled == false, "TW016");
        require(proposals[proposalId].executed == false, "TW017");
        require(proposals[proposalId].deadline >= block.timestamp, "TW018");
        // proposal guardian can be put in the roles module
        require(proposals[proposalId].proposer == msg.sender || msg.sender == _safe, "TW019");
        proposals[proposalId].canceled = true;
        _activeProposal[proposals[proposalId].proposer] = false;
    }
}