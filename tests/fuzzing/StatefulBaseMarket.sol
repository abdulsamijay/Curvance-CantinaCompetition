// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { PropertiesAsserts } from "tests/fuzzing/PropertiesHelper.sol";
import { ErrorConstants } from "tests/fuzzing/ErrorConstants.sol";

import { MockToken } from "contracts/mocks/MockToken.sol";
import { MockCToken } from "contracts/mocks/MockCToken.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { MockCircleRelayer, MockWormhole } from "contracts/mocks/MockCircleRelayer.sol";
import { MockTokenBridgeRelayer } from "contracts/mocks/MockTokenBridgeRelayer.sol";

import { CVE } from "contracts/token/CVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { CVELocker } from "contracts/architecture/CVELocker.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { FeeAccumulator } from "contracts/architecture/FeeAccumulator.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
import { DToken } from "contracts/market/collateral/DToken.sol";
import { AuraCToken } from "contracts/market/collateral/AuraCToken.sol";
import { DynamicInterestRateModel } from "contracts/market/interestRates/DynamicInterestRateModel.sol";
import { Lendtroller } from "contracts/market/lendtroller/Lendtroller.sol";
import { Zapper } from "contracts/market/zapper/Zapper.sol";
import { PositionFolding } from "contracts/market/leverage/PositionFolding.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { IVault } from "contracts/oracles/adaptors/balancer/BalancerBaseAdaptor.sol";
import { BalancerStablePoolAdaptor } from "contracts/oracles/adaptors/balancer/BalancerStablePoolAdaptor.sol";
import { PriceRouter } from "contracts/oracles/PriceRouter.sol";
import { GaugePool } from "contracts/gauge/GaugePool.sol";
import { PartnerGaugePool } from "contracts/gauge/PartnerGaugePool.sol";
import { ERC20 } from "contracts/libraries/ERC20.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ERC165Checker } from "contracts/libraries/ERC165Checker.sol";

contract StatefulBaseMarket is PropertiesAsserts, ErrorConstants {
    address internal _WETH_ADDRESS;
    address internal _USDC_ADDRESS;
    address internal _RETH_ADDRESS;
    address internal _BALANCER_WETH_RETH;
    address internal _DAI_ADDRESS;
    address internal _CIRCLE_RELAYER;
    address internal _WORMHOLE_RELAYER;

    CVE public cve;
    VeCVE public veCVE;
    CVELocker public cveLocker;
    CentralRegistry public centralRegistry;
    FeeAccumulator public feeAccumulator;
    ProtocolMessagingHub public protocolMessagingHub;
    ChainlinkAdaptor public chainlinkAdaptor;
    ChainlinkAdaptor public dualChainlinkAdaptor;
    DynamicInterestRateModel public InterestRateModel;
    Lendtroller public lendtroller;
    PositionFolding public positionFolding;
    PriceRouter public priceRouter;
    MockCToken public cUSDC;
    MockCToken public cDAI;
    DToken public dUSDC;
    DToken public dDAI;
    AuraCToken public cBALRETH;
    MockToken public usdc;
    MockToken public dai;
    MockToken public WETH;
    MockToken public balRETH;
    MockTokenBridgeRelayer public bridgeRelayer;

    MockV3Aggregator public chainlinkUsdcUsd;
    MockV3Aggregator public chainlinkUsdcEth;
    MockV3Aggregator public chainlinkRethEth;
    MockV3Aggregator public chainlinkEthUsd;
    MockV3Aggregator public chainlinkDaiUsd;
    MockV3Aggregator public chainlinkDaiEth;

    MockToken public rewardToken;
    GaugePool public gaugePool;
    PartnerGaugePool public partnerGaugePool;

    address public harvester;
    uint256 public clPointMultiplier = 11000; // 110%
    uint256 public voteBoostMultiplier = 11000; // 110%
    uint256 public lockBoostMultiplier = 10000; // 110%
    uint256 public marketInterestFactor = 1000; // 10%

    Zapper public zapper;
    mapping(address => uint256) postedCollateralAt;

    constructor() {
        // _fork(18031848);
        WETH = new MockToken("WETH", "WETH", 18);
        _WETH_ADDRESS = address(WETH);
        usdc = new MockToken("USDC", "USDC", 6);
        _USDC_ADDRESS = address(usdc);
        dai = new MockToken("DAI", "DAI", 18);
        _DAI_ADDRESS = address(dai);
        balRETH = new MockToken("balWethReth", "balWethReth", 18);
        _BALANCER_WETH_RETH = address(balRETH);

        _CIRCLE_RELAYER = address(new MockCircleRelayer(10));
        _WORMHOLE_RELAYER = address(0x1);

        emit LogString("DEPLOYED: centralRegistry");
        _deployCentralRegistry();
        emit LogString("DEPLOYED: CVE");
        _deployCVE();
        emit LogString("DEPLOYED: CVELocker");
        _deployCVELocker();
        emit LogString("DEPLOYED: ProtocolMessagingHub");
        _deployProtocolMessagingHub();
        emit LogString("DEPLOYED: FeeAccumulator");
        _deployFeeAccumulator();

        emit LogString("DEPLOYED: VECVE");
        _deployVeCVE();
        emit LogString("DEPLOYED: Mock Chainlink V3 Aggregator");
        chainlinkEthUsd = new MockV3Aggregator(8, 1500e8, 1e50, 1e6);
        emit LogString("DEPLOYED: PriceRouter");
        _deployPriceRouter();
        _deployChainlinkAdaptors();
        emit LogString("DEPLOYED: GaugePool");
        _deployGaugePool();
        emit LogString("DEPLOYED: Lendtroller");
        _deployLendtroller();
        emit LogString("DEPLOYED: DynamicInterestRateModel");
        _deployDynamicInterestRateModel();
        emit LogString("DEPLOYED: DUSDC");
        _deployDUSDC();
        emit LogString("DEPLOYED: DDAI");
        _deployDDAI();
        emit LogString("DEPLOYED: CUSDC");
        _deployCUSDC();
        emit LogString("DEPLOYED: DAI");
        _deployCDAI();
        // emit LogString("DEPLOYED: ZAPPER");
        // _deployZapper();
        emit LogString("DEPLOYED: PositionFolding");
        _deployPositionFolding();
        emit LogString("DEPLOYED: Adding dUSDC to router");
        // priceRouter.addMTokenSupport(address(cUSDC));
        // priceRouter.addMTokenSupport(address(cDAI));
        // emit LogString("DEPLOYED: Adding cBalReth to router");
    }

    function _deployCentralRegistry() internal {
        centralRegistry = new CentralRegistry(
            address(this),
            address(this),
            address(this),
            0,
            address(0)
        );
        centralRegistry.transferEmergencyCouncil(address(this));
        centralRegistry.setLockBoostMultiplier(lockBoostMultiplier);
    }

    function _deployCVE() internal {
        bridgeRelayer = new MockTokenBridgeRelayer();
        cve = new CVE(
            ICentralRegistry(address(centralRegistry)),
            address(bridgeRelayer),
            address(this),
            10000 ether,
            10000 ether,
            10000 ether,
            10000 ether
        );
        centralRegistry.setCVE(address(cve));
    }

    function _deployCVELocker() internal {
        cveLocker = new CVELocker(
            ICentralRegistry(address(centralRegistry)),
            _USDC_ADDRESS
        );
        centralRegistry.setCVELocker(address(cveLocker));
    }

    function _deployVeCVE() internal {
        veCVE = new VeCVE(ICentralRegistry(address(centralRegistry)));
        centralRegistry.setVeCVE(address(veCVE));
        centralRegistry.setVoteBoostMultiplier(voteBoostMultiplier);
        cveLocker.startLocker();
    }

    function _deployPriceRouter() internal {
        priceRouter = new PriceRouter(
            ICentralRegistry(address(centralRegistry)),
            address(chainlinkEthUsd)
        );

        centralRegistry.setPriceRouter(address(priceRouter));
    }

    function _deployProtocolMessagingHub() internal {
        protocolMessagingHub = new ProtocolMessagingHub(
            ICentralRegistry(address(centralRegistry)),
            _USDC_ADDRESS,
            _WORMHOLE_RELAYER,
            _CIRCLE_RELAYER
        );
        centralRegistry.setProtocolMessagingHub(address(protocolMessagingHub));
    }

    function _deployFeeAccumulator() internal {
        // harvester = makeAddr("harvester");
        harvester = address(this);
        centralRegistry.addHarvester(harvester);

        feeAccumulator = new FeeAccumulator(
            ICentralRegistry(address(centralRegistry)),
            _USDC_ADDRESS,
            1e9,
            1e9
        );
        centralRegistry.setFeeAccumulator(address(feeAccumulator));
    }

    function _deployChainlinkAdaptors() internal {
        chainlinkUsdcUsd = new MockV3Aggregator(8, 1e8, 1e24, 1e6);
        chainlinkDaiUsd = new MockV3Aggregator(8, 1e8, 1e24, 1e6);
        chainlinkUsdcEth = new MockV3Aggregator(18, 1e18, 1e24, 1e13);
        chainlinkRethEth = new MockV3Aggregator(18, 1e18, 1e24, 1e13);
        chainlinkDaiEth = new MockV3Aggregator(18, 1e18, 1e24, 1e13);

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(chainlinkEthUsd),
            true
        );
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUsdcUsd),
            true
        );
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUsdcEth),
            false
        );
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDaiUsd),
            true
        );
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDaiEth),
            false
        );
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(chainlinkRethEth),
            false
        );

        priceRouter.addApprovedAdaptor(address(chainlinkAdaptor));
        priceRouter.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        priceRouter.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
        priceRouter.addAssetPriceFeed(_DAI_ADDRESS, address(chainlinkAdaptor));
        priceRouter.addAssetPriceFeed(
            _RETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        dualChainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(chainlinkEthUsd),
            true
        );

        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUsdcUsd),
            true
        );

        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUsdcEth),
            false
        );
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDaiUsd),
            true
        );
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDaiEth),
            false
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(chainlinkRethEth),
            false
        );
        priceRouter.addApprovedAdaptor(address(dualChainlinkAdaptor));
        priceRouter.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(dualChainlinkAdaptor)
        );
        priceRouter.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(dualChainlinkAdaptor)
        );
        priceRouter.addAssetPriceFeed(
            _DAI_ADDRESS,
            address(dualChainlinkAdaptor)
        );
        priceRouter.addAssetPriceFeed(
            _RETH_ADDRESS,
            address(dualChainlinkAdaptor)
        );
    }

    function _deployGaugePool() internal {
        gaugePool = new GaugePool(ICentralRegistry(address(centralRegistry)));
        centralRegistry.addGaugeController(address(gaugePool));

        // Additional logic for partner gauge pool fuzzing logic
        // partnerGaugePool = new PartnerGaugePool(
        //     address(gaugePool),
        //     address(usdc),
        //     ICentralRegistry(address(centralRegistry))
        // );
        // gaugePool.addPartnerGauge(address(partnerGaugePool));
    }

    function _deployLendtroller() internal {
        lendtroller = new Lendtroller(
            ICentralRegistry(address(centralRegistry)),
            address(gaugePool)
        );
        centralRegistry.addLendingMarket(
            address(lendtroller),
            marketInterestFactor
        );
        try gaugePool.start(address(lendtroller)) {} catch {
            assertWithMsg(false, "start gauge pool failed");
        }
    }

    function _deployDynamicInterestRateModel() internal {
        InterestRateModel = new DynamicInterestRateModel(
            ICentralRegistry(address(centralRegistry)),
            1000, // baseRatePerYear
            1000, // vertexRatePerYear
            5000, // vertexUtilizationStart
            12 hours, // adjustmentRate
            5000, // adjustmentVelocity
            100000000, // 1000x maximum vertex multiplier
            100 // decayRate
        );
    }

    function _deployDUSDC() internal returns (DToken) {
        dUSDC = _deployDToken(_USDC_ADDRESS);
        return dUSDC;
    }

    function _deployDDAI() internal returns (DToken) {
        dDAI = _deployDToken(_DAI_ADDRESS);
        return dDAI;
    }

    function _deployCUSDC() internal returns (MockCToken) {
        cUSDC = new MockCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(address(usdc)),
            address(lendtroller)
        );
        return cUSDC;
    }

    function _deployCDAI() internal returns (MockCToken) {
        cDAI = new MockCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(address(dai)),
            address(lendtroller)
        );
        return cDAI;
    }

    function _deployDToken(address token) internal returns (DToken) {
        return
            new DToken(
                ICentralRegistry(address(centralRegistry)),
                token,
                address(lendtroller),
                address(InterestRateModel)
            );
    }

    function _deployPositionFolding() internal returns (PositionFolding) {
        positionFolding = new PositionFolding(
            ICentralRegistry(address(centralRegistry)),
            address(lendtroller)
        );
        return positionFolding;
    }

    function _addSinglePriceFeed() internal {
        priceRouter.addApprovedAdaptor(address(chainlinkAdaptor));
        priceRouter.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function _addDualPriceFeed() internal {
        _addSinglePriceFeed();

        priceRouter.addApprovedAdaptor(address(dualChainlinkAdaptor));
        priceRouter.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(dualChainlinkAdaptor)
        );
    }

    function mint_and_approve(
        address underlyingAddress,
        address mtoken,
        uint256 amount
    ) internal returns (bool) {
        // mint ME enough tokens to cover deposit
        try MockToken(underlyingAddress).mint(amount) {} catch (
            bytes memory revertData
        ) {
            uint256 currentSupply = MockToken(underlyingAddress).totalSupply();
            uint256 errorSelector = extractErrorSelector(revertData);

            unchecked {
                if (doesOverflow(currentSupply + amount, currentSupply)) {
                    assertWithMsg(
                        errorSelector == token_total_supply_overflow,
                        "MToken underlying - mint underlying amount should succeed"
                    );
                    return false;
                } else {
                    assertWithMsg(
                        false,
                        "MToken underlying - mint underlying amount should succeed"
                    );
                }
            }
        }
        // approve sufficient underlying tokens prior to calling deposit
        try MockToken(underlyingAddress).approve(mtoken, amount) {} catch (
            bytes memory revertData
        ) {
            uint256 currentAllowance = MockToken(underlyingAddress).allowance(
                msg.sender,
                mtoken
            );

            uint256 errorSelector = extractErrorSelector(revertData);
            unchecked {
                if (
                    doesOverflow(currentAllowance + amount, currentAllowance)
                ) {
                    assertEq(
                        errorSelector,
                        token_allowance_overflow,
                        "MTOKEN underlying - revert expected when underflow"
                    );
                    return false;
                } else {
                    assertWithMsg(
                        false,
                        "MTOKEN underlying - approve underlying amount should succeed"
                    );
                }
            }
        }
        return true;
    }
}
