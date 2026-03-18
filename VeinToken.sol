// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VeinToken — $VEIN ERC-20
/// @notice Fixed supply. Minted once at deploy. No admin mint after.
contract VeinToken is ERC20, Ownable {
    uint256 public constant TOTAL_SUPPLY = 100_000_000_000 * 1e18; // 100B

    constructor(address initialHolder)
        ERC20("Vein", "VEIN")
        Ownable(initialHolder)
    {
        _mint(initialHolder, TOTAL_SUPPLY);
    }
}
