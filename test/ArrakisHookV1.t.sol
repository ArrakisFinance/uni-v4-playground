//  SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {ArrakisHookV1} from "../contracts/ArrakisHookV1.sol";

contract ArrakisHookV1Test is Test {
    PoolManager public poolManager;
    ArrakisHookV1 public arrakisHookV1;

    function setUp() public {
        poolManager = new PoolManager(0);
        arrakisHookV1 = new ArrakisHookV1(poolManager);
    }
}
