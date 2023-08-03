// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "forge-std/console.sol";

contract UniswapV4Swapper {
    // #region usings.

    using BalanceDeltaLibrary for BalanceDelta;

    // #endregion usings.

    // #region errors.

    error ZeroAmountIn(
        IPoolManager.PoolKey poolKey,
        IPoolManager.SwapParams params
    );

    // #endregion errors.

    IPoolManager public immutable poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function swap(
        IPoolManager.PoolKey memory poolKey_,
        IPoolManager.SwapParams memory params_
    ) external {
        if (params_.amountSpecified <= 0)
            revert ZeroAmountIn(poolKey_, params_);

        bytes memory data = abi.encode(msg.sender, poolKey_, params_);
        poolManager.lock(data);
    }

    function lockAcquired(
        uint256,
        bytes calldata data
    ) external returns (bytes memory result) {
        (
            address msgSender,
            IPoolManager.PoolKey memory poolKey,
            IPoolManager.SwapParams memory params
        ) = abi.decode(
                data,
                (address, IPoolManager.PoolKey, IPoolManager.SwapParams)
            );

        BalanceDelta delta = poolManager.swap(poolKey, params);

        if (params.zeroForOne) {
            IERC20(Currency.unwrap(poolKey.currency0)).transferFrom(
                msgSender,
                address(poolManager),
                SafeCast.toUint256(int256(delta.amount0()))
            );
            poolManager.settle(poolKey.currency0);
            poolManager.take(
                poolKey.currency1,
                msgSender,
                SafeCast.toUint256(int256( - delta.amount1()))
            );
        } else {
            IERC20(Currency.unwrap(poolKey.currency1)).transferFrom(
                msgSender,
                address(poolManager),
                SafeCast.toUint256(int256(delta.amount1()))
            );
            poolManager.settle(poolKey.currency1);
            poolManager.take(
                poolKey.currency0,
                msgSender,
                SafeCast.toUint256(int256( - delta.amount0()))
            );
        }
    }
}
