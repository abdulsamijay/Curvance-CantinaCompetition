//SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ERC165Checker } from "contracts/libraries/ERC165Checker.sol";
import { SafeTransferLib } from "contracts/libraries/SafeTransferLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";
import { RewardsData } from "contracts/interfaces/ICveLocker.sol";
import { ICVXLocker } from "contracts/interfaces/ICvxLocker.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract cveLocker {
    event TokenRecovered(address token, address to, uint256 amount);
    event RewardPaid(
        address user,
        address recipient,
        address rewardToken,
        uint256 amount
    );

    // TO-DO:
    // Process fee per cve reporting by chain in fee routing/here (permissioned functions for feerouting)
    // Figure out when fees should be active either current epoch or epoch + 1
    // Add epoch rewards view for frontend?

    // Add slippage checks
    // Add Whitelisted swappers

    uint256 public immutable genesisEpoch;

    // Address for Curvance DAO registry contract for ownership and location data.
    ICentralRegistry public immutable centralRegistry;

    bool public isShutdown;

    // Token Addresses
    address public immutable cve;
    address public immutable cvx;
    IVeCVE public immutable veCVE;

    ICVXLocker public cvxLocker;

    address public constant baseRewardToken =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant EPOCH_DURATION = 2 weeks;
    uint256 public constant DENOMINATOR = 10000;
    uint256 public constant ethPerCVEOffset = 1 ether;
    uint256 public constant SLIPPAGE = 500; // 5%

    uint256 public nextEpochToDeliver;

    // User => Reward Next Claim Index
    mapping(address => uint256) public userNextClaimIndex;

    // Move Reward Tokens to Central Registry
    mapping(address => bool) public authorizedRewardToken;

    // Move this to Central Registry
    // What other chains are supported
    uint256[] public childChains;

    // Epoch # => ChainID => Tokens Locked in Epoch
    mapping(uint256 => mapping(uint256 => uint256)) public tokensLockedByChain;
    // Epoch # => Child Chains updated
    mapping(uint256 => uint256) public childChainsUpdatedByEpoch;

    // Epoch # => Total Tokens Locked across all chains
    mapping(uint256 => uint256) public totalTokensLockedByEpoch;

    // Epoch # => Ether rewards per CVE multiplier by offset
    mapping(uint256 => uint256) public ethPerCVE;

    constructor(ICentralRegistry centralRegistry_, address cvx_) {

        require(
            ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            ),
            "cveLocker: invalid central registry"
        );

        centralRegistry = centralRegistry_;
        genesisEpoch = centralRegistry.genesisEpoch();
        cvx = cvx_;
        cve = centralRegistry.CVE();
        veCVE = IVeCVE(centralRegistry.veCVE());
    }

    modifier onlyDaoPermissions() {
        require(
            centralRegistry.hasDaoPermissions(msg.sender),
            "cveLocker: UNAUTHORIZED"
        );
        _;
    }

    modifier onlyElevatedPermissions() {
        require(
            centralRegistry.hasElevatedPermissions(msg.sender),
            "cveLocker: UNAUTHORIZED"
        );
        _;
    }

    modifier onlyVeCVE() {
        require(msg.sender == address(veCVE), "cveLocker: UNAUTHORIZED");
        _;
    }

    modifier onlyMessagingHub() {
        require(
            msg.sender == centralRegistry.protocolMessagingHub(),
            "cveLocker: UNAUTHORIZED"
        );
        _;
    }

    /// @notice Returns the current epoch for the given time
    /// @param time The timestamp for which to calculate the epoch
    /// @return The current epoch
    function currentEpoch(uint256 time) public view returns (uint256) {
        if (time < genesisEpoch) return 0;
        return ((time - genesisEpoch) / EPOCH_DURATION);
    }

    /// @notice Checks if a user has any CVE locker rewards to claim.
    /// @dev Even if a users lock is expiring the next lock resulting in 0 points,
    ///      we want their data updated so data is properly adjusted on unlock
    /// @param user The address of the user to check for reward claims.
    /// @return A boolean value indicating if the user has any rewards to claim.
    function hasRewardsToClaim(address user) public view returns (bool) {
        if (
            nextEpochToDeliver > userNextClaimIndex[user] &&
            veCVE.userTokenPoints(user) > 0
        ) return true;
        return false;
    }

    /// @notice Checks if a user has any CVE locker rewards to claim.
    /// @dev Even if a users lock is expiring the next lock resulting in 0 points,
    ///      we want their data updated so data is properly adjusted on unlock
    /// @param user The address of the user to check for reward claims.
    /// @return A boolean value indicating if the user has any rewards to claim.
    function epochsToClaim(address user) public view returns (uint256) {
        if (
            nextEpochToDeliver > userNextClaimIndex[user] &&
            veCVE.userTokenPoints(user) > 0
        ) {
            unchecked {
                return nextEpochToDeliver - userNextClaimIndex[user] - 1;
            }
        }
        return 0;
    }

    ///////////////////////////////////////////
    ////////// Fee Router Functions ///////////
    ///////////////////////////////////////////

    /// @notice Update user claim index
    /// @dev Updates the claim index of a user. Can only be called by the VeCVE contract.
    /// @param user The address of the user.
    /// @param index The new claim index.
    function updateUserClaimIndex(
        address user,
        uint256 index
    ) public onlyVeCVE {
        userNextClaimIndex[user] = index;
    }

    /// @notice Reset user claim index
    /// @dev Deletes the claim index of a user. Can only be called by the VeCVE contract.
    /// @param user The address of the user.
    function resetUserClaimIndex(address user) public onlyVeCVE {
        delete userNextClaimIndex[user];
    }

    ///////////////////////////////////////////
    ///////////// Reward Functions ////////////
    ///////////////////////////////////////////

    /// @notice Claim rewards for multiple epochs
    /// @param recipient The address who should receive the rewards of _user
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Swap data for token swapping rewards to desiredRewardToken.
    /// @param aux Auxiliary data for wrapped assets such as vlCVX and veCVE.
    function claimRewards(
        address recipient,
        RewardsData memory rewardsData,
        bytes memory params,
        uint256 aux
    ) public {
        uint256 epochs = epochsToClaim(msg.sender);
        require(epochs > 0, "cveLocker: no epochs to claim");
        _claimRewards(
            msg.sender,
            recipient,
            epochs,
            rewardsData,
            params,
            aux
        );
    }

    /// @notice Claim rewards for multiple epochs
    /// @param recipient The address who should receive the rewards of _user
    /// @param epochs The number of epochs for which to claim rewards.
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Swap data for token swapping rewards to desiredRewardToken.
    /// @param aux Auxiliary data for wrapped assets such as vlCVX and veCVE.
    function claimRewardsFor(
        address user,
        address recipient,
        uint256 epochs,
        RewardsData memory rewardsData,
        bytes memory params,
        uint256 aux
    ) public onlyVeCVE {
        /// We check whether there are epochs to claim in veCVE so we do not need to check here like in claimRewards
        _claimRewards(user, recipient, epochs, rewardsData, params, aux);
    }

    // See claimRewardFor above
    function _claimRewards(
        address user,
        address recipient,
        uint256 epochs,
        RewardsData memory rewardsData,
        bytes memory params,
        uint256 aux
    ) public {
        uint256 nextUserRewardEpoch = userNextClaimIndex[user];
        uint256 userRewards;

        for (uint256 i; i < epochs; ) {
            unchecked {
                userRewards += _calculateRewardsForEpoch(
                    nextUserRewardEpoch + i++
                );
            }
        }

        unchecked {
            userNextClaimIndex[user] += epochs;
            userRewards = userRewards / ethPerCVEOffset; //Removes the 1e18 offset for proper reward value
        }

        uint256 rewardAmount = _processRewards(
            recipient,
            userRewards,
            rewardsData,
            params,
            aux
        );

        if (rewardAmount > 0)
            // Only emit an event if they actually had rewards, do not wanna revert to maintain composability
            emit RewardPaid(
                user,
                recipient,
                rewardsData.desiredRewardToken,
                rewardAmount
            );
    }

    /// @notice Calculate the rewards for a given epoch
    /// @param epoch The epoch for which to calculate the rewards.
    /// @return The calculated reward amount. This is calculated based on the user's token points for the given epoch.
    function _calculateRewardsForEpoch(
        uint256 epoch
    ) internal returns (uint256) {
        if (veCVE.userTokenUnlocksByEpoch(msg.sender, epoch) > 0) {
            // If they have tokens unlocking this epoch we need to decriment their tokenPoints
            veCVE.updateUserPoints(msg.sender, epoch);
        }

        return (veCVE.userTokenPoints(msg.sender) * ethPerCVE[epoch]);
    }

    /// @notice Process user rewards
    /// @dev Process the rewards for the user, if any. If the user wishes to receive rewards in a token other than the base reward token, a swap is performed.
    /// If the desired reward token is CVE and the user opts for lock, the rewards are locked as VeCVE.
    /// @param userRewards The amount of rewards to process for the user.
    /// @param rewardsData Rewards data for CVE rewards locker
    /// @param params Additional parameters required for reward processing, which may include swap data.
    /// @param aux Auxiliary data for wrapped assets such as vlCVX and veCVE.
    function _processRewards(
        address recipient,
        uint256 userRewards,
        RewardsData memory rewardsData,
        bytes memory params,
        uint256 aux
    ) internal returns (uint256) {
        if (userRewards == 0) return 0;

        if (rewardsData.desiredRewardToken != baseRewardToken) {
            require(
                authorizedRewardToken[rewardsData.desiredRewardToken],
                "cveLocker: unsupported reward token"
            );

            SwapperLib.Swap memory swapData = abi.decode(
                params,
                (SwapperLib.Swap)
            );

            if (swapData.call.length > 0) {
                SwapperLib.swap(
                    swapData,
                    ICentralRegistry(centralRegistry).priceRouter(),
                    SLIPPAGE
                );
            } else {
                revert("cveLocker: swapData misconfigured");
            }

            if (
                rewardsData.desiredRewardToken == cvx &&
                rewardsData.shouldLock
            ) {
                return
                    _lockFeesAsVlCVX(
                        recipient,
                        rewardsData.desiredRewardToken,
                        aux
                    );
            }

            if (
                rewardsData.desiredRewardToken == cve &&
                rewardsData.shouldLock
            ) {
                return
                    _lockFeesAsVeCVE(
                        rewardsData.desiredRewardToken,
                        rewardsData.isFreshLock,
                        rewardsData.isFreshLockContinuous,
                        aux
                    ); // dont allow users to lock for others to avoid spam attacks
            }

            uint256 reward = IERC20(rewardsData.desiredRewardToken).balanceOf(
                address(this)
            );
            SafeTransferLib.safeTransfer(baseRewardToken, recipient, reward);
            return reward;
        }

        return _distributeRewardsAsETH(recipient, userRewards);
    }

    /// @notice Lock fees as veCVE
    /// @param desiredRewardToken The address of the token to be locked, this should be CVE.
    /// @param isFreshLock A boolean to indicate if it's a new lock.
    /// @param continuousLock A boolean to indicate if the lock should be continuous.
    /// @param lockIndex The index of the lock in the user's lock array. This parameter is only required if it is not a fresh lock.
    function _lockFeesAsVeCVE(
        address desiredRewardToken,
        bool isFreshLock,
        bool continuousLock,
        uint256 lockIndex
    ) internal returns (uint256) {
        uint256 reward = IERC20(desiredRewardToken).balanceOf(address(this));

        /// Because this call is nested within call to claim all rewards there will never be any rewards to process,
        /// and thus no potential secondary lock so we can just pass empty reward data to the veCVE calls
        if (isFreshLock) {
            veCVE.lockFor(
                msg.sender,
                reward,
                continuousLock,
                msg.sender,
                RewardsData({
                    desiredRewardToken: desiredRewardToken,
                    shouldLock: false,
                    isFreshLock: false,
                    isFreshLockContinuous: false
                }),
                "",
                0
            );
            return reward;
        }

        /// Because this call is nested within call to claim all rewards there will never be any rewards to process,
        /// and thus no potential secondary lock so we can just pass empty reward data to the veCVE calls
        veCVE.increaseAmountAndExtendLockFor(
            msg.sender,
            reward,
            lockIndex,
            continuousLock,
            msg.sender,
            RewardsData({
                desiredRewardToken: desiredRewardToken,
                shouldLock: false,
                isFreshLock: false,
                isFreshLockContinuous: false
            }),
            "",
            0
        );
        return reward;
    }

    /// @dev Lock fees as vlCVX
    /// @param recipient The address to receive the locked vlCVX tokens.
    /// @param desiredRewardToken The address of the token to be locked, this should be CVX.
    /// @param spendRatio X% of your deposit to gain Y% boost on the deposit, currently disabled.
    /// @return reward The total amount of CVX that was locked as vlCVX.
    function _lockFeesAsVlCVX(
        address recipient,
        address desiredRewardToken,
        uint256 spendRatio
    ) internal returns (uint256) {
        uint256 reward = IERC20(desiredRewardToken).balanceOf(address(this));
        cvxLocker.lock(recipient, reward, spendRatio);
        return reward;
    }

    /// @dev Distributes the specified reward amount as ETH to the recipient address.
    /// @param recipient The address to receive the ETH rewards.
    /// @param reward The amount of ETH to send.
    /// @return reward The total amount of ETH that was sent.
    function _distributeRewardsAsETH(
        address recipient,
        uint256 reward
    ) internal returns (uint256) {
        (bool success, ) = payable(recipient).call{ value: reward }("");
        require(success, "cveLocker: error sending ETH rewards");
        return reward;
    }

    /// @notice Recover tokens sent accidentally to the contract or leftover rewards (excluding veCVE tokens)
    /// @param token The address of the token to recover
    /// @param to The address to receive the recovered tokens
    /// @param amount The amount of tokens to recover
    function recoverToken(
        address token,
        address to,
        uint256 amount
    ) external onlyDaoPermissions {
        require(
            token != baseRewardToken,
            "cveLocker: cannot withdraw reward token"
        );
        if (amount == 0) {
            amount = IERC20(token).balanceOf(address(this));
        }
        SafeTransferLib.safeTransfer(token, to, amount);

        emit TokenRecovered(token, to, amount);
    }

    /// @dev Authorizes a new reward token. Can only be called by the DAO manager.
    /// @param token The address of the token to authorize.
    function addAuthorizedRewardToken(
        address token
    ) external onlyElevatedPermissions {
        require(token != address(0), "Invalid Token Address");
        require(!authorizedRewardToken[token], "Invalid Operation");
        authorizedRewardToken[token] = true;
    }

    /// @dev Removes an authorized reward token. Can only be called by the DAO manager.
    /// @param token The address of the token to deauthorize.
    function removeAuthorizedRewardToken(
        address token
    ) external onlyDaoPermissions {
        require(token != address(0), "Invalid Token Address");
        require(authorizedRewardToken[token], "Invalid Operation");
        delete authorizedRewardToken[token];
    }

    function notifyLockerShutdown() external {
        require(
            msg.sender == address(veCVE) ||
                centralRegistry.hasElevatedPermissions(msg.sender),
            "cveLocker: UNAUTHORIZED"
        );
        isShutdown = true;
    }

    /// @param chainId The remote chainId sending the tokens
    /// @param srcAddress The remote Bridge address
    /// @param nonce The message ordering nonce
    /// @param token The token contract on the local chain
    /// @param amountLD The qty of local _token contract tokens
    /// @param payload The bytes containing the _tokenOut, _deadline, _amountOutMin, _toAddr
    function sgReceive(
        uint16 chainId,
        bytes memory srcAddress,
        uint256 nonce,
        address token,
        uint256 amountLD,
        bytes memory payload
    ) external payable {}

    receive() external payable {}
}
