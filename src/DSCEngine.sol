//SPDX-License-Identifier: MIT
pragma solidity^ 0.8.0;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
/*
 * @title DSCEngine
 * @author Yash More
 * 
 * The system is designed to be as minimal as possible, and have the tokens to maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmically Stable
 * 
 * It is similar to DAI had no governance, no fees, and was only backed by WETH and WBTC
 * 
 * Our DSC system should always be overcollateralized. At no point should the value of all collateral <= the $ backed value of all DSC.
 * 
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard{

    /////////////////////////
   //////ERRORS/////////////
   ////////////////////////

    error DscEngine_NeedsMoreThanZero();
    error DSCEngine_TokenAddressesandPriceFeedAddressMustBeSameLength();
    error DSCEngine_NotAllowedToken();
    error DSCEngine_TransferFailed();
    error DSCEngine_HealthFactorIsBroken(uint256 healthFactor);
    error DSCEngine__MintedFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();


    using OracleLib for AggregatorV3Interface;
    

    /////////////////////////
   //////STATE VARIABLES////
   ////////////////////////

   uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
   uint256 private constant PRECISION = 1e18;
   uint256 private constant LIQUIDATION_THRESHOLD = 50;
   uint256 private constant LIQUIDATION_PRECISION = 100;
   uint256 private constant MIN_HEALTH_FACTOR =1e18;
   uint256 private constant LIQUIDATION_BONUS = 10;


   mapping(address token => address priceFeed) private s_priceFeeds; 
   mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
   mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
   DecentralizedStableCoin private immutable i_dsc;
   address[] private s_collateralTokens;

   event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
   event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

    /*
    * @notice follows CIE patterns
    * @param tokenCollateralAddress The address of the token to deposit as collateral.
    * @param amountCollateral The amount of collateral to deposit.
    */

   /////////////////////////
   //////MODIFIERS/////////
   ////////////////////////

    modifier moreThanZero(uint256 amount){
        if(amount<=0){
            revert DscEngine_NeedsMoreThanZero(); 
            }
            _;
    }

    modifier isAllowedToken(address token){
        if(s_priceFeeds[token]==address(0)){
            revert DSCEngine_NotAllowedToken(); 
        }
     _;   
    }

    /////////////////////////
   /////FUNCTIONS///////////
   ////////////////////////

   constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress,
   address dscAddress){
    if(tokenAddresses.length !=priceFeedAddress.length){
        revert DSCEngine_TokenAddressesandPriceFeedAddressMustBeSameLength(); 
    }
    for(uint256 i=0;i<tokenAddresses.length;i++){
        s_priceFeeds[tokenAddresses[i]]=priceFeedAddress[i];
        s_collateralTokens.push(tokenAddresses[i]);
    }
    i_dsc=DecentralizedStableCoin(dscAddress);

   }

   /////////////////////////////////
   //////EXTERNAL FUNCTIONS/////////
   ////////////////////////////////

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant{
       s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral; 
       emit CollateralDeposited(msg.sender, tokenCollateralAddress,amountCollateral);
       bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
       if(!success){
           revert DSCEngine_TransferFailed();
       }
    }

    function depositCollateralAndMintDSC(address tokenCollateralAdress, uint256 amountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAdress, amountCollateral);
        mintDSC(amountDscToMint);
    }


    function redeemCollateral(address tokenAddress, uint256 amountCollateral) public  moreThanZero(amountCollateral) nonReentrant{

       _redeemCollateral(msg.sender, amountCollateral, tokenAddress, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral) external {

       burnDSC(amountCollateral);
       redeemCollateral(tokenCollateralAddress, amountCollateral);

}
    
    /*
    * @notice follows CIE pATTERNS
    * @param amountDscToMint The amount of decentralised stable to mint
    * @notice they must have more collateral value than minimum threshold
    */
    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant{
        s_DSCMinted[msg.sender] += amountDscToMint;

        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted){
            revert DSCEngine__MintedFailed();
        }
    }

    function burnDSC(uint256 amount) public moreThanZero(amount){

        _burnDsc(amount,msg.sender,msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);

    }

    function liquidate(address collateral, address user, uint256 debtToCover) external  moreThanZero(debtToCover) nonReentrant{
        uint256 startingUserHealthFactor = healthFactor(user);
        if(startingUserHealthFactor >=MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS)/
        LIQUIDATION_PRECISION;
        uint256 toalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, toalCollateralToRedeem, collateral,msg.sender );
        _burnDsc(debtToCover,user, msg.sender);

        uint256 endingUserHealthFactor = healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor){
            revert DSCEngine__HealthFactorNotImproved();
        }
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view{}

    /////Private and Internal Functions //////

        function _burnDsc(uint256 amountDSCToBurn, address onBehalfOf, address dscFrom) private{
            s_DSCMinted[onBehalfOf] -=amountDSCToBurn;
            bool success = i_dsc.transferFrom(dscFrom,address(this),amountDSCToBurn);
            if(!success){
            revert DSCEngine_TransferFailed();
            }
            i_dsc.burn(amountDSCToBurn);
        }

        function _redeemCollateral(address tokenAddress, uint256 amountCollateral, address from, address to) private{
        s_collateralDeposited[from][tokenAddress] -= amountCollateral;
        emit CollateralRedeemed(from,to, tokenAddress, amountCollateral);
        bool success = IERC20(tokenAddress).transfer(to, amountCollateral);
        if(!success){
            revert DSCEngine_TransferFailed();
        }
        }

    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd){
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    function healthFactor(address user) public view returns(uint256){
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD)/ LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION)/ totalDscMinted;
    }

    function revertIfHealthFactorIsBroken(address user) internal view{
        // 1. check health factor (do they have enough collateral ?)
        // 2. revert if health factor is broken.
        uint256 userHealthFactor = healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR){
            revert DSCEngine_HealthFactorIsBroken(userHealthFactor);
        }

    }

    function getAccountCollateralValueInUsd(address user) public view returns(uint256 totalCollateralValueInUsd){
        // loop through each collateral token, get the amount they have deposited, and then get the value in USD
        // using price feeds.
        for(uint256 i=0;i<s_collateralTokens.length;i++){
            address token =s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }
    function getUsdValue(address token, uint256 amount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.stalePriceCheck();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount)/PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256){

        AggregatorV3Interface priceFeed =AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,)=priceFeed.stalePriceCheck();
        return (usdAmountInWei * PRECISION)/ (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }
    function getAccountInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd){
        (totalDscMinted, collateralValueInUsd)= _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns(address[] memory){
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns(uint256){
        return s_collateralDeposited[user][token];
    }
    function getCollateralTokenPriceFeed(address token) external view returns (address) {
    return s_priceFeeds[token];
}
}