//  SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "forge-std/console.sol";
import "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IArrakisHookV1} from "../contracts/interfaces/IArrakisHookV1.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ArrakisHookV1} from "../contracts/ArrakisHookV1.sol";
import "./constants/FeeAmount.sol" as FeeAmount;
import {ArrakisHooksV1Factory} from "./utils/ArrakisHooksV1Factory.sol";
import {ArrakisHookV1Helper} from "./helper/ArrakisHookV1Helper.sol";
import {UniswapV4Swapper} from "./helper/UniswapV4Swapper.sol";

// import {ArrakisHookV1} from "../contracts/ArrakisHookV1.sol";

contract ArrakisHookV1Test is Test, ILockCallback {
    //#region constants.

    ArrakisHooksV1Factory public immutable factory;

    //#endregion constants.

    using TickMath for int24;
    using BalanceDeltaLibrary for BalanceDelta;

    PoolManager public poolManager;
    ArrakisHookV1 public arrakisHookV1;
    uint24 public fee;
    IPoolManager.PoolKey public poolKey;

    IERC20 public tokenA;
    IERC20 public tokenB;

    constructor() {
        factory = new ArrakisHooksV1Factory();
    }

    ///@dev let's assume for this test suite the price of tokenA/tokenB is equal to 1.

    function setUp() public {
        poolManager = new PoolManager(0);
        tokenA = new ERC20("Token A", "TOA");
        tokenB = new ERC20("Token B", "TOB");

        Hooks.Calls memory calls = Hooks.Calls({
            beforeInitialize: true,
            afterInitialize: false,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: false, // strategy of the vault
            beforeDonate: false,
            afterDonate: false
        });

        IArrakisHookV1.InitializeParams memory params = IArrakisHookV1
            .InitializeParams({
                poolManager: poolManager,
                name: "HOOK TOKEN",
                symbol: "HOT",
                rangeSize: uint24(FeeAmount.HIGH * 2), /// 2% price range.
                lowerTick: -FeeAmount.HIGH,
                upperTick: FeeAmount.HIGH,
                referenceFee: 200,
                referenceVolatility: 0, // TODO onced implemented in the hook
                ultimateThreshold: 0, // TODO onced implemented in the hook
                allocation: 1000, /// @dev in BPS => 10%
                c: 5000 /// @dev in BPS also => 50%
            });

        address hookAddress;
        (hookAddress, fee) = factory.deployWithPrecomputedHookAddress(
            params,
            calls
        );

        arrakisHookV1 = ArrakisHookV1(hookAddress);
    }

    function test_initialization() public {
        int16 tickSpacing = 200; ///@dev like 0.3% fees.

        // #region deploy pool on uniswap v4.

        //#region before assert checks.

        (
            Currency currency0,
            Currency currency1,
            uint24 f,
            int24 tS,
            IHooks hook
        ) = arrakisHookV1.poolKey();
        uint160 lastSqrtPriceX96 = arrakisHookV1.lastSqrtPriceX96();
        uint256 lastBlockNumber = arrakisHookV1.lastBlockNumber();

        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(0));
        assertEq(f, 0);
        assertEq(tS, 0);
        assertEq(address(hook), address(0));
        assertEq(lastSqrtPriceX96, 0);
        assertEq(lastBlockNumber, 0);

        //#endregion before assert checks.

        int24 tick = 1;
        uint160 sqrtPriceX96 = tick.getSqrtRatioAtTick();
        int24 tickResult = _initialize(sqrtPriceX96, tickSpacing);

        assertEq(tick, tickResult);

        // #region assert check.

        (currency0, currency1, f, tS, hook) = arrakisHookV1.poolKey();
        lastSqrtPriceX96 = arrakisHookV1.lastSqrtPriceX96();
        lastBlockNumber = arrakisHookV1.lastBlockNumber();

        assertEq(Currency.unwrap(currency0), address(tokenA));
        assertEq(Currency.unwrap(currency1), address(tokenB));
        assertEq(f, fee);
        assertEq(tS, tickSpacing);
        assertEq(address(hook), address(arrakisHookV1));
        assertEq(lastSqrtPriceX96, sqrtPriceX96);
        assertEq(lastBlockNumber, block.number);

        /// @dev we can consider here that beforeInitialize hook is working good.

        // #endregion assert check.

        // #endregion deploy pool on uniswap v4.
    }

    function test_beforeSwap() public {
        address vb = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045; // swapper

        deal(address(tokenA), address(this), 1000);
        deal(address(tokenB), address(this), 1000);

        uint160 sqrtPriceX96 = int24(1).getSqrtRatioAtTick();
        int16 tickSpacing = 200;

        _initialize(sqrtPriceX96, tickSpacing);

        ///@dev do swap on the pool to simulate price move for computing dynamic fees.

        // #region create a position on that pool.

        uint160 sqrtPriceX96A = (-FeeAmount.HIGH).getSqrtRatioAtTick();
        uint160 sqrtPriceX96B = FeeAmount.HIGH.getSqrtRatioAtTick();

        uint128 liquidity = ArrakisHookV1Helper.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceX96A,
            sqrtPriceX96B,
            1000,
            1000
        );

        bytes memory data = abi.encode(
            -FeeAmount.HIGH,
            FeeAmount.HIGH,
            liquidity
        );

        poolManager.lock(data);

        // #endregion create a position on that pool.

        // #region do swap to move the price.
        /// @dev to do multiple swap.

        UniswapV4Swapper swapper = new UniswapV4Swapper(poolManager);

        vm.startPrank(vb);

        deal(address(tokenA), vb, 500);

        tokenA.approve(address(swapper), 500);

        assertEq(200, arrakisHookV1.getFee(poolKey)); /// @dev it's what we set earlier.

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 500,
            sqrtPriceLimitX96: (-FeeAmount.HIGH / 2).getSqrtRatioAtTick()
        });

        swapper.swap(poolKey, params);

        vm.stopPrank();

        assertEq(200, arrakisHookV1.getFee(poolKey)); /// @dev it's what we set earlier.
        // #endregion do swap to move the price.

        /// TODO check that swap happening inside the same block has the same fees.
        /// TODO move to next block.
        vm.roll(block.number + 1);
        assertEq(200, arrakisHookV1.getFee(poolKey)); /// @dev it's what we set earlier.

        /// TODO do another swap

        vm.startPrank(vb);

        deal(address(tokenB), vb, 200);

        tokenB.approve(address(swapper), 200);

        assertEq(200, arrakisHookV1.getFee(poolKey)); /// @dev it's what we set earlier.

        params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: 200,
            sqrtPriceLimitX96: int24(1).getSqrtRatioAtTick()
        });

        swapper.swap(poolKey, params);

        vm.stopPrank();

        /// TODO check different fee charging.
        assertEq(0, arrakisHookV1.getFee(poolKey));
    }

    function test_mint() public {
        address vb = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045; // minter

        deal(address(tokenA), vb, 200);
        deal(address(tokenB), vb, 200);

        uint160 sqrtPriceX96 = int24(1).getSqrtRatioAtTick();
        int16 tickSpacing = 200;

        _initialize(sqrtPriceX96, tickSpacing);

        uint160 sqrtPriceX96A = (-FeeAmount.HIGH).getSqrtRatioAtTick();
        uint160 sqrtPriceX96B = FeeAmount.HIGH.getSqrtRatioAtTick();

        uint128 liquidity = ArrakisHookV1Helper.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceX96A,
            sqrtPriceX96B,
            200,
            200
        );

        vm.startPrank(vb);

        tokenA.approve(address(arrakisHookV1), 200);
        tokenB.approve(address(arrakisHookV1), 200);

        arrakisHookV1.mint(uint256(liquidity), vb);
        assertEq(arrakisHookV1.balanceOf(vb), 20_000);

        vm.stopPrank();
    }

    function test_burn() public {

        // #region minting before burning.

        address vb = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045; // minter

        deal(address(tokenA), vb, 200);
        deal(address(tokenB), vb, 200);

        uint160 sqrtPriceX96 = int24(1).getSqrtRatioAtTick();
        int16 tickSpacing = 200;

        _initialize(sqrtPriceX96, tickSpacing);

        uint160 sqrtPriceX96A = (-FeeAmount.HIGH).getSqrtRatioAtTick();
        uint160 sqrtPriceX96B = FeeAmount.HIGH.getSqrtRatioAtTick();

        uint128 liquidity = ArrakisHookV1Helper.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceX96A,
            sqrtPriceX96B,
            200,
            200
        );

        vm.startPrank(vb);

        tokenA.approve(address(arrakisHookV1), 200);
        tokenB.approve(address(arrakisHookV1), 200);

        arrakisHookV1.mint(uint256(liquidity), vb);


        // #endregion minting before burning.

        // #region burning.

        arrakisHookV1.burn(arrakisHookV1.balanceOf(vb), vb);

        // #endregion burning.

        vm.stopPrank();

        assertGe(199, tokenA.balanceOf(vb));
        assertGe(199, tokenB.balanceOf(vb));
    }

    // #region lockAcquired callback.

    function lockAcquired(
        uint256,
        bytes calldata data
    ) external returns (bytes memory result) {
        (int24 tickLower, int24 tickUpper, uint128 liquidity) = abi.decode(
            data,
            (int24, int24, uint128)
        );
        BalanceDelta balanceDelta = poolManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: SafeCast.toInt256(uint256(liquidity))
            })
        );

        result = abi.encode(balanceDelta);

        tokenA.transfer(
            address(poolManager),
            SafeCast.toUint256(int256(balanceDelta.amount0()))
        );

        poolManager.settle(poolKey.currency0);

        tokenB.transfer(
            address(poolManager),
            SafeCast.toUint256(int256(balanceDelta.amount1()))
        );

        poolManager.settle(poolKey.currency1);
    }

    // #endregion lockAcquired callback.

    // #region internal functions.

    function _initialize(
        uint160 sqrtPriceX96_,
        int16 tickSpacing_
    ) internal returns (int24) {
        poolKey = IPoolManager.PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: fee,
            tickSpacing: tickSpacing_,
            hooks: IHooks(address(arrakisHookV1))
        });

        return poolManager.initialize(poolKey, sqrtPriceX96_);
    }

    // #endregion internal functions.
}
