// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseLendtroller } from "../TestBaseLendtroller.sol";
import { Lendtroller } from "contracts/market/lendtroller/Lendtroller.sol";
import { IMToken, AccountSnapshot } from "contracts/interfaces/market/IMToken.sol";
import "hardhat/console.sol";

contract CanBorrowTest is TestBaseLendtroller {
    event MarketEntered(address mToken, address account);

    function setUp() public override {
        super.setUp();

        lendtroller.listToken(address(dUSDC));
    }

    function test_canBorrow_fail_whenBorrowPaused() public {
        lendtroller.setBorrowPaused(IMToken(address(dUSDC)), true);

        vm.prank(address(dUSDC));

        vm.expectRevert(Lendtroller.Lendtroller__Paused.selector);
        lendtroller.canBorrow(address(dUSDC), user1, 100e6);
    }

    function test_canBorrow_fail_whenMTokenIsNotListed() public {
        vm.prank(address(dUSDC));

        vm.expectRevert(Lendtroller.Lendtroller__TokenNotListed.selector);
        lendtroller.canBorrow(address(dDAI), user1, 100e6);
    }

    function test_canBorrow_fail_whenCallerIsNotMTokenAndBorrowerNotInMarket()
        public
    {
        lendtroller.listToken(address(dDAI));

        vm.prank(address(dUSDC));

        vm.expectRevert(Lendtroller.Lendtroller__AddressUnauthorized.selector);
        lendtroller.canBorrow(address(dDAI), user1, 100e6);
    }

    function test_canBorrow_fail_whenInsufficientLiquidity() public {
        skip(gaugePool.startTime() - block.timestamp);
        chainlinkUsdcUsd.updateRoundData(0, 1e8, block.timestamp, block.timestamp);
        chainlinkUsdcEth.updateRoundData(0, 1e18, block.timestamp, block.timestamp);

        address[] memory tokens = new address[](1);
        tokens[0] = address(dUSDC);

        vm.prank(user1);
        lendtroller.enterMarkets(tokens);

        vm.expectRevert(Lendtroller.Lendtroller__InsufficientLiquidity.selector);
        lendtroller.canBorrow(address(dUSDC), user1, 100e6);
    }

    function test_canBorrow_success_whenSufficientLiquidity() public {
        skip(gaugePool.startTime() - block.timestamp);
        chainlinkEthUsd.updateRoundData(0, 1500e8, block.timestamp, block.timestamp);
        chainlinkUsdcUsd.updateRoundData(0, 1e8, block.timestamp, block.timestamp);
        chainlinkUsdcEth.updateRoundData(0, 1500e18, block.timestamp, block.timestamp);

        lendtroller.listMarketToken(address(cBALRETH));
        lendtroller.updateCollateralToken(IMToken(address(cBALRETH)), 2000, 100, 3000, 3000, 7000);
        address[] memory tokens = new address[](2);
        tokens[0] = address(dUSDC);
        tokens[1] = address(cBALRETH);

        // Need some CTokens/collateral to have enough liquidity for borrowing
        deal(address(balRETH), user1, 10_000e18);
        vm.startPrank(user1);
        lendtroller.enterMarkets(tokens);
        balRETH.approve(address(cBALRETH), 1_000e18);
        cBALRETH.mint(1_000e18);
        vm.stopPrank();

        vm.prank(address(dUSDC));
        lendtroller.canBorrow(address(dUSDC), user1, 100e6);

        AccountSnapshot memory snapshot = cBALRETH.getSnapshotPacked(user1);
        (uint256 price,) = priceRouter.getPrice(cBALRETH.underlying(), true, true);
        (,,uint256 collRatio) = lendtroller.getMTokenData(address(cBALRETH));
        uint256 assetValue = price * (snapshot.balance * snapshot.exchangeRate / 1e18) / 10 ** cBALRETH.decimals();
        uint256 maxBorrow = assetValue * collRatio / 1e18;

        // max amount of USDC that can be borrowed based on provided collateral in cBALRETH
        uint256 borrowInUSDC = maxBorrow / 10 ** cBALRETH.decimals() * 10 ** dUSDC.decimals();
        vm.prank(address(dUSDC));
        lendtroller.canBorrow(address(dUSDC), user1, borrowInUSDC);

        // should fail when borrowing more than is allowed by provided collateral
        vm.expectRevert(Lendtroller.Lendtroller__InsufficientLiquidity.selector);
        vm.prank(address(dUSDC));
        lendtroller.canBorrow(address(dUSDC), user1, borrowInUSDC + 1e6);
    }

    function test_canBorrow_fail_entersUserInMarket() external {
        skip(gaugePool.startTime() - block.timestamp);
        chainlinkUsdcUsd.updateRoundData(0, 1e8, block.timestamp, block.timestamp);
        chainlinkUsdcEth.updateRoundData(0, 1e18, block.timestamp, block.timestamp);

        address[] memory tokens = new address[](1);
        tokens[0] = address(dUSDC);

        vm.expectRevert(Lendtroller.Lendtroller__AddressUnauthorized.selector);
        lendtroller.canBorrow(address(dUSDC), user1, 0);
    }

    function test_canBorrow_entersUserInMarket() external {
        skip(gaugePool.startTime() - block.timestamp);
        chainlinkUsdcUsd.updateRoundData(0, 1e8, block.timestamp, block.timestamp);
        chainlinkUsdcEth.updateRoundData(0, 1e18, block.timestamp, block.timestamp);

        assertFalse(lendtroller.getAccountMembership(address(dUSDC), user1));
        IMToken[] memory accountAssets = lendtroller.getAccountAssets(user1);
        assertEq(accountAssets.length, 0);

        vm.prank(address(dUSDC));
        lendtroller.canBorrow(address(dUSDC), user1, 0);

        assertTrue(lendtroller.getAccountMembership(address(dUSDC), user1));

        accountAssets = lendtroller.getAccountAssets(user1);
        assertEq(accountAssets.length, 1);
        assertEq(address(accountAssets[0]), address(dUSDC));
    }

    function test_canBorrow_fail_whenExceedsBorrowCap() external {
        skip(gaugePool.startTime() - block.timestamp);
        chainlinkUsdcUsd.updateRoundData(0, 1e8, block.timestamp, block.timestamp);
        chainlinkUsdcEth.updateRoundData(0, 1e18, block.timestamp, block.timestamp);

        IMToken[] memory mTokens = new IMToken[](1);
        uint256[] memory borrowCaps = new uint256[](1);
        mTokens[0] = IMToken(address(cBALRETH));
        borrowCaps[0] = 100e6 - 1;

        lendtroller.listMarketToken(address(cBALRETH));
        lendtroller.setCTokenCollateralCaps(mTokens, borrowCaps);

        vm.expectRevert(Lendtroller.Lendtroller__BorrowCapReached.selector);
        vm.prank(address(cBALRETH));
        lendtroller.canBorrow(address(cBALRETH), user1, 100e6);
    }

    function test_canBorrow_success_whenExceedsBorrowCap() external {
        skip(gaugePool.startTime() - block.timestamp);
        chainlinkUsdcUsd.updateRoundData(0, 1e8, block.timestamp, block.timestamp);
        chainlinkUsdcEth.updateRoundData(0, 1e18, block.timestamp, block.timestamp);

        IMToken[] memory mTokens = new IMToken[](1);
        uint256[] memory borrowCaps = new uint256[](1);
        mTokens[0] = IMToken(address(cBALRETH));
        borrowCaps[0] = 100e6;

        lendtroller.listMarketToken(address(cBALRETH));
        lendtroller.setCTokenCollateralCaps(mTokens, borrowCaps);

        vm.prank(address(cBALRETH));
        lendtroller.canBorrow(address(cBALRETH), user1, borrowCaps[0] - 1);
    }
}
