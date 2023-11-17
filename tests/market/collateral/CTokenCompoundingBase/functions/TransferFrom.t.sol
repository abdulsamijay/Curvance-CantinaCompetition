// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

// import { TestBaseCTokenCompoundingBase } from "../TestBaseCTokenCompoundingBase.sol";
// import { GaugeErrors } from "contracts/gauge/GaugeErrors.sol";
// import { CTokenCompoundingBase } from "contracts/market/collateral/CTokenCompoundingBase.sol";
// import { Lendtroller } from "contracts/market/lendtroller/Lendtroller.sol";

// contract CTokenCompoundingBase_TransferFromTest is TestBaseCTokenCompoundingBase {
//     event Transfer(address indexed from, address indexed to, uint256 amount);

//     function test_CTokenCompoundingBase_TransferFrom_fail_whenSenderAndReceiverAreSame()
//         public
//     {
//         vm.expectRevert(CTokenCompoundingBase.CTokenCompoundingBase__TransferError.selector);
//         cBALRETH.transferFrom(address(this), address(this), 1e18);
//     }

//     function test_CTokenCompoundingBase_TransferFrom_fail_whenTransferZeroAmount() public {
//         vm.expectRevert(GaugeErrors.InvalidAmount.selector);
//         cBALRETH.transferFrom(address(this), user1, 0);
//     }

//     function test_CTokenCompoundingBase_TransferFrom_fail_whenAllowanceIsInvalid() public {
//         vm.expectRevert();
//         cBALRETH.transferFrom(user1, address(this), 100);
//     }

//     function test_transfer_fail_whenTransferIsNotAllowed() public {
//         lendtroller.setTransferPaused(true);

//         vm.expectRevert(Lendtroller.Lendtroller__Paused.selector);
//         cBALRETH.transferFrom(address(this), user1, 100);
//     }

//     function test_CTokenCompoundingBase_TransferFrom_success() public {
//         cBALRETH.mint(100);

//         uint256 balance = cBALRETH.balanceOf(address(this));
//         uint256 user1Balance = cBALRETH.balanceOf(user1);

//         vm.expectEmit(true, true, true, true, address(cBALRETH));
//         emit Transfer(address(this), user1, 100);

//         cBALRETH.transferFrom(address(this), user1, 100);

//         assertEq(cBALRETH.balanceOf(address(this)), balance - 100);
//         assertEq(cBALRETH.balanceOf(user1), user1Balance + 100);
//     }
// }
