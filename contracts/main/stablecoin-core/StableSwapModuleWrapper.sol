// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../interfaces/IToken.sol";
import "../interfaces/IStablecoinAdapter.sol";
import "../interfaces/IStablecoin.sol";
import "../interfaces/IBookKeeper.sol";
import "../interfaces/IStableSwapModule.sol";
import "../utils/SafeToken.sol";
import "../interfaces/IStableSwapRetriever.sol";
import "../interfaces/IStableSwapModuleWrapper.sol";
 

// Stable Swap Module
// Allows anyone to go between FUSD and the Token by pooling the liquidity
// An optional fee is charged for incoming and outgoing transfers
contract StableSwapModuleWrapper is PausableUpgradeable, ReentrancyGuardUpgradeable, IStableSwapModuleWrapper{
    using SafeToken for address;

    IBookKeeper public bookKeeper;

    address public stablecoin;
    address public token;
    uint256 public totalStablecoinDeposited;
    uint256 public totalTokenDeposited;
    address public stableSwapModule;
    bool public isDecentralizedState;
    uint256 public totalValueDeposited;

    mapping(address => uint256) public depositTracker;
    mapping(address => bool) public whiteListed;
    mapping(address => bool) public usersWhitelist;

    event LogDepositTokens(address indexed _depositor, uint256 _amount);
    event LogWithdrawTokens(address indexed _depositor, uint256 _amount);
    event LogAddToWhitelist(address indexed user);
    event LogRemoveFromWhitelist(address indexed user);
    event LogStableSwapWrapperPauseState(bool _pauseState);
    event LogUpdateIsDecentralizedState(bool _isDecentralizedState);

    modifier onlyOwner() {
        IAccessControlConfig _accessControlConfig = IAccessControlConfig(bookKeeper.accessControlConfig());
        require(_accessControlConfig.hasRole(_accessControlConfig.OWNER_ROLE(), msg.sender), "!ownerRole");
        _;
    }

    modifier onlyOwnerOrGov() {
        IAccessControlConfig _accessControlConfig = IAccessControlConfig(IBookKeeper(bookKeeper).accessControlConfig());
        require(
            _accessControlConfig.hasRole(_accessControlConfig.OWNER_ROLE(), msg.sender) ||
                _accessControlConfig.hasRole(_accessControlConfig.GOV_ROLE(), msg.sender),
            "!(ownerRole or govRole)"
        );
        _;
    }

    modifier onlyWhitelistedIfNotDecentralized() {
        if (!isDecentralizedState) {
            require(usersWhitelist[msg.sender], "user-not-whitelisted");
        }
        _;
    }

    function initialize(
        address _token,
        address _stablecoin
    ) external initializer {
        PausableUpgradeable.__Pausable_init();
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        stablecoin = _stablecoin;
        token = _token;
    }

    function addToWhitelist(address _user) external onlyOwner {
        usersWhitelist[_user] = true;
        emit LogAddToWhitelist(_user);
    }

    function removeFromWhitelist(address _user) external onlyOwner {
        usersWhitelist[_user] = false;
        emit LogRemoveFromWhitelist(_user);
    }

    function setIsDecentralizedState(bool _isDecentralizedState) external onlyOwner{
        isDecentralizedState = _isDecentralizedState;
        emit LogUpdateIsDecentralizedState(isDecentralizedState);
    }

    //@Dev _amount arg should be in 18 decimals
    function depositTokens(uint256 _amount) external override nonReentrant whenNotPaused onlyWhitelistedIfNotDecentralized{
        require(_amount != 0, "depositTokens/amount-zero");
        require(isDecentralizedState || usersWhitelist[msg.sender], "depositTokens/user-not-whitelisted");
        require(IToken(token).balanceOf(msg.sender) >= _amount, "depositTokens/token-not-enough");
        require(IToken(stablecoin).balanceOf(msg.sender) >= _amount, "depositTokens/FXD-not-enough");
        uint256 _amount6decimals = _convertDecimals(_amount, 18, IToken(token).decimals());

        token.safeTransferFrom(msg.sender, address(this), _amount6decimals);
        IToken(token).approve(stableSwapModule, _amount6decimals);
        IStableSwapModule(stableSwapModule).depositToken(token, _amount6decimals);
        
        stablecoin.safeTransferFrom(msg.sender, address(this), _amount);
        IToken(stablecoin).approve(stableSwapModule, _amount);
        IStableSwapModule(stableSwapModule).depositToken(stablecoin, _amount);
        

        //then call deposit fn for stablecoin
        //deposit tracker is saving only half of total token amount, later when
        //withdrawl happens
        // ( depositTracker * 2 ) * ratioOfStablecoin in SSM 
        // 
        // ( depositTracker * 2 ) * ratioOfToken in SSM 
        //need to be sent to withdrawer, of course, for token withdrawl, conversion
        //of decimals will be done
        depositTracker[msg.sender] += _amount;
        totalValueDeposited += _amount;

        emit LogDepositTokens(msg.sender, _amount);
    }
    function withdrawTokens(uint256 _amount) external override nonReentrant whenNotPaused onlyWhitelistedIfNotDecentralized{
        require(_amount != 0, "depositStablecoin/amount-zero");
        require(isDecentralizedState || usersWhitelist[msg.sender], "depositTokens/user-not-whitelisted");
        require(depositTracker[msg.sender]>=_amount, "withdrawTokens/amount-exceeds-deposit");
        require(totalTokenDeposited >= _amount * 2, "withdrawTokens/amount-exceeds-total-deposit");
        
        uint256 stablecoinAmountInStableswap18Decimals = IStableSwapRetriever(stableSwapModule).tokenBalance(stablecoin);
        uint256 tokenAmountInStableswap6Decimals = IStableSwapRetriever(stableSwapModule).tokenBalance(token);
        uint256 stablecoinAmountInStableswap6decimals = _convertDecimals(stablecoinAmountInStableswap18Decimals, 18, IToken(stablecoin).decimals());
        uint256 tokenAmountInStableswap18decimals = _convertDecimals(stablecoinAmountInStableswap6decimals, IToken(token).decimals(), 18);
        
        uint256 _amount6decimals = _convertDecimals(_amount, 18, IToken(token).decimals());
        
        uint256 withdrawableStablecoinAmount = 
                    depositTracker[msg.sender] * 
                    _amount * 
                    stablecoinAmountInStableswap18Decimals 
                    / tokenAmountInStableswap18decimals / depositTracker[msg.sender];

        uint256 withdrawableTokenAmount = 
                    depositTracker[msg.sender] * 
                    _amount6decimals * 
                    tokenAmountInStableswap6Decimals 
                    / stablecoinAmountInStableswap6decimals / depositTracker[msg.sender];

        
        depositTracker[msg.sender] -= _amount;
        totalValueDeposited -= _amount;
        token.safeTransferFrom(address(this), msg.sender, withdrawableTokenAmount);
        stablecoin.safeTransferFrom(address(this), msg.sender, withdrawableStablecoinAmount);

        emit LogWithdrawTokens(msg.sender, _amount);
    }

    function pause() external onlyOwnerOrGov {
        _pause();
        emit LogStableSwapWrapperPauseState(true);
    }

    function unpause() external onlyOwnerOrGov {
        _unpause();
        emit LogStableSwapWrapperPauseState(false);
    }

    function _convertDecimals(uint256 _amount, uint8 _fromDecimals, uint8 _toDecimals) internal pure returns (uint256 result) {
        result = _toDecimals >= _fromDecimals ? _amount * (10 ** (_toDecimals - _fromDecimals)) : _amount / (10 ** (_fromDecimals - _toDecimals));
    }
}
