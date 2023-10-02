// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "contracts/layerzero/OFTV2.sol";

contract CVE is OFTV2 {
    /// CONSTANTS ///

    uint256 public constant DENOMINATOR = 10000; // Scalar for math

    /// MODIFIERS ///

    modifier onlyMessagingHub() {
        require(
            msg.sender == centralRegistry.protocolMessagingHub(),
            "FeeAccumulator: UNAUTHORIZED"
        );
        _;
    }

    /// CONSTRUCTOR ///

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 sharedDecimals_,
        address lzEndpoint_,
        ICentralRegistry centralRegistry_
    ) OFTV2(name_, symbol_, sharedDecimals_, lzEndpoint_, centralRegistry_) {}

    /// EXTERNAL FUNCTIONIS ///

    /// @notice Mint new gauge emissions
    /// @dev Allows the VotingHub to mint new gauge emissions.
    /// @param gaugeEmissions The amount of gauge emissions to be minted
    /// @param gaugePool The address of the gauge pool where emissions will be configured
    /// Emission amount is multiplied by the lock boost value from the central registry
    /// Resulting tokens are minted to the voting hub contract.
    function mintGaugeEmissions(
        uint256 gaugeEmissions,
        address gaugePool
    ) external {
        require(
            msg.sender == centralRegistry.protocolMessagingHub(),
            "CVE: UNAUTHORIZED"
        );
        _mint(
            gaugePool,
            (gaugeEmissions * centralRegistry.lockBoostValue()) / DENOMINATOR
        );
    }

    /// PUBLIC FUNCTIONS ///

    function sendAndCall(
        address from,
        uint16 dstChainId,
        bytes32 toAddress,
        uint256 amount,
        bytes calldata payload,
        uint64 dstGasForCall,
        LzCallParams calldata callParams
    ) public payable override onlyMessagingHub {
        super.sendAndCall(
            from,
            dstChainId,
            toAddress,
            amount,
            payload,
            dstGasForCall,
            callParams
        );
    }
}
