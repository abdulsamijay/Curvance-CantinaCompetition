// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { BaseWrappedAggregator } from "./BaseWrappedAggregator.sol";
import { IStakedFrax } from "contracts/interfaces/external/frax/IStakedFrax.sol";

contract StakedFraxAggregator is BaseWrappedAggregator {
    address public sFrax;
    address public frax;
    address public fraxAggregator;

    constructor(address _sFrax, address _frax, address _fraxAggregator) {
        sFrax = _sFrax;
        frax = _frax;
        fraxAggregator = _fraxAggregator;
    }

    function underlyingAssetAggregator()
        public
        view
        override
        returns (address)
    {
        return fraxAggregator;
    }

    function getWrappedAssetWeight() public view override returns (uint256) {
        // Staked Frax contract returns naturally in 1e18 format,
        // so no adjustment needed to return decimals.
        return IStakedFrax(sFrax).pricePerShare();
    }
}
