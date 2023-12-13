// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { GMCToken, IERC20 } from "contracts/market/collateral/GMCToken.sol";
import { MockArbSys } from "contracts/mocks/MockArbSys.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract TestGMCToken is TestBaseMarket {
    address private _ARB_SYS = 0x0000000000000000000000000000000000000064;
    address private _GMX_ORDER_KEEPER =
        0xf1e1B2F4796d984CCb8485d43db0c64B83C1FA6d;
    address private _GMX_DEPOSIT_HANDLER =
        0x9Dc4f12Eb2d8405b499FB5B8AF79a5f64aB8a457;
    address private _GMX_GM_WETH_USDC_POOL =
        0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;

    // GM pool token holder.
    address private _DEPOSITOR = 0x7575d9eb64CCe0DF0D570Ae88049382Ce6fB0D31;

    GMCToken public cGM;
    IERC20 public gmxGM;

    receive() external payable {}

    fallback() external payable {}

    // this is to use address(this) as mock GMCToken address
    function tokenType() external pure returns (uint256) {
        return 1;
    }

    function setUp() public override {
        _fork("ETH_NODE_URI_ARBITRUM", 150366795);
        vm.warp(block.timestamp - 2 weeks);

        _deployCentralRegistry();
        _deployCVE();
        _deployCVELocker();
        _deployVeCVE();
        _deployGaugePool();
        _deployLendtroller();

        centralRegistry.addHarvester(address(this));
        centralRegistry.setFeeAccumulator(address(this));

        gmxGM = IERC20(_GMX_GM_WETH_USDC_POOL);

        // Deploy position vault to the existing depositor address.
        deployCodeTo(
            "GMCToken.sol",
            abi.encode(
                ICentralRegistry(address(centralRegistry)),
                gmxGM,
                address(lendtroller)
            ),
            _DEPOSITOR
        );

        cGM = GMCToken(payable(_DEPOSITOR));

        // Update code on existing ArbSys contract with mock contract.
        vm.etch(_ARB_SYS, address(new MockArbSys()).code);

        gaugePool.start(address(lendtroller));
        skip(2 weeks);
    }

    function testGmxGMWethUsdcPool() public {
        uint256 assets = 100e18;
        deal(_GMX_GM_WETH_USDC_POOL, user1, assets);
        deal(_GMX_GM_WETH_USDC_POOL, address(this), 42069);

        gmxGM.approve(address(cGM), 42069);
        lendtroller.listToken(address(cGM));

        vm.prank(user1);
        gmxGM.approve(address(cGM), assets);

        vm.prank(user1);
        cGM.deposit(assets, user1);

        assertEq(
            cGM.totalAssets(),
            assets + 42069,
            "Total Assets should equal user deposit plus initial mint."
        );

        // Simulate deposit execution called by GMX keeper.
        vm.roll(150368146);

        bytes memory data;
        cGM.harvest(data);

        vm.roll(150368158);

        vm.prank(_GMX_ORDER_KEEPER);
        address(_GMX_DEPOSIT_HANDLER).call(
            hex"ced966259f5d56970d281e33718372913f69cfbda1d3d23d7c63ce1b6e3aebb1d8ac99410000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000002400000000000000000000000000000000000000000000000000000000000000260000000000000000000000000000000000000000000000000000000000000028000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000000000000000000000000000000000000000002c000000000000000000000000000000000000000000000000000000000000002e000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000320000000000000000000000000000000000000000000000000000000000000038000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e58310000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000003c00000000000000000000000000000000000000000000000000000000000000360000637558ae605b87120ff75c52308703f79ebafba207a65d69705ec7ba8beb7000000000000000000000000000000000000000000000000000000000ac78c01000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000002c00001000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012074aca63821bf7ead199e924d261d277cbec96d1026ab65267d655c51b453691400000000000000000000000000000000000000000000000000000000655393710000000000000000000000000000000000000000000000000000002f3568cc000000000000000000000000000000000000000000000000000000002f331665e00000000000000000000000000000000000000000000000000000002f3674fee00000000000000000000000000000000000000000000000000000000008f66f94950cea2980f9a92d1e2c59526071f2d793b9f40d84ca1974948d35a0649c0a150000000000000000000000000000000000000000000000000000000008f66f92000000000000000000000000000000000000000000000000000000006553937100000000000000000000000000000000000000000000000000000000000000045367af437b7d8e9511ded389368022624611fcdff58ba243a9e3b7116d3a043d0efdef23d95beec36d0ba2e8e320c6dc8dc23ddb3151c1c66b1e73a9983289a2666a55538e282190e1c0b7de997f83262846ebdddd1490ead82004d44d8630fb548724543aedf2000c157f8e7c4bb1b3c8ee73ca09277b5f6ae8e2fdeafdf9010000000000000000000000000000000000000000000000000000000000000004684e4da85ec4c32cf621b7559975ef34f0935ded9b9403a690a62324a09a655d605476a839b3a69b83300c5ecca8da7e02ecff0b3c05574454e50f70044c370a21123038c8aa6f7b1c9e7715771c24932e7f57f7a694335487afebe0f8d919794d0e4937d9cb6754a0c846d22039a626cdbb8fb87560c85202102654d0254c920000000000000000000000000000000000000000000000000000000000000360000636e8260d36292bcbc2d205dc922cde2a93a929350b7163c803ac4fd89560000000000000000000000000000000000000000000000000000000000ac7100d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000002c00100010100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012095241f154d34539741b19ce4bae815473fd1b2a90ac3b4b023a692f31edfe90e00000000000000000000000000000000000000000000000000000000655393710000000000000000000000000000000000000000000000000000000005f5edd90000000000000000000000000000000000000000000000000000000005f5d5a20000000000000000000000000000000000000000000000000000000005f5fe090000000000000000000000000000000000000000000000000000000008f66f931829312c7ab7afd4792be2df4561fc9b293341021905134670a05c2152c0b0810000000000000000000000000000000000000000000000000000000008f66f920000000000000000000000000000000000000000000000000000000065539371000000000000000000000000000000000000000000000000000000000000000436f2d29b798490e6d4a4124c95dea80a7c291644a4456a7f3e5d57583d8e6be7c5af96c5fba93e692a81f46cad824ef74e8ac45d7083f6ef1cc42e2dab4bce27c8d2e9686afedb7fb356b460646d15d4a9e9175f91cf4aeabc60b8e9ca53741a2987e1ba34d4c73aaf65cc636f1c2993defdb56a046b821f76968d3aa5cd97ac00000000000000000000000000000000000000000000000000000000000000043fa5d0a5774b5f135a7faba819ab320d0a0badaf4586a0f62ead15dccb6cb5267ff294e960c9b940a84cfdc7d16dd44f81e9000f04bb1a72e10b815c4bef3fa4398520f9f0104fdf90d2bfb1dedf22f652bb6a9a2e262eab52ac277516e91c3b4d8ffa1dd2b55893684d12f5be474740d1b50ee31ae493071a1533f6bfbbcec7"
        );

        skip(8 days);

        assertGt(
            cGM.totalAssets(),
            assets + 42069,
            "Total Assets should greater than user deposit plus initial mint."
        );

        vm.prank(user1);
        cGM.withdraw(assets, user1, user1);
    }
}
