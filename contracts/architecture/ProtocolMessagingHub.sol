// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ERC165Checker } from "contracts/libraries/ERC165Checker.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuard.sol";
import { SafeTransferLib } from "contracts/libraries/SafeTransferLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { GaugeController } from "contracts/gauge/GaugeController.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICVE, LzCallParams } from "contracts/interfaces/ICVE.sol";
import { IFeeAccumulator, EpochRolloverData } from "contracts/interfaces/IFeeAccumulator.sol";
import { ICentralRegistry, OmnichainData } from "contracts/interfaces/ICentralRegistry.sol";
import { SwapRouter, LzTxObj } from "contracts/interfaces/layerzero/IStargateRouter.sol";
import { PoolData } from "contracts/interfaces/IProtocolMessagingHub.sol";

contract ProtocolMessagingHub is ReentrancyGuard {
    /// CONSTANTS ///

    /// @notice Scalar for math
    uint256 public constant DENOMINATOR = 10000;
    /// @notice CVE contract address
    ICVE public immutable CVE;
    /// @notice Address of fee token
    address public immutable feeToken;
    /// @notice Curvance DAO hub
    ICentralRegistry public immutable centralRegistry;

    /// ERRORS ///

    error ProtocolMessagingHub__FeeTokenIsZeroAddress();
    error ProtocolMessagingHub__CallerIsNotStargateRouter();
    error ProtocolMessagingHub__ConfigurationError();
    error ProtocolMessagingHub__InsufficientGasToken();

    /// MODIFIERS ///

    modifier onlyAuthorized() {
        require(
            centralRegistry.isHarvester(msg.sender) ||
                msg.sender == centralRegistry.feeAccumulator(),
            "ProtocolMessagingHub: UNAUTHORIZED"
        );
        _;
    }

    modifier onlyDaoPermissions() {
        require(
            centralRegistry.hasDaoPermissions(msg.sender),
            "ProtocolMessagingHub: UNAUTHORIZED"
        );
        _;
    }

    modifier onlyLayerZero() {
        require(
            msg.sender == centralRegistry.CVE(),
            "ProtocolMessagingHub: UNAUTHORIZED"
        );
        _;
    }

    receive() external payable {}

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry centralRegistry_, address feeToken_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert ProtocolMessagingHub__ConfigurationError();
        }
        if (feeToken_ == address(0)) {
            revert ProtocolMessagingHub__FeeTokenIsZeroAddress();
        }

        centralRegistry = centralRegistry_;
        CVE = ICVE(centralRegistry.CVE());
        feeToken = feeToken_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Used when fees are received from other chains.
    /// @param token The token contract on the local chain.
    /// @param amountLD The qty of local _token contract tokens.
    function sgReceive(
        uint16 /* chainId */, // The remote chainId sending the tokens
        bytes memory /* srcAddress */, // The remote Bridge address
        uint256 /* nonce */, // The message ordering nonce
        address token,
        uint256 amountLD,
        bytes memory /* payload */
    ) external payable {
        if (
            msg.sender !=
            IFeeAccumulator(centralRegistry.feeAccumulator()).stargateRouter()
        ) {
            revert ProtocolMessagingHub__CallerIsNotStargateRouter();
        }

        SafeTransferLib.safeTransfer(
            token,
            centralRegistry.feeAccumulator(),
            amountLD
        );
    }

    /// @notice Sends gauge emission information to multiple destination chains
    /// @param dstChainId Destination chain ID where the message data should be
    ///                   sent
    /// @param toAddress The destination address specified by `dstChainId`
    /// @param payload The payload data that is sent along with the message
    /// @param dstGasForCall The amount of gas that should be provided for
    ///                      the call on the destination chain
    /// @param callParams AdditionalParameters for the call, as LzCallParams
    /// @dev We redundantly pass adapterParams & callParams so we do not
    ///      need to coerce data in the function, calls with this function will
    ///      have messageType = 3
    function sendGaugeEmissions(
        uint16 dstChainId,
        bytes32 toAddress,
        bytes calldata payload,
        uint64 dstGasForCall,
        LzCallParams calldata callParams
    ) external onlyAuthorized {
        // Validate that we are aiming for a supported chain
        if (
            centralRegistry
                .supportedChainData(
                    centralRegistry.messagingToGETHChainId(dstChainId)
                )
                .isSupported < 2
        ) {
            revert ProtocolMessagingHub__ConfigurationError();
        }
        CVE.sendAndCall{
            value: CVE.estimateSendAndCallFee(
                dstChainId,
                toAddress,
                0,
                payload,
                dstGasForCall,
                // may need to turn on ZRO in the future but can redeploy
                // ProtocolMessagingHub
                false,
                callParams.adapterParams
            )
        }(
            address(this),
            dstChainId,
            toAddress,
            0,
            payload,
            dstGasForCall,
            callParams
        );
    }

    /// @notice Sends fee tokens to the Fee Accumulator on `dstChainId`
    /// @param to The address Stargate Endpoint to call
    /// @param poolData Stargate pool routing data
    /// @param lzTxParams Supplemental LayerZero parameters for the transaction
    /// @param payload Additional payload data
    function sendFees(
        address to,
        PoolData calldata poolData,
        LzTxObj calldata lzTxParams,
        bytes calldata payload
    ) external payable onlyAuthorized {
        {
            // Avoid stack too deep
            uint256 GETHChainId = centralRegistry.messagingToGETHChainId(
                poolData.dstChainId
            );
            OmnichainData memory operator = centralRegistry.omnichainOperators(
                to,
                GETHChainId
            );

            // Validate that the operator is authorized
            if (operator.isAuthorized < 2) {
                revert ProtocolMessagingHub__ConfigurationError();
            }

            // Validate that the operator messaging chain matches
            // the destination chain id
            if (operator.messagingChainId != poolData.dstChainId) {
                revert ProtocolMessagingHub__ConfigurationError();
            }

            // Validate that we are aiming for a supported chain
            if (
                centralRegistry.supportedChainData(GETHChainId).isSupported < 2
            ) {
                revert ProtocolMessagingHub__ConfigurationError();
            }
        }

        address stargateRouter = IFeeAccumulator(
            centralRegistry.feeAccumulator()
        ).stargateRouter();

        bytes memory bytesTo = new bytes(32);
        assembly {
            mstore(add(bytesTo, 32), to)
        }

        {
            // Scoping to avoid stack too deep
            (uint256 messageFee, ) = this.quoteStargateFee(
                SwapRouter(stargateRouter),
                uint16(poolData.dstChainId),
                1,
                bytesTo,
                "",
                lzTxParams
            );

            // Validate that we have sufficient fees to send crosschain
            if (msg.value < messageFee) {
                revert ProtocolMessagingHub__InsufficientGasToken();
            }
        }

        // Pull the fee token from the fee accumulator
        // This will revert if we've misconfigured fee token contract supply
        // by `amountLD`
        SafeTransferLib.safeTransferFrom(
            feeToken,
            centralRegistry.feeAccumulator(),
            address(this),
            poolData.amountLD
        );

        SwapperLib.approveTokenIfNeeded(
            feeToken,
            stargateRouter,
            poolData.amountLD
        );

        // Sends funds to feeAccumulator on another chain
        SwapRouter(stargateRouter).swap{ value: msg.value }(
            uint16(poolData.dstChainId),
            poolData.srcPoolId,
            poolData.dstPoolId,
            payable(address(this)),
            poolData.amountLD,
            poolData.minAmountLD,
            lzTxParams,
            bytesTo,
            payload
        );
    }

    /// @notice Handles actions based on the payload provided from calling
    ///         CVE's OFT integration where messageType:
    ///         1: corresponds to locked token information transfer
    ///         2: receiving finalized token epoch rewards information
    ///         3: corresponds to configuring gauge emissions for the chain
    /// @dev amount is always set to 0 since we are moving data,
    ///      or minting gauge emissions here
    /// @param srcChainId The source chain ID from which the calldata
    ///                   was received
    /// @param srcAddress The CVE source address
    /// @param from The address from which the OFT was sent
    /// @param payload The message calldata, encoded in bytes
    function onOFTReceived(
        uint16 srcChainId,
        bytes memory srcAddress,
        uint64, // nonce
        bytes32 from,
        uint256, // amount
        bytes calldata payload
    ) external onlyLayerZero {
        OmnichainData memory operator = centralRegistry.omnichainOperators(
            address(uint160(uint256(from))),
            centralRegistry.messagingToGETHChainId(srcChainId)
        );

        // Validate the operator is authorized
        if (operator.isAuthorized < 2) {
            return;
        }

        // If the operator is correct but the source chain Id
        // is invalid, ignore the message
        // Validate the source chainId is correct for the operator
        if (operator.messagingChainId != srcChainId) {
            return;
        }

        // Validate message came directly from CVE on the source chain
        if (bytes32(operator.cveAddress) != bytes32(srcAddress)) {
            return;
        }

        (
            address[] memory gaugePools,
            uint256[] memory emissionTotals,
            address[][] memory tokens,
            uint256[][] memory emissions,
            uint256 chainLockedAmount,
            uint256 messageType
        ) = abi.decode(
                payload,
                (
                    address[],
                    uint256[],
                    address[][],
                    uint256[][],
                    uint256,
                    uint256
                )
            );

        // Message Type 1: receive feeAccumulator information of locked tokens
        //                 on a chain for the epoch
        if (messageType == 1) {
            IFeeAccumulator(centralRegistry.feeAccumulator())
                .receiveCrossChainLockData(
                    EpochRolloverData({
                        chainId: operator.chainId,
                        value: chainLockedAmount,
                        numChainData: 0,
                        epoch: 0
                    })
                );
            return;
        }

        // Message Type 2: receive finalized epoch rewards data
        if (messageType == 2) {
            IFeeAccumulator(centralRegistry.feeAccumulator())
                .receiveExecutableLockData(chainLockedAmount);
        }

        // Message Type 3+: update gauge emissions for all gauge controllers on
        //                  this chain
        {
            // Use scoping for stack too deep logic
            uint256 lockBoostMultiplier = centralRegistry.lockBoostValue();
            uint256 numPools = gaugePools.length;
            GaugeController gaugePool;

            for (uint256 i; i < numPools; ) {
                gaugePool = GaugeController(gaugePools[i]);
                // Mint epoch gauge emissions to the gauge pool
                CVE.mintGaugeEmissions(
                    (lockBoostMultiplier * emissionTotals[i]) / DENOMINATOR,
                    address(gaugePool)
                );
                // Set upcoming epoch emissions for the voted configuration
                gaugePool.setEmissionRates(
                    gaugePool.currentEpoch() + 1,
                    tokens[i],
                    emissions[i]
                );

                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @notice Quotes gas cost for executing crosschain stargate swap
    /// @dev Intentionally greatly overestimates so we are sure that
    ///      a multicall will not fail
    function overEstimateStargateFee(
        SwapRouter stargateRouter,
        uint8 functionType,
        bytes calldata toAddress
    ) external view returns (uint256) {
        uint256 fee;

        if (block.chainid == 1) {
            (fee, ) = stargateRouter.quoteLayerZeroFee(
                110, // Arbitrum Destination
                functionType,
                toAddress,
                "",
                LzTxObj({
                    dstGasForCall: 0,
                    dstNativeAmount: 0,
                    dstNativeAddr: ""
                })
            );

            // Overestimate fees 5x to make sure it does not fail
            return fee * 5;
        }

        (fee, ) = stargateRouter.quoteLayerZeroFee(
            101, // Ethereum Destination
            functionType,
            toAddress,
            "",
            LzTxObj({
                dstGasForCall: 0,
                dstNativeAmount: 0,
                dstNativeAddr: ""
            })
        );

        // Overestimate fees by estimating moving to mainnet every time
        return fee;
    }

    /// @notice Quotes gas cost for executing crosschain stargate swap
    function quoteStargateFee(
        SwapRouter stargateRouter,
        uint16 _dstChainId,
        uint8 _functionType,
        bytes calldata _toAddress,
        bytes calldata _transferAndCallPayload,
        LzTxObj memory _lzTxParams
    ) external view returns (uint256, uint256) {
        return
            stargateRouter.quoteLayerZeroFee(
                _dstChainId,
                _functionType,
                _toAddress,
                _transferAndCallPayload,
                _lzTxParams
            );
    }

    /// @notice Permissioned function for returning fees reimbursed from
    ///         Stargate to FeeAccumulator
    /// @dev This is for if we ever need to depreciate this
    ///      ProtocolMessagingHub for another
    function returnReimbursedFees() external onlyDaoPermissions {
        SafeTransferLib.safeTransfer(
            feeToken,
            centralRegistry.feeAccumulator(),
            IERC20(feeToken).balanceOf(address(this))
        );
        centralRegistry.feeAccumulator().call{ value: address(this).balance }(
            ""
        );
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Sends veCVE locked token data to destination chain
    /// @param dstChainId The destination chain ID where the message data
    ///                   should be sent
    /// @param toAddress The destination addresses specified by `dstChainId`
    /// @param payload The payload data that is sent along with the message
    /// @param dstGasForCall The amount of gas that should be provided for
    ///                      the call on the destination chain
    /// @param callParams AdditionalParameters for the call, as LzCallParams
    /// @param etherValue How much ether to attach to the transaction
    /// @dev We redundantly pass adapterParams & callParams so we do not
    ///      need to coerce data in the function, calls with this function will
    ///      have messageType = 1 or messageType = 2
    function sendLockedTokenData(
        uint16 dstChainId,
        bytes32 toAddress,
        bytes calldata payload,
        uint64 dstGasForCall,
        LzCallParams calldata callParams,
        uint256 etherValue
    ) public payable onlyAuthorized {
        // Validate that we are aiming for a supported chain
        if (
            centralRegistry
                .supportedChainData(
                    centralRegistry.messagingToGETHChainId(dstChainId)
                )
                .isSupported < 2
        ) {
            revert ProtocolMessagingHub__ConfigurationError();
        }

        //
        CVE.sendAndCall{ value: etherValue }(
            address(this),
            dstChainId,
            toAddress,
            0,
            payload,
            dstGasForCall,
            callParams
        );
    }
}
