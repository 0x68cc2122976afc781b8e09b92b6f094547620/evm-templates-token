// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {CountersUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ECDSAUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {IERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20PermitUpgradeable.sol";

contract Dollar is
    IERC20MetadataUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IERC20PermitUpgradeable,
    EIP712Upgradeable
{
    using CountersUpgradeable for CountersUpgradeable.Counter;
    string private _name;
    string private _symbol;
    uint256 private _totalDollars;
    uint256 private constant _BASE = 1e18;
    uint256 public rewardMultiplier;
    mapping(address => uint256) private _shares;
    mapping(address => bool) private _blocklist;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => CountersUpgradeable.Counter) private _nonces;
    bytes32 private constant _PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant BLOCKLIST_ROLE = keccak256("BLOCKLIST_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant UPGRADE_ROLE = keccak256("UPGRADE_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");

    // Events
    event AccountBlocked(address indexed addr);
    event AccountUnblocked(address indexed addr);
    event RewardMultiplier(uint256 indexed value);
    error ERC20InsufficientBalance(address sender, uint256 shares, uint256 sharesNeeded);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);

    // ERC2612 Errors
    error ERC2612ExpiredDeadline(uint256 deadline, uint256 blockTimestamp);
    error ERC2612InvalidSignature(address owner, address spender);
    
    // Dollar Errors
    error DollarInvalidMintReceiver(address receiver);
    error DollarInvalidBurnSender(address sender);
    error DollarInsufficientBurnBalance(address sender, uint256 shares, uint256 sharesNeeded);
    error DollarInvalidRewardMultiplier(uint256 rewardMultiplier);
    error DollarBlockedSender(address sender);
    error DollarInvalidBlockedAccount(address account);
    error DollarPausedTransfers();

    function initialize(string memory name_, string memory symbol_, address owner) external initializer {
        _name = name_;
        _symbol = symbol_;
        _setRewardMultiplier(_BASE);
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __EIP712_init(name_, "1");
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }
    constructor() {
        _disableInitializers();
    }
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADE_ROLE) {}
    function name() external view returns (string memory) {
        return _name;
    }
    function symbol() external view returns (string memory) {
        return _symbol;
    }
    function decimals() external pure returns (uint8) {
        return 18;
    }
    function convertToDollars(uint256 amount) public view returns (uint256) {
        return (amount * _BASE) / rewardMultiplier;
    }
    function convertToTokens(uint256 shares) public view returns (uint256) {
        return (shares * rewardMultiplier) / _BASE;
    }
    function totalDollars() external view returns (uint256) {
        return _totalDollars;
    }
    function totalSupply() external view returns (uint256) {
        return convertToTokens(_totalDollars);
    }
    function sharesOf(address account) public view returns (uint256) {
        return _shares[account];
    }
    function balanceOf(address account) external view returns (uint256) {
        return convertToTokens(sharesOf(account));
    }
    function _mint(address to, uint256 amount) private {
        if (to == address(0)) {
            revert DollarInvalidMintReceiver(to);
        }
        _beforeTokenTransfer(address(0), to, amount);
        uint256 shares = convertToDollars(amount);
        _totalDollars += shares;
        unchecked {
            _shares[to] += shares;
        }
        _afterTokenTransfer(address(0), to, amount);
    }
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
    function _burn(address account, uint256 amount) private {
        if (account == address(0)) {
            revert DollarInvalidBurnSender(account);
        }
        _beforeTokenTransfer(account, address(0), amount);
        uint256 shares = convertToDollars(amount);
        uint256 accountDollars = sharesOf(account);
        if (accountDollars < shares) {
            revert DollarInsufficientBurnBalance(account, accountDollars, shares);
        }
        unchecked {
            _shares[account] = accountDollars - shares;
            _totalDollars -= shares;
        }
        _afterTokenTransfer(account, address(0), amount);
    }
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }
    function _beforeTokenTransfer(address from, address /* to */, uint256 /* amount */) private view {
        if (isBlocked(from)) {
            revert DollarBlockedSender(from);
        }
        if (paused()) {
            revert DollarPausedTransfers();
        }
    }
    function _afterTokenTransfer(address from, address to, uint256 amount) private {
        emit Transfer(from, to, amount);
    }
    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) {
            revert ERC20InvalidSender(from);
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(to);
        }
        _beforeTokenTransfer(from, to, amount);
        uint256 shares = convertToDollars(amount);
        uint256 fromDollars = _shares[from];
        if (fromDollars < shares) {
            revert ERC20InsufficientBalance(from, fromDollars, shares);
        }
        unchecked {
            _shares[from] = fromDollars - shares;
            _shares[to] += shares;
        }
        _afterTokenTransfer(from, to, amount);
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }
    function _blockAccount(address account) private {
        if (isBlocked(account)) {
            revert DollarInvalidBlockedAccount(account);
        }
        _blocklist[account] = true;
        emit AccountBlocked(account);
    }
    function _unblockAccount(address account) private {
        if (!isBlocked(account)) {
            revert DollarInvalidBlockedAccount(account);
        }
        _blocklist[account] = false;
        emit AccountUnblocked(account);
    }
    function blockAccounts(address[] calldata addresses) external onlyRole(BLOCKLIST_ROLE) {
        for (uint256 i = 0; i < addresses.length; i++) {
            _blockAccount(addresses[i]);
        }
    }
    function unblockAccounts(address[] calldata addresses) external onlyRole(BLOCKLIST_ROLE) {
        for (uint256 i = 0; i < addresses.length; i++) {
            _unblockAccount(addresses[i]);
        }
    }
    function isBlocked(address account) public view returns (bool) {
        return _blocklist[account];
    }
    function pause() external onlyRole(PAUSE_ROLE) {
        super._pause();
    }
    function unpause() external onlyRole(PAUSE_ROLE) {
        super._unpause();
    }
    function _setRewardMultiplier(uint256 _rewardMultiplier) private {
        if (_rewardMultiplier < _BASE) {
            revert DollarInvalidRewardMultiplier(_rewardMultiplier);
        }
        rewardMultiplier = _rewardMultiplier;
        emit RewardMultiplier(rewardMultiplier);
    }
    function setRewardMultiplier(uint256 _rewardMultiplier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRewardMultiplier(_rewardMultiplier);
    }
    function addRewardMultiplier(uint256 _rewardMultiplierIncrement) external onlyRole(ORACLE_ROLE) {
        if (_rewardMultiplierIncrement == 0) {
            revert DollarInvalidRewardMultiplier(_rewardMultiplierIncrement);
        }
        _setRewardMultiplier(rewardMultiplier + _rewardMultiplierIncrement);
    }
    function _approve(address owner, address spender, uint256 amount) private {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(owner);
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(spender);
        }
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }
    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }
    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, amount);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < subtractedValue) {
            revert ERC20InsufficientAllowance(spender, currentAllowance, subtractedValue);
        }
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }
        return true;
    }
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
    function nonces(address owner) external view returns (uint256) {
        return _nonces[owner].current();
    }
    function _useNonce(address owner) private returns (uint256 current) {
        CountersUpgradeable.Counter storage nonce = _nonces[owner];
        current = nonce.current();
        nonce.increment();
    }
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) {
            revert ERC2612ExpiredDeadline(deadline, block.timestamp);
        }
        bytes32 structHash = keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline));
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSAUpgradeable.recover(hash, v, r, s);
        if (signer != owner) {
            revert ERC2612InvalidSignature(owner, spender);
        }
        _approve(owner, spender, value);
    }
    uint256[42] private __gap;
}
