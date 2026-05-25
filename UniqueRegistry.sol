// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  UniqueRegistry V2
 * @notice The First Permanent On-Chain Ticker Standard on BNBChain
 *
 * THREE REGISTRATION PATHS:
 * 1. Via partner launchpad  — partnerFee (default 0.1 BNB), 50/50 split
 * 2. OG Verified            — ogFee (default 0.05 BNB), owner only
 * 3. Official record        — free, owner only
 *
 * V2 vs V1:
 * - Ticker: 1–20 Unicode chars (was 2–10 bytes)
 * - Unicode normalization: Latin a-z→A-Z, Cyrillic а-я→А-Я
 * - tx.origin → msg.sender for refunds
 * - Deployer in OGVerified event
 * - Dedicated STAMP_OFFICIAL for Path 3
 * - Revoke with 48h timelock
 * - Pre-launch reservation (7 days, fee = ogFee/2)
 * - Batch registration (max 50)
 * - Emergency pause
 * - Launchpad certification badge (double opt-in)
 * - Metadata (feature flag, off by default)
 * - Governance flag placeholder (off by default)
 * - Custom errors for minimal bytecode
 *
 * Note: Ticker Marketplace planned for V3.
 */

contract UniqueRegistryV2 {

    // ─── Custom Errors ───────────────────────────────────────────
    error NotOwner();
    error NotLaunchpad();
    error ContractPaused();
    error Reentrant();
    error InvalidAddress();
    error EmptyString();
    error TickerTooShort();
    error TickerTooLong();
    error TickerAlreadyTaken();
    error TickerNotRegistered();
    error NotCurrentOwner();
    error InsufficientFee();
    error TickerReservedByOther();
    error TickerAlreadyReserved();
    error NothingToWithdraw();
    error WithdrawalFailed();
    error LaunchpadSplitFailed();
    error RefundFailed();
    error RevokeNotScheduled();
    error TimelockActive();
    error NoPendingChange();
    error NoPendingRevoke();
    error FeeOutOfBounds();
    error PartnerMustExceedOG();
    error NotAuthorized();
    error NotCertifiedByUnique();
    error MetadataDisabled();
    error EmptyBatch();
    error BatchTooLarge();
    error LengthMismatch();

    // ─── Stamps ───────────────────────────────────────────────────
    string public constant STAMP_CERTIFIED = "Certified UNIQUE (TM) - Launched on Integrated Launchpad";
    string public constant STAMP_OG        = "Certified UNIQUE (TM) - OG Verified - Original Project";
    string public constant STAMP_OFFICIAL  = "Certified UNIQUE (TM) - Official Protocol Record";

    // ─── Constants ────────────────────────────────────────────────
    uint256 public constant MIN_FEE          = 0.01 ether;
    uint256 public constant MAX_FEE          = 10 ether;
    uint256 public constant TIMELOCK_DELAY   = 48 hours;
    uint256 public constant RESERVATION_DAYS = 7 days;
    uint256 public constant MIN_TICKER_CHARS = 1;
    uint256 public constant MAX_TICKER_CHARS = 20;
    uint256 public constant MAX_BATCH_SIZE   = 50;

    // ─── Reentrancy ───────────────────────────────────────────────
    uint8 private _locked = 1;
    modifier nonReentrant() {
        if (_locked != 1) revert Reentrant();
        _locked = 2; _; _locked = 1;
    }

    // ─── Structs ──────────────────────────────────────────────────
    struct TokenRecord {
        string  name;
        string  ticker;
        address contractAddress;
        address deployer;
        address currentOwner;
        address originalRegistrant;
        uint256 registeredAt;
        string  launchpad;
        string  stamp;
        string  evidence;
        bool    exists;
    }

    struct Reservation {
        address reserver;
        uint256 expiresAt;
        bool    active;
    }

    struct Metadata {
        string logoHash;
        string website;
        string description;
    }

    struct LaunchpadInfo {
        bool    authorized;
        bool    certifiedByUnique;
        bool    certificationAccepted;
        string  name;
        uint256 registrations;
    }

    struct PendingFeeChange {
        uint256 newPartnerFee;
        uint256 newOgFee;
        uint256 executableAt;
        bool    exists;
    }

    struct PendingOwnerChange {
        address newOwner;
        uint256 executableAt;
        bool    exists;
    }

    // ─── State ────────────────────────────────────────────────────
    address public owner;
    bool    public paused;
    bool    public metadataEnabled;
    bool    public governanceEnabled;

    uint256 public partnerFee    = 0.1  ether;
    uint256 public ogFee         = 0.05 ether;
    uint256 public collectedFees;
    uint256 public revokedCount;

    PendingFeeChange   public pendingFeeChange;
    PendingOwnerChange public pendingOwnerChange;

    mapping(string  => TokenRecord) private _records;
    mapping(string  => Reservation) private _reservations;
    mapping(string  => Metadata)    private _metadata;
    mapping(string  => uint256)     public  pendingRevoke;
    mapping(address => LaunchpadInfo) public launchpads;

    string[] public allTickers;

    // ─── Events ───────────────────────────────────────────────────
    event TokenRegistered(string indexed ticker, string name,
                          address contractAddress, address deployer,
                          address currentOwner, uint256 registeredAt,
                          string launchpad, string stamp);
    event OGVerified(string indexed ticker, string name,
                     address contractAddress, address deployer, string evidence);
    event OfficialRecord(string indexed ticker, string name,
                         address contractAddress, string evidence);
    event TickerReserved(string indexed ticker, address indexed reserver, uint256 expiresAt);
    event ReservationCleared(string indexed ticker);
    event LaunchpadAuthorized(address indexed launchpad, string name);
    event LaunchpadRevoked(address indexed launchpad);
    event LaunchpadCertified(address indexed launchpad);
    event RevokeScheduled(string indexed ticker, uint256 executableAt);
    event RevokeExecuted(string indexed ticker);
    event FeeChangeProposed(uint256 newPartnerFee, uint256 newOgFee, uint256 executableAt);
    event FeeChangeExecuted(uint256 newPartnerFee, uint256 newOgFee);
    event FeeChangeCancelled();
    event OwnershipTransferProposed(address indexed newOwner, uint256 executableAt);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event Paused();
    event Unpaused();
    event MetadataToggled(bool enabled);
    event GovernanceToggled(bool enabled);

    // ─── Modifiers ────────────────────────────────────────────────
    modifier onlyOwner()     { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyLaunchpad() { if (!launchpads[msg.sender].authorized) revert NotLaunchpad(); _; }
    modifier whenNotPaused() { if (paused) revert ContractPaused(); _; }

    // ─── Constructor ──────────────────────────────────────────────
    constructor() { owner = msg.sender; }

    // ─── Internal Helpers ─────────────────────────────────────────

    function _normalize(string memory input) internal pure returns (string memory) {
        bytes memory b      = bytes(input);
        bytes memory result = new bytes(b.length);
        uint256 i = 0;
        uint256 j = 0;
        while (i < b.length) {
            uint8 c = uint8(b[i]);
            if (c >= 0x61 && c <= 0x7A) {
                result[j] = bytes1(c - 32); i++; j++;
            } else if (c == 0xD0 && i + 1 < b.length) {
                uint8 c2 = uint8(b[i + 1]);
                if (c2 >= 0xB0 && c2 <= 0xBF) {
                    result[j] = bytes1(0xD0); result[j+1] = bytes1(c2 - 0x20);
                } else {
                    result[j] = b[i]; result[j+1] = b[i+1];
                }
                i += 2; j += 2;
            } else if (c == 0xD1 && i + 1 < b.length) {
                uint8 c2 = uint8(b[i + 1]);
                if (c2 >= 0x80 && c2 <= 0x8F) {
                    result[j] = bytes1(0xD0); result[j+1] = bytes1(c2 + 0x20);
                } else {
                    result[j] = b[i]; result[j+1] = b[i+1];
                }
                i += 2; j += 2;
            } else if (c < 0x80) {
                result[j] = b[i]; i++; j++;
            } else if (c < 0xE0) {
                if (i + 1 < b.length) { result[j]=b[i]; result[j+1]=b[i+1]; i+=2; j+=2; }
                else { i++; }
            } else if (c < 0xF0) {
                if (i + 2 < b.length) { result[j]=b[i]; result[j+1]=b[i+1]; result[j+2]=b[i+2]; i+=3; j+=3; }
                else { i++; }
            } else {
                if (i + 3 < b.length) { result[j]=b[i]; result[j+1]=b[i+1]; result[j+2]=b[i+2]; result[j+3]=b[i+3]; i+=4; j+=4; }
                else { i++; }
            }
        }
        bytes memory trimmed = new bytes(j);
        for (uint256 k = 0; k < j; k++) trimmed[k] = result[k];
        return string(trimmed);
    }

    function _charCount(bytes memory b) internal pure returns (uint256 count) {
        uint256 i = 0; count = 0;
        while (i < b.length) {
            uint8 c = uint8(b[i]);
            if      (c < 0x80) { i += 1; }
            else if (c < 0xE0) { i += 2; }
            else if (c < 0xF0) { i += 3; }
            else               { i += 4; }
            count++;
        }
    }

    function _validateTicker(string memory ticker) internal pure {
        bytes memory b = bytes(ticker);
        if (b.length == 0) revert EmptyString();
        uint256 chars = _charCount(b);
        if (chars < MIN_TICKER_CHARS) revert TickerTooShort();
        if (chars > MAX_TICKER_CHARS) revert TickerTooLong();
    }

    function _clearReservation(string memory normalized) internal {
        if (_reservations[normalized].active) {
            delete _reservations[normalized];
            emit ReservationCleared(normalized);
        }
    }

    // ─── Read Functions ───────────────────────────────────────────

    function isTaken(string calldata ticker) external view returns (bool) {
        return _records[_normalize(ticker)].exists;
    }

    function getRecord(string calldata ticker) external view returns (TokenRecord memory) {
        return _records[_normalize(ticker)];
    }

    function getReservation(string calldata ticker) external view returns (Reservation memory) {
        return _reservations[_normalize(ticker)];
    }

    function isReserved(string calldata ticker) external view returns (bool) {
        Reservation memory r = _reservations[_normalize(ticker)];
        return r.active && block.timestamp < r.expiresAt;
    }

    function getMetadata(string calldata ticker) external view returns (Metadata memory) {
        return _metadata[_normalize(ticker)];
    }

    function totalRegistered() external view returns (uint256) {
        return allTickers.length - revokedCount;
    }

    // ─── PATH 1: Launchpad Registration ──────────────────────────

    function register(
        string  calldata name,
        string  calldata ticker,
        address contractAddress,
        address deployer
    ) external payable onlyLaunchpad nonReentrant whenNotPaused {
        if (msg.value < partnerFee)        revert InsufficientFee();
        _validateTicker(ticker);
        if (bytes(name).length == 0)       revert EmptyString();
        if (contractAddress == address(0)) revert InvalidAddress();
        if (deployer == address(0))        revert InvalidAddress();

        string memory n = _normalize(ticker);
        if (_records[n].exists) revert TickerAlreadyTaken();

        Reservation memory res = _reservations[n];
        if (res.active && block.timestamp < res.expiresAt) {
            if (res.reserver != deployer && res.reserver != msg.sender) revert TickerReservedByOther();
        }
        _clearReservation(n);

        uint256 proto = partnerFee / 2;
        uint256 pad   = partnerFee - proto;
        collectedFees += proto;
        launchpads[msg.sender].registrations++;

        _records[n] = TokenRecord({
            name: name, ticker: n, contractAddress: contractAddress,
            deployer: deployer, currentOwner: deployer, originalRegistrant: deployer,
            registeredAt: block.timestamp, launchpad: launchpads[msg.sender].name,
            stamp: STAMP_CERTIFIED, evidence: "", exists: true
        });
        allTickers.push(n);

        emit TokenRegistered(n, name, contractAddress, deployer, deployer,
                             block.timestamp, launchpads[msg.sender].name, STAMP_CERTIFIED);

        (bool ok1,) = msg.sender.call{value: pad}("");
        if (!ok1) revert LaunchpadSplitFailed();

        uint256 excess = msg.value - partnerFee;
        if (excess > 0) { (bool ok2,) = msg.sender.call{value: excess}(""); if (!ok2) revert RefundFailed(); }
    }

    // ─── Batch Registration ───────────────────────────────────────

    function batchRegister(
        string[]  calldata names,
        string[]  calldata tickers,
        address[] calldata contractAddresses,
        address[] calldata deployers
    ) external payable onlyLaunchpad nonReentrant whenNotPaused {
        uint256 count = tickers.length;
        if (count == 0)               revert EmptyBatch();
        if (count > MAX_BATCH_SIZE)   revert BatchTooLarge();
        if (count != names.length || count != contractAddresses.length || count != deployers.length)
            revert LengthMismatch();
        if (msg.value < partnerFee * count) revert InsufficientFee();

        uint256 totalProto = 0;
        uint256 totalPad   = 0;
        string memory padName = launchpads[msg.sender].name;

        for (uint256 i = 0; i < count; i++) {
            (uint256 p, uint256 d) = _registerOne(names[i], tickers[i], contractAddresses[i], deployers[i], padName);
            totalProto += p; totalPad += d;
        }

        collectedFees += totalProto;
        launchpads[msg.sender].registrations += count;

        (bool ok1,) = msg.sender.call{value: totalPad}("");
        if (!ok1) revert LaunchpadSplitFailed();

        uint256 excess = msg.value - (partnerFee * count);
        if (excess > 0) { (bool ok2,) = msg.sender.call{value: excess}(""); if (!ok2) revert RefundFailed(); }
    }

    function _registerOne(
        string calldata name,
        string calldata ticker,
        address contractAddress,
        address deployer,
        string memory padName
    ) internal returns (uint256 proto, uint256 pad) {
        _validateTicker(ticker);
        if (bytes(name).length == 0)       revert EmptyString();
        if (contractAddress == address(0)) revert InvalidAddress();
        if (deployer == address(0))        revert InvalidAddress();

        string memory n = _normalize(ticker);
        if (_records[n].exists) revert TickerAlreadyTaken();

        Reservation memory res = _reservations[n];
        if (res.active && block.timestamp < res.expiresAt) {
            if (res.reserver != deployer) revert TickerReservedByOther();
        }
        _clearReservation(n);

        proto = partnerFee / 2;
        pad   = partnerFee - proto;

        _records[n] = TokenRecord({
            name: name, ticker: n, contractAddress: contractAddress,
            deployer: deployer, currentOwner: deployer, originalRegistrant: deployer,
            registeredAt: block.timestamp, launchpad: padName,
            stamp: STAMP_CERTIFIED, evidence: "", exists: true
        });
        allTickers.push(n);

        emit TokenRegistered(n, name, contractAddress, deployer, deployer,
                             block.timestamp, padName, STAMP_CERTIFIED);
    }

    // ─── PATH 2: OG Verified ──────────────────────────────────────

    function registerOG(
        string  calldata name,
        string  calldata ticker,
        address contractAddress,
        address deployer,
        string  calldata evidence
    ) external payable onlyOwner nonReentrant whenNotPaused {
        if (msg.value < ogFee) revert InsufficientFee();
        _validateTicker(ticker);
        if (bytes(name).length == 0)       revert EmptyString();
        if (contractAddress == address(0)) revert InvalidAddress();
        if (deployer == address(0))        revert InvalidAddress();
        if (bytes(evidence).length == 0)   revert EmptyString();

        string memory n = _normalize(ticker);
        if (_records[n].exists) revert TickerAlreadyTaken();
        _clearReservation(n);

        uint256 excess = msg.value - ogFee;
        collectedFees += ogFee;

        _records[n] = TokenRecord({
            name: name, ticker: n, contractAddress: contractAddress,
            deployer: deployer, currentOwner: deployer, originalRegistrant: deployer,
            registeredAt: block.timestamp, launchpad: "UNIQUE OG",
            stamp: STAMP_OG, evidence: evidence, exists: true
        });
        allTickers.push(n);

        emit TokenRegistered(n, name, contractAddress, deployer, deployer,
                             block.timestamp, "UNIQUE OG", STAMP_OG);
        emit OGVerified(n, name, contractAddress, deployer, evidence);

        if (excess > 0) { (bool ok,) = msg.sender.call{value: excess}(""); if (!ok) revert RefundFailed(); }
    }

    // ─── PATH 3: Official Record ──────────────────────────────────

    function certifyRecord(
        string  calldata name,
        string  calldata ticker,
        address contractAddress,
        address deployer,
        string  calldata evidence
    ) external onlyOwner whenNotPaused {
        _validateTicker(ticker);
        if (bytes(name).length == 0)       revert EmptyString();
        if (contractAddress == address(0)) revert InvalidAddress();
        if (deployer == address(0))        revert InvalidAddress();

        string memory n = _normalize(ticker);
        if (_records[n].exists) revert TickerAlreadyTaken();
        _clearReservation(n);

        _records[n] = TokenRecord({
            name: name, ticker: n, contractAddress: contractAddress,
            deployer: deployer, currentOwner: msg.sender, originalRegistrant: msg.sender,
            registeredAt: block.timestamp, launchpad: "UNIQUE Official",
            stamp: STAMP_OFFICIAL, evidence: evidence, exists: true
        });
        allTickers.push(n);

        emit TokenRegistered(n, name, contractAddress, deployer, msg.sender,
                             block.timestamp, "UNIQUE Official", STAMP_OFFICIAL);
        emit OfficialRecord(n, name, contractAddress, evidence);
    }

    // ─── Pre-Launch Reservation ───────────────────────────────────

    function reserveTicker(string calldata ticker) external payable nonReentrant whenNotPaused {
        uint256 fee = ogFee / 2;
        if (msg.value < fee) revert InsufficientFee();
        _validateTicker(ticker);
        string memory n = _normalize(ticker);
        if (_records[n].exists) revert TickerAlreadyTaken();

        Reservation memory ex = _reservations[n];
        if (ex.active && block.timestamp < ex.expiresAt) revert TickerAlreadyReserved();

        uint256 expiresAt = block.timestamp + RESERVATION_DAYS;
        _reservations[n] = Reservation({reserver: msg.sender, expiresAt: expiresAt, active: true});
        collectedFees += fee;
        emit TickerReserved(n, msg.sender, expiresAt);

        uint256 excess = msg.value - fee;
        if (excess > 0) { (bool ok,) = msg.sender.call{value: excess}(""); if (!ok) revert RefundFailed(); }
    }

    // ─── Revoke (48h timelock) ────────────────────────────────────

    function scheduleRevoke(string calldata ticker) external onlyOwner {
        string memory n = _normalize(ticker);
        if (!_records[n].exists) revert TickerNotRegistered();
        uint256 execAt = block.timestamp + TIMELOCK_DELAY;
        pendingRevoke[n] = execAt;
        emit RevokeScheduled(n, execAt);
    }

    function executeRevoke(string calldata ticker) external onlyOwner {
        string memory n = _normalize(ticker);
        uint256 execAt = pendingRevoke[n];
        if (execAt == 0) revert RevokeNotScheduled();
        if (block.timestamp < execAt) revert TimelockActive();
        delete _records[n];
        delete _reservations[n];
        delete pendingRevoke[n];
        revokedCount++;
        emit RevokeExecuted(n);
    }

    function cancelRevoke(string calldata ticker) external onlyOwner {
        string memory n = _normalize(ticker);
        if (pendingRevoke[n] == 0) revert NoPendingRevoke();
        delete pendingRevoke[n];
    }

    // ─── Launchpad Management ─────────────────────────────────────

    function authorizeLaunchpad(address launchpad, string calldata name) external onlyOwner {
        if (launchpad == address(0)) revert InvalidAddress();
        if (bytes(name).length == 0) revert EmptyString();
        launchpads[launchpad].authorized = true;
        launchpads[launchpad].name       = name;
        emit LaunchpadAuthorized(launchpad, name);
    }

    function revokeLaunchpad(address launchpad) external onlyOwner {
        launchpads[launchpad].authorized = false;
        emit LaunchpadRevoked(launchpad);
    }

    function certifyLaunchpad(address launchpad) external onlyOwner {
        if (!launchpads[launchpad].authorized) revert NotAuthorized();
        launchpads[launchpad].certifiedByUnique = true;
    }

    function acceptCertification() external {
        if (!launchpads[msg.sender].authorized)        revert NotAuthorized();
        if (!launchpads[msg.sender].certifiedByUnique) revert NotCertifiedByUnique();
        launchpads[msg.sender].certificationAccepted = true;
        emit LaunchpadCertified(msg.sender);
    }

    // ─── Metadata (feature flag) ──────────────────────────────────

    function setMetadata(string calldata ticker, string calldata logoHash,
                         string calldata website, string calldata description) external whenNotPaused {
        if (!metadataEnabled) revert MetadataDisabled();
        string memory n = _normalize(ticker);
        if (!_records[n].exists) revert TickerNotRegistered();
        if (_records[n].currentOwner != msg.sender) revert NotCurrentOwner();
        _metadata[n] = Metadata(logoHash, website, description);
    }

    function setMetadataEnabled(bool enabled) external onlyOwner {
        metadataEnabled = enabled;
        emit MetadataToggled(enabled);
    }

    // ─── Governance flag (placeholder) ────────────────────────────

    function setGovernanceEnabled(bool enabled) external onlyOwner {
        governanceEnabled = enabled;
        emit GovernanceToggled(enabled);
    }

    // ─── Emergency Pause ──────────────────────────────────────────

    function pause()   external onlyOwner { paused = true;  emit Paused(); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(); }

    // ─── Fee Management (48h timelock) ────────────────────────────

    function proposeFeeChange(uint256 newPartnerFee, uint256 newOgFee) external onlyOwner {
        if (newPartnerFee < MIN_FEE || newPartnerFee > MAX_FEE) revert FeeOutOfBounds();
        if (newOgFee      < MIN_FEE || newOgFee      > MAX_FEE) revert FeeOutOfBounds();
        if (newPartnerFee <= newOgFee) revert PartnerMustExceedOG();
        uint256 execAt = block.timestamp + TIMELOCK_DELAY;
        pendingFeeChange = PendingFeeChange({newPartnerFee: newPartnerFee, newOgFee: newOgFee,
                                             executableAt: execAt, exists: true});
        emit FeeChangeProposed(newPartnerFee, newOgFee, execAt);
    }

    function executeFeeChange() external onlyOwner {
        if (!pendingFeeChange.exists) revert NoPendingChange();
        if (block.timestamp < pendingFeeChange.executableAt) revert TimelockActive();
        partnerFee = pendingFeeChange.newPartnerFee;
        ogFee      = pendingFeeChange.newOgFee;
        delete pendingFeeChange;
        emit FeeChangeExecuted(partnerFee, ogFee);
    }

    function cancelFeeChange() external onlyOwner {
        if (!pendingFeeChange.exists) revert NoPendingChange();
        delete pendingFeeChange;
        emit FeeChangeCancelled();
    }

    // ─── Ownership Transfer (48h timelock) ───────────────────────

    function proposeOwnerChange(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        uint256 execAt = block.timestamp + TIMELOCK_DELAY;
        pendingOwnerChange = PendingOwnerChange({newOwner: newOwner, executableAt: execAt, exists: true});
        emit OwnershipTransferProposed(newOwner, execAt);
    }

    function executeOwnerChange() external onlyOwner {
        if (!pendingOwnerChange.exists) revert NoPendingChange();
        if (block.timestamp < pendingOwnerChange.executableAt) revert TimelockActive();
        address old = owner;
        owner = pendingOwnerChange.newOwner;
        delete pendingOwnerChange;
        emit OwnershipTransferred(old, owner);
    }

    // ─── Withdraw ─────────────────────────────────────────────────

    function withdrawFees() external onlyOwner nonReentrant {
        uint256 amount = collectedFees;
        if (amount == 0) revert NothingToWithdraw();
        collectedFees = 0;
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert WithdrawalFailed();
        emit FeesWithdrawn(owner, amount);
    }

    receive() external payable { collectedFees += msg.value; }
}
