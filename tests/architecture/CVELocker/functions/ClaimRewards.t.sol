// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseCVELocker } from "../TestBaseCVELocker.sol";
import { CVELocker } from "contracts/architecture/CVELocker.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { RewardsData } from "contracts/interfaces/ICVELocker.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";

contract ClaimRewardsTest is TestBaseCVELocker {
    address internal constant _UNISWAP_V2_ROUTER =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    RewardsData public rewardsData =
        RewardsData(_WETH_ADDRESS, false, false, false);
    SwapperLib.Swap public swapData;
    address[] public path;

    function setUp() public override {
        super.setUp();

        path.push(_USDC_ADDRESS);
        path.push(_WETH_ADDRESS);

        swapData.inputToken = _USDC_ADDRESS;
        swapData.inputAmount = 1e18;
        swapData.outputToken = _WETH_ADDRESS;
        swapData.target = _UNISWAP_V2_ROUTER;
        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            1e18,
            0,
            path,
            address(cveLocker),
            block.timestamp
        );

        centralRegistry.addSwapper(_UNISWAP_V2_ROUTER);

        deal(_USDC_ADDRESS, address(cveLocker), 1e18);
    }

    function test_claimRewards_fail_whenRewardTokenIsNotAuthorized() public {
        vm.startPrank(user1);

        deal(address(cve), user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(1e18, false, rewardsData, "0x", 0);

        vm.stopPrank();

        vm.prank(address(cveLocker.veCVE()));
        cveLocker.updateUserClaimIndex(user1, 1);

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(centralRegistry.feeAccumulator());
            cveLocker.recordEpochRewards(_ONE);
        }

        vm.expectRevert(
            CVELocker.CVELocker__RewardTokenIsNotAuthorized.selector
        );

        vm.prank(user1);
        cveLocker.claimRewards(rewardsData, abi.encode(swapData), 0);
    }

    function test_claimRewards_fail_whenNoEpochRewardsToClaim() public {
        cveLocker.addAuthorizedRewardToken(_WETH_ADDRESS);

        vm.prank(address(cveLocker.veCVE()));
        cveLocker.updateUserClaimIndex(user1, 1);

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(centralRegistry.feeAccumulator());
            cveLocker.recordEpochRewards(_ONE);
        }

        vm.expectRevert(CVELocker.CVELocker__NoEpochRewards.selector);

        vm.prank(user1);
        cveLocker.claimRewards(rewardsData, abi.encode(swapData), 0);
    }

    function test_claimRewards_success_fuzzed(uint256 amount) public {
        vm.assume(amount > 1e18 && amount <= 100e18);

        cveLocker.addAuthorizedRewardToken(_WETH_ADDRESS);

        vm.startPrank(user1);

        deal(address(cve), user1, 100e18);
        cve.approve(address(veCVE), 100e18);

        veCVE.createLock(amount, false, rewardsData, "0x", 0);

        vm.stopPrank();

        vm.prank(address(cveLocker.veCVE()));
        cveLocker.updateUserClaimIndex(user1, 1);

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(centralRegistry.feeAccumulator());
            cveLocker.recordEpochRewards(_ONE);
        }

        deal(_USDC_ADDRESS, address(cveLocker), amount);

        swapData.inputAmount = amount;
        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amount,
            0,
            path,
            address(cveLocker),
            block.timestamp
        );

        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(amount, path);
        uint256 baseRewardBalance = usdc.balanceOf(address(cveLocker));
        uint256 desiredTokenBalance = IERC20(_WETH_ADDRESS).balanceOf(user1);

        vm.prank(user1);
        cveLocker.claimRewards(rewardsData, abi.encode(swapData), 0);

        assertEq(
            usdc.balanceOf(address(cveLocker)),
            baseRewardBalance - amountsOut[0]
        );
        assertEq(
            IERC20(_WETH_ADDRESS).balanceOf(user1),
            desiredTokenBalance + amountsOut[1]
        );
    }
}
