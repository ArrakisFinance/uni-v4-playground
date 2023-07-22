// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";

/// @dev Arrakis common vault
interface IArrakisHookV1 is IERC20 {
    //#region structs.

    struct InitializeParams {
        IPoolManager.PoolKey poolKey;
        uint160 lastSqrtPriceX96;
        uint8 referenceFee;
        uint8 referenceVolatility;
        uint24 rangeSize;
        uint8 ultimateThreshold;
        uint256 rebalanceFrequence;
        uint8 allocation;
    }

    //#endregion structs.

    //#region events.

    event LogMint(address indexed receiver, uint256 mintAmount, uint256 amount0In, uint256 amount1In);

    event LogBurn(address indexed receiver, uint256 burnAmount, uint256 amount0Out, uint256 amount1Out);

    event LogCollectedFees(uint256 fee0, uint256 fee1);

    //#endregion events.

    // #region state modifiying functions.

    function initialize(InitializeParams memory initializeParams_) external;

    function mint(uint256 mintAmount_, address receiver_) external returns (uint256 amount0, uint256 amount1);

    function burn(uint256 burnAmount_, address receiver_) external returns (uint256 amount0, uint256 amount1);

    // #endregion state modifiying functions.

    // #region state reading functions.

    function poolKey() external view returns (IPoolManager.PoolKey memory);

    /// @dev Al N delta constant.
    function c() external view returns (uint256);

    /// @dev base fee when volatility is average
    function referenceFee() external view returns (uint8);

    /// @dev base volatility, above that level we will proportionally increase referenceFee
    /// below we will proportionally decrease the referenceFee.
    function referenceVolatility() external view returns (uint8);

    /// @dev middle range size.
    function rangeSize() external view returns (int24);

    /// @dev ultimate threshold.
    function ultimateThreshold() external view returns (uint8);

    /// @dev frequence at which rebalance will happen.
    function rebalanceFrequence() external view returns (uint256);

    /// @dev percentage of tokens to put in action.
    function allocation() external view returns (uint8);

    // #endregion state reading functions.

    // option 1 : fee rebate idea for the swapper that modify the position.
}
