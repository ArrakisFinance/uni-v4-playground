// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {BaseHook, IPoolManager, Hooks} from "@uniswap/v4-periphery/contracts/BaseHook.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/contracts/libraries/SqrtPriceMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IArrakisHookV1} from "./interfaces/IArrakisHookV1.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";

import "forge-std/console.sol";

/// @dev Al N spread V1
contract ArrakisHookV1 is IArrakisHookV1, BaseHook, ERC20, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using TickMath for int24;
    using Pool for Pool.State;
    using SafeERC20 for ERC20;

    //#region constants.

    uint16 public immutable c;
    uint16 public immutable referenceFee;

    //#endregion constants.

    //#region properties.

    /// @dev should not be settable.
    PoolManager.PoolKey public override poolKey;
    uint160 public lastSqrtPriceX96;
    uint16 public referenceVolatility;
    uint24 public rangeSize;
    int24 public lowerTick;
    int24 public upperTick;
    uint16 public ultimateThreshold;
    uint16 public allocation;
    uint256 public lastBlockNumber;

    uint16 public delta;
    bool public impactDirection;

    bool public zeroForOne; // transient.
    uint256 public a0;
    uint256 public a1;

    //#endregion properties.

    constructor(
        InitializeParams memory params_
    ) BaseHook(params_.poolManager) ERC20(params_.name, params_.symbol) {
        referenceFee = params_.referenceFee;
        referenceVolatility = params_.referenceVolatility;
        rangeSize = params_.rangeSize;
        lowerTick = params_.lowerTick;
        upperTick = params_.upperTick;
        ultimateThreshold = params_.ultimateThreshold;
        allocation = params_.allocation;
        c = params_.c;
    }

    // #region pre calls.

    function beforeInitialize(
        address,
        PoolManager.PoolKey calldata poolKey_,
        uint160 sqrtPriceX96_
    ) external override returns (bytes4) {
        poolKey = poolKey_;
        lastSqrtPriceX96 = sqrtPriceX96_;
        lastBlockNumber = block.number;
        return this.beforeInitialize.selector;
    }

    /// @dev beforeSwap do the new spread computation.
    function beforeSwap(
        address,
        PoolManager.PoolKey calldata poolKey_,
        PoolManager.SwapParams calldata swapParams_
    ) external override returns (bytes4) {
        /// @dev is first swap.
        bool isFirstBlock = block.number > lastBlockNumber;

        if (isFirstBlock) {
            // update block numbers tracks.
            lastBlockNumber = block.number;

            // compute spread.
            (uint160 sqrtPriceX96, , , , , ) = poolManager.getSlot0(
                PoolIdLibrary.toId(poolKey_)
            );

            uint256 price = _getPrice(sqrtPriceX96);
            uint256 lastPrice = _getPrice(lastSqrtPriceX96);

            delta = SafeCast.toUint16(
                FullMath.mulDiv(
                    c,
                    (
                        price > lastPrice
                            ? price - lastPrice
                            : lastPrice - price
                    ) * 1_000_000,
                    lastSqrtPriceX96 * 10_000
                )
            );

            impactDirection = price > lastPrice;
        }

        zeroForOne = swapParams_.zeroForOne;

        return this.beforeSwap.selector;
    }

    // #endregion pre calls.

    // #region IERC20 functions.

    function burn(
        uint256 burnAmount_,
        address receiver_
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(burnAmount_ > 0, "burn 0");
        require(totalSupply() > 0, "total supply is 0");

        bytes memory data = abi.encode(
            PoolManagerCallData({
                actionType: 1,
                mintAmount: 0,
                burnAmount: burnAmount_,
                receiver: receiver_,
                msgSender: msg.sender
            })
        );

        a0 = a1 = 0;

        poolManager.lock(data);

        amount0 = a0;
        amount1 = a1;

        _burn(msg.sender, burnAmount_);
    }

    function mint(
        uint256 mintAmount_,
        address receiver_
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(mintAmount_ > 0, "mint 0");

        bytes memory data = abi.encode(
            PoolManagerCallData({
                actionType: 0,
                mintAmount: mintAmount_,
                burnAmount: 0,
                receiver: receiver_,
                msgSender: msg.sender
            })
        );

        a0 = a1 = 0;

        poolManager.lock(data);

        amount0 = a0;
        amount1 = a1;

        _mint(receiver_, mintAmount_);
    }

    // #endregion IERC20 functions.

    // #region hook functions

    function lockAcquired(
        uint256,
        /* id */ bytes calldata data_
    ) external override poolManagerOnly returns (bytes memory) {
        PoolManagerCallData memory pMCallData = abi.decode(
            data_,
            (PoolManagerCallData)
        );
        // first case mint
        if (pMCallData.actionType == 0) _lockAcquiredMint(pMCallData);
        // second case burn action.
        if (pMCallData.actionType == 1) _lockAcquiredBurn(pMCallData);
    }

    function _lockAcquiredMint(PoolManagerCallData memory pMCallData) internal {
        // burn everything positions and erc1155

        uint256 totalSupply = totalSupply();

        if (totalSupply == 0) {
            poolManager.modifyPosition(
                poolKey,
                IPoolManager.ModifyPositionParams({
                    liquidityDelta: SafeCast.toInt256(pMCallData.mintAmount),
                    tickLower: lowerTick,
                    tickUpper: upperTick
                })
            );

            uint256 index = poolManager.lockedByLength() - 1;
            int256 currency0BalanceRaw = poolManager.getCurrencyDelta(
                index,
                poolKey.currency0
            );
            if (currency0BalanceRaw < 0) {
                revert("cannot delta currency0 negative");
            }
            uint256 currency0Balance = SafeCast.toUint256(currency0BalanceRaw);
            int256 currency1BalanceRaw = poolManager.getCurrencyDelta(
                index,
                poolKey.currency1
            );
            if (currency1BalanceRaw < 0) {
                revert("cannot delta currency1 negative");
            }
            uint256 currency1Balance = SafeCast.toUint256(currency1BalanceRaw);

            if (currency0Balance > 0) {
                ERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                    pMCallData.msgSender,
                    address(poolManager),
                    currency0Balance
                );
                poolManager.settle(poolKey.currency0);
            }
            if (currency1Balance > 0) {
                ERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                    pMCallData.msgSender,
                    address(poolManager),
                    currency1Balance
                );
                poolManager.settle(poolKey.currency1);
            }
            a0 = currency0Balance;
            a1 = currency1Balance;
        } else {
            Position.Info memory info = PoolManager(
                payable(address(poolManager))
            ).getPosition(
                    PoolIdLibrary.toId(poolKey),
                    address(this),
                    lowerTick,
                    upperTick
                );

            if (info.liquidity > 0)
                poolManager.modifyPosition(
                    poolKey,
                    IPoolManager.ModifyPositionParams({
                        liquidityDelta: -SafeCast.toInt256(
                            uint256(info.liquidity)
                        ),
                        tickLower: lowerTick,
                        tickUpper: upperTick
                    })
                );

            uint256 currency0Id = CurrencyLibrary.toId(poolKey.currency0);
            uint256 leftOver0 = poolManager.balanceOf(
                address(this),
                currency0Id
            );

            if (leftOver0 > 0)
                PoolManager(payable(address(poolManager))).onERC1155Received(
                    address(0),
                    address(0),
                    currency0Id,
                    leftOver0,
                    ""
                );

            uint256 currency1Id = CurrencyLibrary.toId(poolKey.currency1);
            uint256 leftOver1 = poolManager.balanceOf(
                address(this),
                currency1Id
            );
            if (leftOver1 > 0)
                PoolManager(payable(address(poolManager))).onERC1155Received(
                    address(0),
                    address(0),
                    currency1Id,
                    leftOver1,
                    ""
                );

            // check locker balances.

            uint256 index = poolManager.lockedByLength() - 1;
            int256 currency0BalanceRaw = poolManager.getCurrencyDelta(
                index,
                poolKey.currency0
            );
            if (currency0BalanceRaw < 0) {
                revert("cannot delta currency0 negative");
            }
            uint256 currency0Balance = SafeCast.toUint256(currency0BalanceRaw);
            int256 currency1BalanceRaw = poolManager.getCurrencyDelta(
                index,
                poolKey.currency1
            );
            if (currency1BalanceRaw < 0) {
                revert("cannot delta currency1 negative");
            }
            uint256 currency1Balance = SafeCast.toUint256(currency1BalanceRaw);

            uint256 amount0 = FullMath.mulDiv(
                pMCallData.mintAmount,
                currency0Balance,
                totalSupply
            );
            uint256 amount1 = FullMath.mulDiv(
                pMCallData.mintAmount,
                currency1Balance,
                totalSupply
            );

            // safeTransfer to PoolManager.
            if (amount0 > 0) {
                ERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                    pMCallData.msgSender,
                    address(poolManager),
                    amount0
                );
                poolManager.settle(poolKey.currency0);
            }
            if (amount1 > 0) {
                ERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(
                    pMCallData.msgSender,
                    address(poolManager),
                    amount1
                );
                poolManager.settle(poolKey.currency1);
            }

            a0 = amount0;
            a1 = amount1;

            // updated total balances.
            currency0BalanceRaw = poolManager.getCurrencyDelta(
                index,
                poolKey.currency0
            );
            if (currency0BalanceRaw < 0) {
                revert("cannot delta currency0 negative");
            }
            currency0Balance = SafeCast.toUint256(currency0BalanceRaw);
            currency1BalanceRaw = poolManager.getCurrencyDelta(
                index,
                poolKey.currency1
            );
            if (currency1BalanceRaw < 0) {
                revert("cannot delta currency1 negative");
            }
            currency1Balance = SafeCast.toUint256(currency1BalanceRaw);

            // mint back the position.

            (uint160 sqrtPriceX96, , , , , ) = poolManager.getSlot0(
                PoolIdLibrary.toId(poolKey)
            );

            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(lowerTick),
                TickMath.getSqrtRatioAtTick(upperTick),
                currency0Balance,
                currency1Balance
            );

            if (liquidity > 0)
                poolManager.modifyPosition(
                    poolKey,
                    IPoolManager.ModifyPositionParams({
                        liquidityDelta: SafeCast.toInt256(uint256(liquidity)),
                        tickLower: lowerTick,
                        tickUpper: upperTick
                    })
                );

            leftOver0 = poolManager.balanceOf(address(this), currency0Id);

            leftOver1 = poolManager.balanceOf(address(this), currency1Id);

            if (leftOver0 > 0) {
                poolManager.mint(poolKey.currency0, address(this), leftOver0);
            }

            if (leftOver1 > 0) {
                poolManager.mint(poolKey.currency1, address(this), leftOver1);
            }
        }
    }

    function _lockAcquiredBurn(PoolManagerCallData memory pMCallData) internal {
        {
            // burn everything positions and erc1155

            uint256 totalSupply = totalSupply();

            Position.Info memory info = PoolManager(
                payable(address(poolManager))
            ).getPosition(
                    PoolIdLibrary.toId(poolKey),
                    address(this),
                    lowerTick,
                    upperTick
                );

            if (info.liquidity > 0)
                poolManager.modifyPosition(
                    poolKey,
                    IPoolManager.ModifyPositionParams({
                        liquidityDelta: -SafeCast.toInt256(
                            uint256(info.liquidity)
                        ),
                        tickLower: lowerTick,
                        tickUpper: upperTick
                    })
                );

            {
                uint256 currency0Id = CurrencyLibrary.toId(poolKey.currency0);
                uint256 leftOver0 = poolManager.balanceOf(
                    address(this),
                    currency0Id
                );

                if (leftOver0 > 0)
                    PoolManager(payable(address(poolManager)))
                        .onERC1155Received(
                            address(0),
                            address(0),
                            currency0Id,
                            leftOver0,
                            ""
                        );

                uint256 currency1Id = CurrencyLibrary.toId(poolKey.currency1);
                uint256 leftOver1 = poolManager.balanceOf(
                    address(this),
                    currency1Id
                );
                if (leftOver1 > 0)
                    PoolManager(payable(address(poolManager)))
                        .onERC1155Received(
                            address(0),
                            address(0),
                            currency1Id,
                            leftOver1,
                            ""
                        );
            }

            // check locker balances.

            uint256 index = poolManager.lockedByLength() - 1;
            int256 currency0BalanceRaw = poolManager.getCurrencyDelta(
                index,
                poolKey.currency0
            );
            if (currency0BalanceRaw > 0) {
                revert("cannot delta currency0 positive");
            }
            uint256 currency0Balance = SafeCast.toUint256(- currency0BalanceRaw);
            int256 currency1BalanceRaw = poolManager.getCurrencyDelta(
                index,
                poolKey.currency1
            );
            if (currency1BalanceRaw > 0) {
                revert("cannot delta currency1 positive");
            }
            uint256 currency1Balance = SafeCast.toUint256(- currency1BalanceRaw);

            {
                uint256 amount0 = FullMath.mulDiv(
                    pMCallData.burnAmount,
                    currency0Balance,
                    totalSupply
                );
                uint256 amount1 = FullMath.mulDiv(
                    pMCallData.burnAmount,
                    currency1Balance,
                    totalSupply
                );

                // take amounts and send them to receiver
                if (amount0 > 0) {
                    poolManager.take(
                        poolKey.currency0,
                        pMCallData.receiver,
                        amount0
                    );
                }
                if (amount1 > 0) {
                    poolManager.take(
                        poolKey.currency1,
                        pMCallData.receiver,
                        amount1
                    );
                }

                a0 = amount0;
                a1 = amount1;
            }

            // mint back the position.

            // updated total balances.
            currency0BalanceRaw = poolManager.getCurrencyDelta(
                index,
                poolKey.currency0
            );
            if (currency0BalanceRaw < 0) {
                revert("cannot delta currency0 negative");
            }
            currency0Balance = SafeCast.toUint256(currency0BalanceRaw);
            currency1BalanceRaw = poolManager.getCurrencyDelta(
                index,
                poolKey.currency1
            );
            if (currency1BalanceRaw < 0) {
                revert("cannot delta currency1 negative");
            }
            currency1Balance = SafeCast.toUint256(currency1BalanceRaw);

            {
                (uint160 sqrtPriceX96, , , , , ) = poolManager.getSlot0(
                    PoolIdLibrary.toId(poolKey)
                );

                uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                    sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(lowerTick),
                    TickMath.getSqrtRatioAtTick(upperTick),
                    currency0Balance,
                    currency1Balance
                );

                if (liquidity > 0)
                    poolManager.modifyPosition(
                        poolKey,
                        IPoolManager.ModifyPositionParams({
                            liquidityDelta: SafeCast.toInt256(
                                uint256(liquidity)
                            ),
                            tickLower: lowerTick,
                            tickUpper: upperTick
                        })
                    );
            }

            {
                uint256 currency0Id = CurrencyLibrary.toId(poolKey.currency0);
                uint256 currency1Id = CurrencyLibrary.toId(poolKey.currency1);

                uint256 leftOver0 = poolManager.balanceOf(
                    address(this),
                    currency0Id
                );

                uint256 leftOver1 = poolManager.balanceOf(
                    address(this),
                    currency1Id
                );

                if (leftOver0 > 0) {
                    poolManager.mint(
                        poolKey.currency0,
                        address(this),
                        leftOver0
                    );
                }

                if (leftOver1 > 0) {
                    poolManager.mint(
                        poolKey.currency1,
                        address(this),
                        leftOver1
                    );
                }
            }
        }
    }

    function getFee(
        PoolManager.PoolKey calldata
    ) external view returns (uint24) {
        return
            impactDirection != zeroForOne
                ? referenceFee + delta
                : referenceFee > delta
                ? referenceFee - delta
                : 0;
    }

    // #endegion hook functions

    //#region view/pure functions.

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: true,
                afterInitialize: false,
                beforeModifyPosition: false,
                afterModifyPosition: false,
                beforeSwap: true,
                afterSwap: false, // strategy of the vault
                beforeDonate: false,
                afterDonate: false
            });
    }

    //#endregion view/pure functions.

    //#region internal functions.

    function _getPrice(
        uint160 sqrtPriceX96_
    ) internal pure returns (uint256 price) {
        price = FullMath.mulDiv(sqrtPriceX96_, sqrtPriceX96_, 2 ** 96);
    }

    //#endregion internal functions.
}
