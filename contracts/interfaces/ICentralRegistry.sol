// SPDX-License-Identifier: MIT

pragma solidity >=0.8.12;

interface ICentralRegistry {
    // @notice Returns Protocol DAO Address
    function daoAddress() external view returns (address);
    // @notice Returns CVE Locker Address
    function cveLocker() external view returns (address);
    // @notice Returns CVE Address
    function CVE() external view returns (address);
    // @notice Returns veCVE Address
    function veCVE() external view returns (address);
    // @notice Returns Call Option Address
    function callOptionCVE() external view returns (address);
    // @notice Returns Voting Hub Address
    function votingHub() external view returns (address);
    // @notice Returns Price Router Address
    function priceRouter() external view returns (address);
    // @notice Returns Deposit Router Address
    function depositRouter() external view returns (address);
    // @notice Returns whether the inputted address is a Harvester
    function isHarvester(address _address) external view returns (bool);
    // @notice Returns whether the inputted address is a lending market
    function isLendingMarket(address _address) external view returns (bool);
}