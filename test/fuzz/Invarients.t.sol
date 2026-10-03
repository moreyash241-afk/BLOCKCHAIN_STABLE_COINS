// SPDX-License-Identifier: MIT



// Have our invarients aka properties

// What are our invarients?
// 1. The total supply of tokens should always equal the sum of all balances
// 2. Getter view functions should never revert
pragma solidity^ 0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract Invarients is StdInvariant,Test{
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc; 
    Handler handler;


    function setUp() public{
        deployer = new DeployDSC();
        (dsce ,dsc, config) = deployer.run();
        (,,weth,wbtc,)=config.activeNetworkConfig();
        // targetContract(address(dsce));
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));

    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {

        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("Weth Value:", wethValue);
        console.log("wbtc Value:", wbtcValue);
        console.log("Total Supply:", totalSupply);
        console.log("Times mint called", handler.timesMintIsCalled());



        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invarient_gettersShouldNotRevert() public view{
        // all of our getter functions should be here if one fails test will get failed
        dsce.getCollateralBalanceOfUser(address(1), weth);
        dsce.getCollateralBalanceOfUser(address(1), wbtc);
        dsce.getAccountInformation(address(1));
        dsce.getCollateralTokens();
    }

    
    

}