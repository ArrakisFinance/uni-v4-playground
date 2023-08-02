//  SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {IArrakisHookV1} from "../contracts/interfaces/IArrakisHookV1.sol";
import {ArrakisHookV1} from "../contracts/ArrakisHookV1.sol";
import "./constants/FeeAmount.sol" as FeeAmount;
import {TokenA} from "./erc20/TokenA.sol";
import {TokenB} from "./erc20/TokenB.sol";
import {ArrakisHooksV1Factory} from "./utils/ArrakisHooksV1Factory.sol";

// import {ArrakisHookV1} from "../contracts/ArrakisHookV1.sol";

contract ArrakisHookV1Test is Test {
    //#region constants.

    ArrakisHooksV1Factory public immutable factory;

    //#endregion constants.

    using TickMath for int24;

    PoolManager public poolManager;
    ArrakisHookV1 public arrakisHookV1;
    uint24 fee;
    // uint160 public sqrtPriceX96;

    IERC20 public tokenA;
    IERC20 public tokenB;

    constructor() {
        factory = new ArrakisHooksV1Factory();
    }

    ///@dev let's assume for this test suite the price of tokenA/tokenB is equal to 1.

    function setUp() public {
        poolManager = new PoolManager(0);
        tokenA = new TokenA(address(this));
        tokenB = new TokenB(address(this));

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
        (hookAddress, fee) = factory.deployWithPrecomputedHookAddress(params, calls);

        arrakisHookV1 = ArrakisHookV1(
            hookAddress
        );
    }

    function test_initialization() public {
        int16 tickSpacing = 60; ///@dev like 0.3% fees.

        // #region deploy pool on uniswap v4.

        IPoolManager.PoolKey memory poolKey = IPoolManager.PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(arrakisHookV1))
        });

        int24 tick = 1;
        int24 tickResult = poolManager.initialize(poolKey, tick.getSqrtRatioAtTick());

        assertEq(tick, tickResult);

        // #endregion deploy pool on uniswap v4.
    }
}
