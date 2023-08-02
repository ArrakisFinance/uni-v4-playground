// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenA is ERC20 {
    constructor(address initialAllocationReceiver_) ERC20("Token A", "TOA") {
        _mint(initialAllocationReceiver_, 1e27);
    }
}
