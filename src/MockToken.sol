// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";


/**
 * @title MockToken
 * @dev Token ERC-20 mock to test the yield farming project
 */
contract MockToken is ERC20, Ownable {

    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) Ownable(msg.sender) {
        _mint(msg.sender, initialSupply * 10**decimals());
    }

    /**
     * @dev Function to mint tokens
     * @param to address to mint tokens to
     * @param amount amount to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Function to burn tokens
     * @param amount amount to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
