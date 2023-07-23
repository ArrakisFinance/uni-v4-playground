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

/// @dev Al N spread V1
contract ArrakisHookV1 is IArrakisHookV1, BaseHook, ERC20, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using TickMath for int24;
    using Pool for Pool.State;
    using SafeERC20 for ERC20;

    //#region constants.

    uint8 public immutable c;
    uint8 public immutable referenceFee;
    uint256 public immutable rebalanceFrequence;

    //#endregion constants.

    //#region properties.

    /// @dev should not be settable.
    PoolManager.PoolKey public override poolKey;
    uint160 public lastSqrtPriceX96;
    uint8 public referenceVolatility;
    uint24 public rangeSize;
    int24 public lowerTick;
    int24 public upperTick;
    uint8 public ultimateThreshold;
    uint8 public allocation;
    uint256 public lastBlockNumber;
    uint256 public currentBlockNumber;

    uint8 public delta;
    bool public impactDirection;

    bool public zeroForOne; // transient.

    //#endregion properties.

    struct InitializeParams {
        PoolManager poolManager;
        string name;
        string symbol;
        uint256 rebalanceFrequence_;
        uint24 rangeSize;
        int24 lowerTick;
        int24 upperTick;
        uint8 referenceFee;
        uint8 referenceVolatility; // not use for now
        uint8 ultimateThreshold;
        uint8 allocation;
        uint8 c;
    }

    struct PoolManagerCallData {
        uint8 actionType; // 0 for mint, 1 for burn, 2 for rebalance.
        bytes1 sendOrTake0;
        uint256 amount0;
        bytes1 sendOrTake1;
        uint256 amount1;
        uint256 burnAmount;
        address receiver;
        bytes payload;
    }

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
        lastBlockNumber = currentBlockNumber = block.number;
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

            delta = SafeCast.toUint8(
                FullMath.mulDiv(
                    c,
                    price > lastPrice
                        ? price - lastPrice
                        : lastPrice - price * 1_000_000,
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

        uint256 totalSupply = totalSupply();

        (uint160 sqrtPriceX96, , , , , ) = poolManager.getSlot0(
            PoolIdLibrary.toId(poolKey)
        );

        Position.Info memory positionInfo = PoolManager(
            payable(address(poolManager))
        ).getPosition(
                PoolIdLibrary.toId(poolKey),
                address(this),
                lowerTick,
                upperTick
            );

        _burn(msg.sender, burnAmount_);

        uint256 liquidityBurned_ = FullMath.mulDiv(
            burnAmount_,
            positionInfo.liquidity,
            totalSupply
        );
        uint256 liquidityBurned = SafeCast.toUint128(liquidityBurned_);

        PoolManager.ModifyPositionParams memory modPosParams = IPoolManager
            .ModifyPositionParams({
                tickLower: lowerTick,
                tickUpper: upperTick,
                liquidityDelta: -SafeCast.toInt128(
                    SafeCast.toInt256(liquidityBurned)
                )
            });

        bytes memory poolManagerData = abi.encodeWithSelector(
            PoolManager.modifyPosition.selector,
            poolKey,
            modPosParams
        );

        Pool.State memory state;
        (
            state.slot0,
            state.feeGrowthGlobal0X128,
            state.feeGrowthGlobal1X128,
            state.liquidity
        ) = poolManager.pools(PoolIdLibrary.toId(poolKey));

        state.ticks = poolManager.pools(PoolIdLibrary.toId(poolKey)).ticks;

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = Pool
            .getFeeGrowthInside(state, lowerTick, upperTick);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(lowerTick),
            TickMath.getSqrtRatioAtTick(upperTick),
            SafeCast.toUint128(liquidityBurned)
        );

        // compute current fees earned
        uint256 fee0 = _computeFeesEarned(
            positionInfo.feeGrowthInside0LastX128,
            feeGrowthInside0X128,
            positionInfo.liquidity
        );
        uint256 fee1 = _computeFeesEarned(
            positionInfo.feeGrowthInside1LastX128,
            feeGrowthInside1X128,
            positionInfo.liquidity
        );

        uint256 leftOver0 = poolManager.balanceOf(
            address(this),
            poolKey.currency0.toId()
        );

        uint256 leftOver1 = poolManager.balanceOf(
            address(this),
            poolKey.currency1.toId()
        );

        amount0 += FullMath.mulDiv(burnAmount_, fee0 + leftOver0, totalSupply);
        amount1 += FullMath.mulDiv(burnAmount_, fee1 + leftOver1, totalSupply);

        bytes memory data = abi.encode(
            PoolManagerCallData({
                actionType: 1,
                sendOrTake0: 1,
                amount0: fee0,
                sendOrTake1: 1,
                burnAmount: burnAmount_,
                receiver: receiver_,
                amount1: fee1,
                data: poolManagerData
            })
        );

        poolManager.lock(data);
    }

    function mint(
        uint256 mintAmount_,
        address receiver_
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(mintAmount_ > 0, "mint 0");

        uint256 totalSupply = totalSupply();

        (uint160 sqrtPriceX96, , , , , ) = poolManager.getSlot0(
            PoolIdLibrary.toId(poolKey)
        );

        if (totalSupply > 0) {
            (
                uint256 amount0Current,
                uint256 amount1Current
            ) = _getUnderlyingBalances();

            amount0 = FullMath.mulDivRoundingUp(
                amount0Current,
                mintAmount_,
                totalSupply
            );
            amount1 = FullMath.mulDivRoundingUp(
                amount1Current,
                mintAmount_,
                totalSupply
            );
        } else {
            // if supply is 0 mintAmount == liquidity to deposit
            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                lowerTick.getSqrtRatioAtTick(),
                upperTick.getSqrtRatioAtTick(),
                SafeCast.toUint128(mintAmount_)
            );
        }

        // deposit as much new liquidity as possible
        uint128 liquidityMinted = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            lowerTick.getSqrtRatioAtTick(),
            upperTick.getSqrtRatioAtTick(),
            amount0,
            amount1
        );

        PoolManager.ModifyPositionParams memory modPosParams = PoolManager
            .ModifyPositionParams({
                tickLower: lowerTick,
                tickUpper: upperTick,
                liquidityDelta: liquidityMinted
            });

        bytes memory poolManagerData = abi.encodeWithSelector(
            PoolManager.modifyPosition.selector,
            poolKey,
            modPosParams
        );

        bytes memory data = abi.encode(
            PoolManagerCallData({
                actionType: 0,
                sendOrTake0: 0,
                amount0: amount0,
                sendOrTake1: 0,
                burnAmount: 0,
                receiver: address(0),
                amount1: amount1,
                data: poolManagerData
            })
        );
        poolManager.lock(data);

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
        if (pMCallData.action == 0) {
            (bool success, ) = address(poolManager).call(pMCallData.payload);

            require(success, "mint failed");

            // send the tokens to poolManager and settle.
            if (pMCallData.sendOrTake0 == 0 && pMCallData.amount0 > 0) {
                ERC20(address(poolKey.currency0)).safeTransferFrom(
                    msg.sender,
                    address(poolManager),
                    pMCallData.amount0
                );
                poolManager.settle(poolKey.currency0);
            }
            if (pMCallData.sendOrTake1 == 0 && pMCallData.amount1 > 0) {
                ERC20(address(poolKey.currency1)).safeTransferFrom(
                    msg.sender,
                    address(poolManager),
                    pMCallData.amount1
                );
                poolManager.settle(poolKey.currency1);
            }
        }
        // second case burn action.
        if (pMCallData.action == 1) {
            (bool success, bytes memory returnData) = address(poolManager).call(
                pMCallData.payload
            );

            require(success, "burn failed");

            BalanceDelta balanceDelta = abi.decode(returnData, (BalanceDelta));

            uint256 totalSupply = totalSupply();

            // take and settle
            if (pMCallData.sendOrTake0 == 1 && pMCallData.amount0 > 0) {
                uint256 leftOver0 = poolManager.balanceOf(
                    address(this),
                    poolKey.currency0.toId()
                );

                poolManager.onReceivedERC1155(
                    address(0),
                    address(0),
                    poolKey.currency0.toId(),
                    FullMath.mulDiv(
                        pMCallData.burnAmount,
                        leftOver0,
                        totalSupply
                    ),
                    ""
                );
                poolManager.take(
                    poolKey.currency0,
                    pMCallData.receiver,
                    FullMath.mulDiv(
                        pMCallData.burnAmount,
                        leftOver0 + pMCallData.amount0,
                        totalSupply
                    ) + (balanceDelta.amount0() - pMCallData.amount0)
                );
            }
            if (pMCallData.sendOrTake1 == 1 && pMCallData.amount1 > 0) {
                uint256 leftOver1 = poolManager.balanceOf(
                    address(this),
                    poolKey.currency1.toId()
                );

                poolManager.onReceivedERC1155(
                    address(0),
                    address(0),
                    poolKey.currency1.toId(),
                    FullMath.mulDiv(
                        pMCallData.burnAmount,
                        leftOver1,
                        totalSupply
                    ),
                    ""
                );
                poolManager.take(
                    poolKey.currency1,
                    pMCallData.receiver,
                    FullMath.mulDiv(
                        pMCallData.burnAmount,
                        leftOver1 + pMCallData.amount1,
                        totalSupply
                    ) + (balanceDelta.amount1() - pMCallData.amount1)
                );
            }
        }
    }

    function getFee(PoolManager.PoolKey calldata) external returns (uint24) {
        return
            impactDirection != zeroForOne
                ? referenceFee + delta
                : referenceFee > delta
                ? referenceFee - delta
                : 0;
    }

    function getFeeGrowthInside(
        Pool.State memory self,
        int24 tickLower,
        int24 tickUpper
    )
        external
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        Pool.TickInfo memory lower = self.ticks[tickLower];
        Pool.TickInfo memory upper = self.ticks[tickUpper];
        int24 tickCurrent = self.slot0.tick;

        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 =
                    lower.feeGrowthOutside0X128 -
                    upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    lower.feeGrowthOutside1X128 -
                    upper.feeGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                feeGrowthInside0X128 =
                    upper.feeGrowthOutside0X128 -
                    lower.feeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    upper.feeGrowthOutside1X128 -
                    lower.feeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 =
                    self.feeGrowthGlobal0X128 -
                    lower.feeGrowthOutside0X128 -
                    upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    self.feeGrowthGlobal1X128 -
                    lower.feeGrowthOutside1X128 -
                    upper.feeGrowthOutside1X128;
            }
        }
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

    function getUnderlyingBalances()
        public
        view
        returns (uint256 amount0Current, uint256 amount1Current)
    {}

    function _computeFeesEarned(
        uint256 feeGrowthInsideLast_,
        uint256 feeGrowthInside_,
        uint128 liquidity_
    ) private pure returns (uint256 fee) {
        unchecked {
            fee = FullMath.mulDiv(
                liquidity_,
                feeGrowthInside_ - feeGrowthInsideLast_,
                0x100000000000000000000000000000000
            );
        }
    }

    //#endregion view/pure functions.

    //#region internal functions.

    function _getUnderlyingBalances()
        internal
        view
        returns (uint256 amount0Current, uint256 amount1Current)
    {
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128
        ) = poolManager.getPosition(
                PoolIdLibrary.toId(poolKey),
                address(this),
                lowerTick,
                upperTick
            );

        Pool.State memory state;
        (
            state.slot0,
            state.feeGrowthGlobal0X128,
            state.feeGrowthGlobal1X128,
            state.liquidity
        ) = poolManager.pools(PoolIdLibrary.toId(poolKey));

        state.ticks = poolManager.pools(PoolIdLibrary.toId(poolKey)).ticks;

        (uint160 sqrtPriceX96, , , , , ) = poolManager.getSlot0(
            PoolIdLibrary.toId(poolKey)
        );

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = state
            .getFeeGrowthInside(lowerTick, upperTick);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(lowerTick),
                TickMath.getSqrtRatioAtTick(upperTick),
                liquidity
            );

        // compute current fees earned
        uint256 fee0 = _computeFeesEarned(
            feeGrowthInside0LastX128,
            feeGrowthInside0X128,
            liquidity
        );
        uint256 fee1 = _computeFeesEarned(
            feeGrowthInside1LastX128,
            feeGrowthInside1X128,
            liquidity
        );

        // balance of ERC1155 token.
        uint256 leftOver0 = poolManager.balanceOf(
            address(this),
            poolKey.currency0.toId()
        );
        uint256 leftOver1 = poolManager.balanceOf(
            address(this),
            poolKey.currency1.toId()
        );

        amount0Current = amount0 + fee0 + leftOver0;
        amount1Current = amount1 + fee1 + leftOver1;
    }

    function _getPrice(
        uint160 sqrtPriceX96_
    ) internal pure returns (uint256 price) {
        price = FullMath.mulDiv(sqrtPriceX96_, sqrtPriceX96_, 2 ** 96);
    }

    //#endregion internal functions.
}
