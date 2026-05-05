// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  UniqueRegistry
 * @notice The heart of UNIQUE - one token name, one contract, forever.
 * @dev    Deployed on BNBChain.
 *
 * THREE REGISTRATION PATHS:
 * 1. Via partner launchpad  - 0.1 BNB
 *    (0.05 BNB auto-split to launchpad, 0.05 to protocol)
 * 2. OG Verified (direct)   - 0.05 BNB
 *    Manual verification by owner. Existing projects only.
 *    Stamp: "Certified UNIQUE (TM) - OG Verified"
 * 3. Official certification  - UNIQUE Protocol
 *    Reserved for UNIQUE Protocol official use.
 *
 * Security:
 * - ReentrancyGuard on all payable functions
 * - Checks-Effects-Interactions pattern
 * - 48h TimeLock on fee changes and ownership transfer
 * - Fee bounds (MIN / MAX)
 * - No Chainlink dependency - fees fixed in BNB
 */
contract UniqueRegistry {

    // Stamps
    string public constant STAMP_STANDARD = "Certified UNIQUE (TM)";
    string public constant STAMP_OG       = "Certified UNIQUE (TM) - OG Verified - Original Project";

    // Reentrancy guard
    uint8 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "UNIQUE: reentrant call");
        _locked = 2;
        _;
        _locked = 1;
    }

    // Fees
    uint256 public partnerFee = 0.1 ether;   // Via partner launchpad
    uint256 public ogFee      = 0.05 ether;  // OG Verified direct

    uint256 public constant MIN_FEE = 0.01 ether;
    uint256 public constant MAX_FEE = 10 ether;

    // TimeLock - 48h on fee & ownership changes
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    struct PendingFeeChange {
        uint256 newPartnerFee;
        uint256 newOgFee;
        uint256 executableAt;
        bool    exists;
    }
    PendingFeeChange public pendingFeeChange;

    struct PendingOwnerChange {
        address newOwner;
        uint256 executableAt;
        bool    exists;
    }
    PendingOwnerChange public pendingOwnerChange;

    // Token record storage
    struct TokenRecord {
        address contractAddress;
        address deployer;
        uint256 launchedAt;
        string  name;
        string  ticker;
        string  launchpad;
        string  stamp;
        string  evidence;
        bool    exists;
    }

    mapping(string => TokenRecord) private _records;
    string[] public allTickers;

    // Tier 0 = not authorized
    // Tier 1 = partner launchpad (partnerFee, auto-split)
    // Tier 2 = OG Verified portal (ogFee, direct)
    mapping(address => uint8)  public launchpadTier;
    mapping(address => string) public launchpadName;

    address public owner;
    uint256 public collectedFees;

    // Events
    event TokenRegistered(
        string indexed ticker,
        string  name,
        address indexed contractAddress,
        address indexed deployer,
        uint256 launchedAt,
        string  launchpad,
        string  stamp
    );

    event OGVerified(
        string indexed ticker,
        string  name,
        address contractAddress,
        string  evidence
    );

    event LaunchpadAuthorized(address indexed launchpad, uint8 tier, string name);
    event LaunchpadRevoked(address indexed launchpad);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event FeeChangeProposed(uint256 newPartnerFee, uint256 newOgFee, uint256 executableAt);
    event FeeChangeExecuted(uint256 newPartnerFee, uint256 newOgFee);
    event FeeChangeCancelled();
    event OwnershipTransferProposed(address indexed newOwner, uint256 executableAt);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "UNIQUE: not owner");
        _;
    }

    modifier onlyAuthorized() {
        require(launchpadTier[msg.sender] > 0, "UNIQUE: not authorized");
        _;
    }

    // Constructor
    constructor() {
        owner = msg.sender;
    }

    // Admin - launchpad management

    function authorizePartner(address launchpad, string calldata name) external onlyOwner {
        require(launchpad != address(0), "UNIQUE: zero address");
        require(bytes(name).length > 0,  "UNIQUE: empty name");
        launchpadTier[launchpad] = 1;
        launchpadName[launchpad] = name;
        emit LaunchpadAuthorized(launchpad, 1, name);
    }

    function authorizeOGPortal(address portal) external onlyOwner {
        require(portal != address(0), "UNIQUE: zero address");
        launchpadTier[portal] = 2;
        launchpadName[portal] = "UNIQUE OG";
        emit LaunchpadAuthorized(portal, 2, "UNIQUE OG");
    }

    function revoke(address launchpad) external onlyOwner {
        launchpadTier[launchpad] = 0;
        delete launchpadName[launchpad];
        emit LaunchpadRevoked(launchpad);
    }

    // PATH 1 - Partner launchpad registration
    // Fee: 0.1 BNB -> 0.05 to launchpad, 0.05 to protocol

    function register(
        string calldata name,
        string calldata ticker,
        address contractAddress,
        address deployer
    ) external payable onlyAuthorized nonReentrant {

        require(launchpadTier[msg.sender] == 1, "UNIQUE: use OG path");
        require(msg.value >= partnerFee,         "UNIQUE: insufficient fee");

        string memory normalized = _normalize(ticker);
        require(!_records[normalized].exists,    "UNIQUE: ticker already taken");
        require(bytes(name).length > 0,          "UNIQUE: empty name");
        require(bytes(ticker).length >= 2,       "UNIQUE: ticker too short");
        require(bytes(ticker).length <= 10,      "UNIQUE: ticker too long");
        require(contractAddress != address(0),   "UNIQUE: zero address");
        require(deployer != address(0),          "UNIQUE: zero deployer");

        string memory pad = launchpadName[msg.sender];
        uint256 protocolShare  = partnerFee / 2;
        uint256 launchpadShare = partnerFee - protocolShare;

        _records[normalized] = TokenRecord({
            contractAddress: contractAddress,
            deployer:        deployer,
            launchedAt:      block.timestamp,
            name:            name,
            ticker:          ticker,
            launchpad:       pad,
            stamp:           STAMP_STANDARD,
            evidence:        "",
            exists:          true
        });

        allTickers.push(normalized);
        collectedFees += protocolShare;

        emit TokenRegistered(normalized, name, contractAddress, deployer, block.timestamp, pad, STAMP_STANDARD);

        (bool ok1, ) = msg.sender.call{value: launchpadShare}("");
        require(ok1, "UNIQUE: launchpad split failed");

        uint256 excess = msg.value - partnerFee;
        if (excess > 0) {
            (bool ok2, ) = tx.origin.call{value: excess}("");
            require(ok2, "UNIQUE: refund failed");
        }
    }

    // PATH 2 - OG Verified direct registration
    // Fee: 0.05 BNB -> 100% to protocol

    function registerOG(
        string calldata name,
        string calldata ticker,
        address contractAddress,
        address deployer,
        string calldata evidence
    ) external payable onlyAuthorized nonReentrant {

        require(launchpadTier[msg.sender] == 2, "UNIQUE: use partner path");
        require(msg.value >= ogFee,              "UNIQUE: insufficient fee");

        string memory normalized = _normalize(ticker);
        require(!_records[normalized].exists,    "UNIQUE: ticker already taken");
        require(bytes(name).length > 0,          "UNIQUE: empty name");
        require(bytes(ticker).length >= 2,       "UNIQUE: ticker too short");
        require(bytes(ticker).length <= 10,      "UNIQUE: ticker too long");
        require(contractAddress != address(0),   "UNIQUE: zero address");
        require(deployer != address(0),          "UNIQUE: zero deployer");
        require(bytes(evidence).length > 0,      "UNIQUE: evidence required");

        _records[normalized] = TokenRecord({
            contractAddress: contractAddress,
            deployer:        deployer,
            launchedAt:      block.timestamp,
            name:            name,
            ticker:          ticker,
            launchpad:       "UNIQUE OG",
            stamp:           STAMP_OG,
            evidence:        evidence,
            exists:          true
        });

        allTickers.push(normalized);
        collectedFees += msg.value;

        emit TokenRegistered(normalized, name, contractAddress, deployer, block.timestamp, "UNIQUE OG", STAMP_OG);
        emit OGVerified(normalized, name, contractAddress, evidence);

        uint256 excess = msg.value - ogFee;
        if (excess > 0) {
            (bool ok, ) = tx.origin.call{value: excess}("");
            require(ok, "UNIQUE: refund failed");
        }
    }

    // PATH 3 - Official certification by UNIQUE Protocol

    function certifyRecord(
        string calldata name,
        string calldata ticker,
        address contractAddress,
        address deployer,
        string calldata evidence
    ) external onlyOwner {

        string memory normalized = _normalize(ticker);
        require(!_records[normalized].exists,  "UNIQUE: ticker already taken");
        require(bytes(name).length > 0,        "UNIQUE: empty name");
        require(bytes(ticker).length >= 2,     "UNIQUE: ticker too short");
        require(bytes(ticker).length <= 10,    "UNIQUE: ticker too long");
        require(contractAddress != address(0), "UNIQUE: zero address");
        require(deployer != address(0),        "UNIQUE: zero deployer");

        _records[normalized] = TokenRecord({
            contractAddress: contractAddress,
            deployer:        deployer,
            launchedAt:      block.timestamp,
            name:            name,
            ticker:          ticker,
            launchpad:       "UNIQUE Certified",
            stamp:           STAMP_OG,
            evidence:        evidence,
            exists:          true
        });

        allTickers.push(normalized);

        emit TokenRegistered(normalized, name, contractAddress, deployer, block.timestamp, "UNIQUE Certified", STAMP_OG);
        emit OGVerified(normalized, name, contractAddress, evidence);
    }

    // TimeLock - fee changes (48h)

    function proposeFeeChange(uint256 newPartnerFee, uint256 newOgFee) external onlyOwner {
        require(newPartnerFee >= MIN_FEE && newPartnerFee <= MAX_FEE, "UNIQUE: partner fee out of bounds");
        require(newOgFee >= MIN_FEE && newOgFee <= MAX_FEE,           "UNIQUE: OG fee out of bounds");
        require(newPartnerFee > newOgFee,                              "UNIQUE: partner fee must exceed OG fee");

        uint256 execAt = block.timestamp + TIMELOCK_DELAY;
        pendingFeeChange = PendingFeeChange({
            newPartnerFee: newPartnerFee,
            newOgFee:      newOgFee,
            executableAt:  execAt,
            exists:        true
        });
        emit FeeChangeProposed(newPartnerFee, newOgFee, execAt);
    }

    function executeFeeChange() external onlyOwner {
        require(pendingFeeChange.exists,                          "UNIQUE: no pending change");
        require(block.timestamp >= pendingFeeChange.executableAt, "UNIQUE: timelock active");
        partnerFee = pendingFeeChange.newPartnerFee;
        ogFee      = pendingFeeChange.newOgFee;
        delete pendingFeeChange;
        emit FeeChangeExecuted(partnerFee, ogFee);
    }

    function cancelFeeChange() external onlyOwner {
        require(pendingFeeChange.exists, "UNIQUE: no pending change");
        delete pendingFeeChange;
        emit FeeChangeCancelled();
    }

    // TimeLock - ownership transfer (48h)

    function proposeOwnerChange(address newOwner) external onlyOwner {
        require(newOwner != address(0), "UNIQUE: zero address");
        uint256 execAt = block.timestamp + TIMELOCK_DELAY;
        pendingOwnerChange = PendingOwnerChange({
            newOwner:     newOwner,
            executableAt: execAt,
            exists:       true
        });
        emit OwnershipTransferProposed(newOwner, execAt);
    }

    function executeOwnerChange() external onlyOwner {
        require(pendingOwnerChange.exists,                          "UNIQUE: no pending change");
        require(block.timestamp >= pendingOwnerChange.executableAt, "UNIQUE: timelock active");
        address old = owner;
        owner = pendingOwnerChange.newOwner;
        delete pendingOwnerChange;
        emit OwnershipTransferred(old, owner);
    }

    // Views

    function isTaken(string calldata ticker) external view returns (bool) {
        return _records[_normalize(ticker)].exists;
    }

    function getRecord(string calldata ticker) external view returns (TokenRecord memory) {
        return _records[_normalize(ticker)];
    }

    function getFee(address launchpad) external view returns (uint256) {
        uint8 tier = launchpadTier[launchpad];
        if (tier == 1) return partnerFee;
        if (tier == 2) return ogFee;
        return 0;
    }

    function totalRegistered() external view returns (uint256) {
        return allTickers.length;
    }

    // Withdraw

    function withdrawFees() external onlyOwner nonReentrant {
        uint256 amount = collectedFees;
        require(amount > 0, "UNIQUE: nothing to withdraw");
        collectedFees = 0;
        (bool ok, ) = owner.call{value: amount}("");
        require(ok, "UNIQUE: withdrawal failed");
        emit FeesWithdrawn(owner, amount);
    }

    // Internal

    function _normalize(string memory ticker) internal pure returns (string memory) {
        bytes memory b      = bytes(ticker);
        bytes memory result = new bytes(b.length);
        for (uint i = 0; i < b.length; i++) {
            if (b[i] >= 0x61 && b[i] <= 0x7A) {
                result[i] = bytes1(uint8(b[i]) - 32);
            } else {
                result[i] = b[i];
            }
        }
        return string(result);
    }

    receive() external payable {
        collectedFees += msg.value;
    }
}
