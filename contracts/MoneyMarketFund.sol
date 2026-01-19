// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Dollar} from "./Dollar.sol";

contract MoneyMarketFund is Dollar {
    
    // Fund-specific state
    uint256 public navPerShare;           // NAV in 18 decimals
    uint256 public managementFeeBps;      // e.g., 50 = 0.50%
    uint256 public minInvestment;
    address public custodian;
    
    // Fund roles (inherit existing + add new)
    bytes32 public constant NAV_MANAGER_ROLE = keccak256("NAV_MANAGER_ROLE");
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");
    
    // Events
    event NAVUpdated(uint256 oldNav, uint256 newNav);
    event Subscription(address indexed investor, uint256 amount, uint256 shares);
    event Redemption(address indexed investor, uint256 shares, uint256 amount);
    
    // Errors
    error BelowMinimumInvestment();
    error InvalidNAV();
    
    function initialize(
        string memory name_,
        string memory symbol_,
        address owner,
        uint256 _minInvestment,
        uint256 _managementFeeBps
    ) external initializer {
        // Call parent initializer
        Dollar.initialize(name_, symbol_, owner);
        
        navPerShare = 1e18;  // Start at $1
        minInvestment = _minInvestment;
        managementFeeBps = _managementFeeBps;
    }
    
    /// @notice Update NAV (called daily by fund admin)
    function updateNAV(uint256 newNav) external onlyRole(NAV_MANAGER_ROLE) {
        if (newNav == 0) revert InvalidNAV();
        emit NAVUpdated(navPerShare, newNav);
        navPerShare = newNav;
    }
    
    /// @notice Subscribe to fund (deposit assets, receive shares)
    function subscribe(address investor, uint256 assetAmount) 
        external 
        onlyRole(CUSTODIAN_ROLE) 
    {
        if (assetAmount < minInvestment) revert BelowMinimumInvestment();
        
        uint256 shares = (assetAmount * 1e18) / navPerShare;
        _mint(investor, shares);
        
        emit Subscription(investor, assetAmount, shares);
    }
    
    /// @notice Redeem shares for assets
    function redeem(address investor, uint256 shares) 
        external 
        onlyRole(CUSTODIAN_ROLE) 
    {
        uint256 assetAmount = (shares * navPerShare) / 1e18;
        _burn(investor, shares);
        
        emit Redemption(investor, shares, assetAmount);
    }
    
    /// @dev Reserved storage gap for upgrades
    uint256[45] private __gap;
}