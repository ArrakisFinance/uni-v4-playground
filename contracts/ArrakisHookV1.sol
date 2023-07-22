// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {BaseHook, IPoolManager, Hooks} from "@uniswap/v4-periphery/contracts/BaseHook.sol";

import {IArrakisHookV1} from "./interfaces/IArrakisHookV1.sol";

/// @dev Al N spread V1
contract ArrakisHookV1 is IArrakisHookV1, BaseHook {
    //#region constants.

    uint256 public immutable c;

    //#endregion constants.

    //#region properties.

    /// @dev should not be settable.
    IPoolManager.PoolKey public poolKey;
    uint8 public referenceFee;
    uint8 public referenceVolatility;
    int24 public rangeSize;
    uint8 public ultimateThreshold;
    uint256 public rebalanceFrequence;
    uint256 public allocation;

    //#endregion properties.

    constructor(IPoolManager _poolManager, uint256 c_) BaseHook(_poolManager) {
        c = c_;
    }

    function initialize(InitializeParams memory initializeParams_) external {}

    //#region view/pure functions.

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: true,
            afterInitialize: false,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: true, // strategy of the vault
            beforeDonate: false,
            afterDonate: false
        });
    }

    //#endregion view/pure functions.
}
