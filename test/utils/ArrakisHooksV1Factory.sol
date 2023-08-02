// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {ArrakisHookV1, IArrakisHookV1} from "../../contracts/ArrakisHookV1.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract ArrakisHooksV1Factory {
    function deployWithPrecomputedHookAddress(
        IArrakisHookV1.InitializeParams memory params_,
        Hooks.Calls memory calls_
    ) external returns (address, uint24) {
        uint160 prefix = _getPrefix(calls_);
        for (uint256 i = 0; i < 1500; i++) {
            bytes32 salt = bytes32(i);

            bytes32 bytecodeHash = keccak256(
                abi.encodePacked(
                    type(ArrakisHookV1).creationCode,
                    abi.encode(params_)
                )
            );
            bytes32 hash = keccak256(
                abi.encodePacked(
                    bytes1(0xff),
                    address(this),
                    salt,
                    bytecodeHash
                )
            );

            address expectedAddress = address(uint160(uint256(hash)));

            if (_doesAddressStartWith(expectedAddress, prefix)) {
                return (_deploy(params_, salt), SafeCast.toUint24(uint256(prefix)));
            }
        }

        return (address(0), SafeCast.toUint24(uint256(prefix)));
    }

    function _doesAddressStartWith(
        address address_,
        uint160 prefix_
    ) private pure returns (bool) {
        return uint160(address_) / (2 ** (8 * (19))) == prefix_;
    }

    function _deploy(
        IArrakisHookV1.InitializeParams memory params_,
        bytes32 salt_
    ) internal returns (address) {
        return address(new ArrakisHookV1{salt: salt_}(params_));
    }

    function _getPrefix(
        Hooks.Calls memory calls_
    ) internal pure returns (uint160) {
        uint160 prefix;
        if (calls_.beforeInitialize) prefix = 1 << 159;
        if (calls_.afterInitialize) prefix = prefix | (1 << 158);
        if (calls_.beforeModifyPosition) prefix = prefix | (1 << 157);
        if (calls_.afterModifyPosition) prefix = prefix | (1 << 156);
        if (calls_.beforeSwap) prefix = prefix | (1 << 155);
        if (calls_.afterSwap) prefix = prefix | (1 << 154);
        if (calls_.beforeDonate) prefix = prefix | (1 << 153);
        if (calls_.afterDonate) prefix = prefix | (1 << 152);

        return prefix / (2 ** (8 * (19)));
    }
}
