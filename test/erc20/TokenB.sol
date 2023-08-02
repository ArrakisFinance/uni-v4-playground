// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenB is ERC20 {
    constructor(address initialAllocationReceiver_) ERC20("Token B", "TOB") {
        _mint(initialAllocationReceiver_, 1e27);
    }
}
