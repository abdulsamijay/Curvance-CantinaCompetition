// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


import { GaugeController, GaugeErrors, IGaugePool } from "contracts/gauge/GaugeController.sol";
import { PartnerGaugePool } from "contracts/gauge/PartnerGaugePool.sol";
import { ERC165 } from "contracts/libraries/ERC165.sol";
import { ERC165Checker } from "contracts/libraries/ERC165Checker.sol";
import { SafeTransferLib } from "contracts/libraries/SafeTransferLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuard.sol";

import { RewardsData } from "contracts/interfaces/ICVELocker.sol";
import { ILendtroller } from "contracts/interfaces/market/ILendtroller.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICVE } from "contracts/interfaces/ICVE.sol";
import { DENOMINATOR } from "contracts/libraries/Constants.sol";

contract GaugePool is GaugeController, ERC165, ReentrancyGuard {
    /// TYPES ///

    struct PoolInfo {
        uint256 lastRewardTimestamp;
        // Accumulated Rewards per share, times 1e12. See below.
        uint256 accRewardPerShare;
        uint256 totalAmount;
    }
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 rewardPending;
    }

    /// CONSTANTS ///

    /// @notice Scalar for math
    uint256 internal constant PRECISION = 1e36;
    address public lendtroller; // Lendtroller linked

    /// STORAGE ///

    // Current partner gauges attached to this gauge pool
    PartnerGaugePool[] public partnerGauges;
    mapping(address => PoolInfo) public poolInfo; // token => pool info
    mapping(address => mapping(address => UserInfo)) public userInfo; // token => user => info
    uint256 public firstDeposit;
    uint256 public unallocatedRewards;

    /// EVENTS ///

    event AddPartnerGauge(address partnerGauge);
    event RemovePartnerGauge(address partnerGauge);
    event Deposit(address user, address token, uint256 amount);
    event Withdraw(address user, address token, uint256 amount);
    event Claim(address user, address token, uint256 amount);

    constructor(
        ICentralRegistry centralRegistry_
    ) GaugeController(centralRegistry_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Initializes the gauge with a starting time based on the next epoch
    /// @dev    Can only be called once, to start the gauge system
    /// @param lendtroller_ The address to be configured as a lending market
    function start(address lendtroller_) external {
        _checkDaoPermissions();

        if (startTime != 0) {
            revert GaugeErrors.AlreadyStarted();
        }

        // Validate that the lendtroller we are setting is actually a lending market
        if (!centralRegistry.isLendingMarket(lendtroller_)) {
            revert GaugeErrors.InvalidAddress();
        }

        if (
            !ERC165Checker.supportsInterface(
                address(lendtroller_),
                type(ILendtroller).interfaceId
            )
        ) {
            revert GaugeErrors.InvalidAddress();
        }

        startTime = veCVE.nextEpochStartTime();
        lendtroller = lendtroller_;
    }

    /// @notice Adds a new partner gauge to the gauge system
    /// @param partnerGauge The address of the partner gauge to be added
    function addPartnerGauge(address partnerGauge) external {
        _checkDaoPermissions();
        
        if (partnerGauge == address(0)) {
            revert GaugeErrors.InvalidAddress();
        }

        if (PartnerGaugePool(partnerGauge).activationTime() != 0) {
            revert GaugeErrors.InvalidAddress();
        }

        partnerGauges.push(PartnerGaugePool(partnerGauge));
        PartnerGaugePool(partnerGauge).activate();

        emit AddPartnerGauge(partnerGauge);
    }

    /// @notice Removes a partner gauge from the gauge system
    /// @param index The index of the partner gauge
    /// @param partnerGauge The address of the partner gauge to be removed
    function removePartnerGauge(
        uint256 index,
        address partnerGauge
    ) external {
        _checkDaoPermissions();
        
        if (partnerGauge != address(partnerGauges[index])) {
            revert GaugeErrors.InvalidAddress();
        }

        // If the partner gauge is not the last one in the array,
        // copy its data down and then pop
        if (index != (partnerGauges.length - 1)) {
            partnerGauges[index] = partnerGauges[partnerGauges.length - 1];
        }
        partnerGauges.pop();

        emit RemovePartnerGauge(partnerGauge);
    }

    function balanceOf(
        address token,
        address user
    ) external view returns (uint256) {
        return userInfo[token][user].amount;
    }

    function totalSupply(address token) external view returns (uint256) {
        return poolInfo[token].totalAmount;
    }

    /// @notice Returns pending rewards of user
    /// @param token Pool token address
    /// @param user User address
    function pendingRewards(
        address token,
        address user
    ) external view returns (uint256) {
        PoolInfo storage _pool = poolInfo[token];
        uint256 accRewardPerShare = _pool.accRewardPerShare;
        uint256 lastRewardTimestamp = _pool.lastRewardTimestamp;
        uint256 totalDeposited = _pool.totalAmount;
        if (lastRewardTimestamp == 0) {
            lastRewardTimestamp = startTime;
        }

        if (block.timestamp > lastRewardTimestamp && totalDeposited != 0) {
            uint256 lastEpoch = epochOfTimestamp(lastRewardTimestamp);
            uint256 currentEpoch = currentEpoch();
            uint256 reward;
            while (lastEpoch < currentEpoch) {
                uint256 endTimestamp = epochEndTime(lastEpoch);

                // update rewards from lastRewardTimestamp to endTimestamp
                reward =
                    ((endTimestamp - lastRewardTimestamp) *
                        _epochInfo[lastEpoch].poolWeights[token]) /
                    EPOCH_WINDOW;
                accRewardPerShare =
                    accRewardPerShare +
                    (reward * (PRECISION)) /
                    totalDeposited;

                ++lastEpoch;
                lastRewardTimestamp = endTimestamp;
            }

            // update rewards from lastRewardTimestamp to current timestamp
            reward =
                ((block.timestamp - lastRewardTimestamp) *
                    _epochInfo[lastEpoch].poolWeights[token]) /
                EPOCH_WINDOW;
            accRewardPerShare =
                accRewardPerShare +
                (reward * (PRECISION)) /
                totalDeposited;
        }

        UserInfo memory info = userInfo[token][user];
        return
            info.rewardPending +
            (info.amount * accRewardPerShare) /
            (PRECISION) -
            info.rewardDebt;
    }

    /// @notice Deposit into gauge pool
    /// @param token Pool token address
    /// @param user User address
    /// @param amount Amounts to deposit
    function deposit(
        address token,
        address user,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) {
            revert GaugeErrors.InvalidAmount();
        }
        if (block.timestamp < startTime) {
            revert GaugeErrors.NotStarted();
        }

        if (
            msg.sender != token || !ILendtroller(lendtroller).isListed(token)
        ) {
            revert GaugeErrors.InvalidToken();
        }

        updatePool(token);

        _calcPending(user, token);

        userInfo[token][user].amount += amount;
        poolInfo[token].totalAmount += amount;

        if (firstDeposit == 0) {
            // if first deposit, the new rewards from gauge start to this point will be unallocated rewards
            firstDeposit = block.timestamp;
            updatePool(token);
            SafeTransferLib.safeTransfer(
                cve,
                centralRegistry.daoAddress(),
                (poolInfo[token].accRewardPerShare *
                    poolInfo[token].totalAmount) / PRECISION
            );
        }

        _calcDebt(user, token);

        uint256 numPartnerGauges = partnerGauges.length;

        for (uint256 i; i < numPartnerGauges; ) {
            if (address(partnerGauges[i]) != address(0)) {
                partnerGauges[i].deposit(token, user, amount);
            }

            unchecked {
                ++i;
            }
        }

        emit Deposit(user, token, amount);
    }

    /// @notice Withdraw from gauge pool
    /// @param token Pool token address
    /// @param user The user address
    /// @param amount Amounts to withdraw
    function withdraw(
        address token,
        address user,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) {
            revert GaugeErrors.InvalidAmount();
        }
        if (block.timestamp < startTime) {
            revert GaugeErrors.NotStarted();
        }

        if (
            msg.sender != token || !ILendtroller(lendtroller).isListed(token)
        ) {
            revert GaugeErrors.InvalidToken();
        }

        UserInfo storage info = userInfo[token][user];
        if (info.amount < amount) {
            revert GaugeErrors.InvalidAmount();
        }

        updatePool(token);
        _calcPending(user, token);

        info.amount -= amount;
        poolInfo[token].totalAmount -= amount;

        _calcDebt(user, token);

        uint256 numPartnerGauges = partnerGauges.length;

        for (uint256 i; i < numPartnerGauges; ) {
            if (address(partnerGauges[i]) != address(0)) {
                partnerGauges[i].withdraw(token, user, amount);
            }

            unchecked {
                ++i;
            }
        }

        emit Withdraw(user, token, amount);
    }

    /// @notice Claim rewards from gauge pool
    /// @param token Pool token address
    function claim(address token) external nonReentrant {
        if (block.timestamp < startTime) {
            revert GaugeErrors.NotStarted();
        }

        updatePool(token);
        _calcPending(msg.sender, token);

        uint256 rewards = userInfo[token][msg.sender].rewardPending;
        if (rewards == 0) {
            revert GaugeErrors.NoReward();
        }
        SafeTransferLib.safeTransfer(cve, msg.sender, rewards);

        userInfo[token][msg.sender].rewardPending = 0;

        _calcDebt(msg.sender, token);

        emit Claim(msg.sender, token, rewards);
    }

    /// @notice Claim rewards from gauge pool
    /// @param token Pool token address
    function claimAndExtendLock(
        address token,
        uint256 lockIndex,
        bool continuousLock,
        RewardsData memory rewardsData,
        bytes memory params,
        uint256 aux
    ) external nonReentrant {
        if (block.timestamp < startTime) {
            revert GaugeErrors.NotStarted();
        }

        updatePool(token);
        _calcPending(msg.sender, token);

        uint256 rewards = userInfo[token][msg.sender].rewardPending;
        if (rewards == 0) {
            revert GaugeErrors.NoReward();
        }

        userInfo[token][msg.sender].rewardPending = 0;

        uint256 currentLockBoost = centralRegistry.lockBoostMultiplier();
        // If theres a current lock boost, recognize their bonus rewards
        if (currentLockBoost > 0) {
            uint256 boostedRewards = (rewards * currentLockBoost) /
                DENOMINATOR;
            ICVE(cve).mintLockBoost(boostedRewards - rewards);
            rewards = boostedRewards;
        }

        SafeTransferLib.safeApprove(cve, address(veCVE), rewards);
        veCVE.increaseAmountAndExtendLockFor(
            msg.sender,
            rewards,
            lockIndex,
            continuousLock,
            rewardsData,
            params,
            aux
        );

        _calcDebt(msg.sender, token);

        emit Claim(msg.sender, token, rewards);
    }

    /// @notice Claim rewards from gauge pool
    /// @param token Pool token address
    function claimAndLock(
        address token,
        bool continuousLock,
        RewardsData memory rewardsData,
        bytes memory params,
        uint256 aux
    ) external nonReentrant {
        if (block.timestamp < startTime) {
            revert GaugeErrors.NotStarted();
        }

        updatePool(token);
        _calcPending(msg.sender, token);

        uint256 rewards = userInfo[token][msg.sender].rewardPending;
        if (rewards == 0) {
            revert GaugeErrors.NoReward();
        }

        userInfo[token][msg.sender].rewardPending = 0;

        uint256 currentLockBoost = centralRegistry.lockBoostMultiplier();
        // If theres a current lock boost, recognize their bonus rewards
        if (currentLockBoost > 0) {
            uint256 boostedRewards = (rewards * currentLockBoost) /
                DENOMINATOR;
            ICVE(cve).mintLockBoost(boostedRewards - rewards);
            rewards = boostedRewards;
        }

        SafeTransferLib.safeApprove(cve, address(veCVE), rewards);
        veCVE.createLockFor(
            msg.sender,
            rewards,
            continuousLock,
            rewardsData,
            params,
            aux
        );

        _calcDebt(msg.sender, token);

        emit Claim(msg.sender, token, rewards);
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Update reward variables of the given pool to be up-to-date
    /// @param token Pool token address
    function updatePool(address token) public override {
        if (block.timestamp < startTime) {
            revert GaugeErrors.NotStarted();
        }

        uint256 lastRewardTimestamp = poolInfo[token].lastRewardTimestamp;
        if (lastRewardTimestamp == 0) {
            lastRewardTimestamp = startTime;
        }

        if (
            block.timestamp <= lastRewardTimestamp ||
            block.timestamp == startTime
        ) {
            return;
        }

        uint256 totalDeposited = poolInfo[token].totalAmount;
        if (totalDeposited == 0) {
            return;
        }

        uint256 accRewardPerShare = poolInfo[token].accRewardPerShare;
        uint256 lastEpoch = epochOfTimestamp(lastRewardTimestamp);
        uint256 currentEpoch = currentEpoch();
        uint256 reward;

        while (lastEpoch < currentEpoch) {
            uint256 endTimestamp = epochEndTime(lastEpoch);

            // update rewards from lastRewardTimestamp to endTimestamp
            reward =
                ((endTimestamp - lastRewardTimestamp) *
                    _epochInfo[lastEpoch].poolWeights[token]) /
                EPOCH_WINDOW;
            accRewardPerShare =
                accRewardPerShare +
                (reward * (PRECISION)) /
                totalDeposited;

            ++lastEpoch;
            lastRewardTimestamp = endTimestamp;
        }

        // update rewards from lastRewardTimestamp to current timestamp
        reward =
            ((block.timestamp - lastRewardTimestamp) *
                _epochInfo[lastEpoch].poolWeights[token]) /
            EPOCH_WINDOW;
        accRewardPerShare =
            accRewardPerShare +
            (reward * (PRECISION)) /
            totalDeposited;

        // update pool storage
        poolInfo[token].lastRewardTimestamp = block.timestamp;
        poolInfo[token].accRewardPerShare = accRewardPerShare;
    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IGaugePool).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Calculate user's pending rewards
    function _calcPending(address user, address token) internal {
        UserInfo storage info = userInfo[token][user];
        info.rewardPending +=
            (info.amount * poolInfo[token].accRewardPerShare) /
            (PRECISION) -
            info.rewardDebt;
    }

    /// @notice Calculate user's debt amount for reward calculation
    function _calcDebt(address user, address token) internal {
        UserInfo storage info = userInfo[token][user];
        info.rewardDebt =
            (info.amount * poolInfo[token].accRewardPerShare) /
            (PRECISION);
    }
}
