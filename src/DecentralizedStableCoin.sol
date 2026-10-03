// SPDX-License-Identifier: MIT
pragma solidity^ 0.8.0;

/*
* @title: DecentralizedStableCoin
* @author: Yash More
* Collateral: Exogenous (ETH & BTC)
* Minting: Algorithmic
* Relative Stability: Pegged to USD
*
* this is the contract meant to be governed by DSCEngine. this contract is just
the ERC20 implementation of our stable coin system.
*
*/

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable{

    error DecentralisedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();
    constructor() ERC20("DecentralizedStableCoin","DSC") Ownable(msg.sender){}

    function burn(uint256 _amount) public override onlyOwner{
        uint256 balance=balanceOf(msg.sender);
        if(_amount <=0){
            revert DecentralisedStableCoin__MustBeMoreThanZero();
        }
        if(balance<_amount){
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool){
        if(_to == address(0)){
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if(_amount <=0){
            revert DecentralisedStableCoin__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
