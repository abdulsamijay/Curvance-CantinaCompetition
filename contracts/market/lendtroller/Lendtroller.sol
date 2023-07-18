// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { PriceOracle } from "../Oracle/PriceOracle.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken } from "contracts/interfaces/market/ICToken.sol";
import { ILendtroller } from "contracts/interfaces/market/ILendtroller.sol";

/// @title Curvance Lendtroller
/// @notice Manages risk within the lending & collateral markets
contract Lendtroller is ILendtroller {

    /// CONSTANTS ///
    ICentralRegistry public immutable centralRegistry;
    /// @notice Indicator that this is a Lendtroller contract (for inspection)
    bool public constant override isLendtroller = true;
    /// @notice closeFactorScaled must be strictly greater than this value
    uint256 internal constant closeFactorMinScaled = 0.05e18; // 0.05
    /// @notice closeFactorScaled must not exceed this value
    uint256 internal constant closeFactorMaxScaled = 0.9e18; // 0.9
    /// @notice No collateralFactorScaled may exceed this value
    uint256 internal constant collateralFactorMaxScaled = 0.9e18; // 0.9
    /// @notice Scaler for floating point math
    uint256 internal constant expScale = 1e18;

    /// STORAGE ///
    /// @notice The Pause Guardian can pause certain actions as a safety mechanism.
    ///  Actions which allow users to remove their own assets cannot be paused.
    ///  Liquidation / seizing / transfer can only be paused globally, not by market.
    address public pauseGuardian;
    bool public _mintGuardianPaused;
    bool public _borrowGuardianPaused;
    bool public transferGuardianPaused;
    bool public seizeGuardianPaused;
    mapping(address => bool) public mintGuardianPaused;
    mapping(address => bool) public borrowGuardianPaused;

    /// @notice The borrowCapGuardian can set borrowCaps to any number for any market.
    /// Lowering the borrow cap could disable borrowing on the given market.
    address public borrowCapGuardian;

    /// @notice Borrow caps enforced by borrowAllowed for each cToken address.
    /// Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint256) public borrowCaps;

    /// @notice Oracle which gives the price of any given asset
    PriceOracle public oracle;

    /// @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
    uint256 public closeFactorScaled;

    /// @notice Multiplier representing the discount on collateral that a liquidator receives
    uint256 public liquidationIncentiveScaled;

    /// @notice Max number of assets a single account can participate in (borrow or use as collateral)
    uint256 public maxAssets;

    /// @notice Official mapping of cTokens -> Market metadata
    /// @dev Used e.g. to determine if a market is supported
    mapping(address => ILendtroller.Market) public markets;

    /// @notice A list of all markets
    ICToken[] public allMarkets;

    /// @notice Per-account mapping of "assets you are in", capped by maxAssets
    mapping(address => ICToken[]) public accountAssets;

    /// Whether market can be used for collateral or not
    mapping(ICToken => bool) public marketDisableCollateral;
    mapping(address => mapping(ICToken => bool)) public userDisableCollateral;

    // PositionFolding contract address
    address public override positionFolding;

    // GaugePool contract address
    address public immutable override gaugePool;

    constructor(ICentralRegistry _centralRegistry, address _gaugePool) {
        centralRegistry = _centralRegistry;
        oracle = PriceOracle(centralRegistry.priceRouter());
        gaugePool = _gaugePool;
    }

    modifier onlyDaoPermissions() {
        require(centralRegistry.hasDaoPermissions(msg.sender), "centralRegistry: UNAUTHORIZED");
        _;
    }

    modifier onlyElevatedPermissions() {
        require(centralRegistry.hasElevatedPermissions(msg.sender), "centralRegistry: UNAUTHORIZED");
        _;
    }

    /// @notice Returns the assets an account has entered
    /// @param account The address of the account to pull assets for
    /// @return A dynamic list with the assets the account has entered
    function getAssetsIn(
        address account
    ) external view returns (ICToken[] memory) {
        ICToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /// @notice Returns whether the given account is entered in the given asset
    /// @param account The address of the account to check
    /// @param cToken The cToken to check
    /// @return True if the account is in the asset, otherwise false.
    function checkMembership(
        address account,
        ICToken cToken
    ) external view returns (bool) {
        return markets[address(cToken)].accountMembership[account];
    }

    /// @notice Add assets to be included in account liquidity calculation
    /// @param cTokens The list of addresses of the cToken markets to be enabled
    /// @return uint array: 0 = market not entered; 1 = market entered
    function enterMarkets(
        address[] memory cTokens
    ) public override returns (uint256[] memory) {
        uint256 numCTokens = cTokens.length;

        uint256[] memory results = new uint256[](numCTokens);
        for (uint256 i; i < numCTokens; ++i) {
            results[i] = addToMarketInternal(ICToken(cTokens[i]), msg.sender);
        }

        // Return a list of markets joined & not joined (1 = joined, 0 = not joined)
        return results;
    }

    /// @notice Add the market to the borrower's "assets in" for liquidity calculations
    /// @param cToken The market to enter
    /// @param borrower The address of the account to modify
    /// @return uint 0 = unable to enter market; 1 = market entered
    function addToMarketInternal(
        ICToken cToken,
        address borrower
    ) internal returns (uint256) {
        ILendtroller.Market storage marketToJoin = markets[address(cToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return 0;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return 0;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(cToken);

        emit MarketEntered(cToken, borrower);

        // Indicates that a market was successfully entered
        return 1;
    }

    /// @notice Removes asset from sender's account liquidity calculation
    /// @dev Sender must not have an outstanding borrow balance in the asset,
    ///  or be providing necessary collateral for an outstanding borrow.
    /// @param cTokenAddress The address of the asset to be removed
    function exitMarket(address cTokenAddress) external override {
        ICToken cToken = ICToken(cTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the cToken */
        (uint256 tokensHeld, uint256 amountOwed, ) = cToken.getAccountSnapshot(
            msg.sender
        );

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            revert NonZeroBorrowBalance();
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        redeemAllowedInternal(cTokenAddress, msg.sender, tokensHeld);

        ILendtroller.Market storage marketToExit = markets[address(cToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return;
        }

        /* Set cToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete cToken from the account’s list of assets */
        // load into memory for faster iteration
        ICToken[] memory userAssetList = accountAssets[msg.sender];
        uint256 numUserAssets = userAssetList.length;
        uint256 assetIndex = numUserAssets;

        for (uint256 i; i < numUserAssets; ++i) {
            if (userAssetList[i] == cToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < numUserAssets);

        // copy last item in list to location of item to be removed, reduce length by 1
        ICToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(cToken, msg.sender);
    }

    /// Policy Hooks

    /// @notice Checks if the account should be allowed to mint tokens in the given market
    /// @param cToken The market to verify the mint against
    /// @param minter The account which would get the minted tokens
    function mintAllowed(address cToken, address minter) external override {
        // Pausing is a very serious situation - we revert to sound the alarms
        if (mintGuardianPaused[cToken]) {
            revert Paused();
        }

        if (!markets[cToken].isListed) {
            revert MarketNotListed(cToken);
        }
    }

    /// @notice Checks if the account should be allowed to redeem tokens in the given market
    /// @param cToken The market to verify the redeem against
    /// @param redeemer The account which would redeem the tokens
    /// @param redeemTokens The number of cTokens to exchange for the underlying asset in the market
    function redeemAllowed(
        address cToken,
        address redeemer,
        uint256 redeemTokens
    ) external override {
        redeemAllowedInternal(cToken, redeemer, redeemTokens);
    }

    /// @notice Checks if the account should be allowed to redeem tokens in the given market
    /// @param cToken The market to verify the redeem against
    /// @param redeemer The account which would redeem the tokens
    /// @param redeemTokens The number of cTokens to exchange for the underlying asset in the market
    function redeemAllowedInternal(
        address cToken,
        address redeemer,
        uint256 redeemTokens
    ) internal view {
        if (!markets[cToken].isListed) {
            revert MarketNotListed(cToken);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[cToken].accountMembership[redeemer]) {
            return;
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (, uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            redeemer,
            ICToken(cToken),
            redeemTokens,
            0
        );

        if (shortfall > 0) {
            revert InsufficientLiquidity();
        }
    }

    /// @notice Checks if the account should be allowed to borrow the underlying asset of the given market
    /// @param cToken The market to verify the borrow against
    /// @param borrower The account which would borrow the asset
    /// @param borrowAmount The amount of underlying the account would borrow
    function borrowAllowed(
        address cToken,
        address borrower,
        uint256 borrowAmount
    ) external override {
        // Pausing is a very serious situation - we revert to sound the alarms
        if (borrowGuardianPaused[cToken]) {
            revert Paused();
        }

        if (!markets[cToken].isListed) {
            revert MarketNotListed(cToken);
        }

        if (!markets[cToken].accountMembership[borrower]) {
            // only cTokens may call borrowAllowed if borrower not in market
            if (msg.sender != cToken) {
                revert AddressUnauthorized();
            }

            addToMarketInternal(ICToken(msg.sender), borrower);

            // it should be impossible to break the important invariant
            assert(markets[cToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(ICToken(cToken)) == 0) {
            revert PriceError();
        }

        uint256 borrowCap = borrowCaps[cToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint256 totalBorrows = ICToken(cToken).totalBorrows();
            uint256 nextTotalBorrows = totalBorrows + borrowAmount;

            if (nextTotalBorrows >= borrowCap) {
                revert BorrowCapReached();
            }
        }

        (, uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            borrower,
            ICToken(cToken),
            0,
            borrowAmount
        );

        if (shortfall > 0) {
            revert InsufficientLiquidity();
        }
    }

    /// @notice Checks if the account should be allowed to repay a borrow in the given market
    /// @param cToken The market to verify the repay against
    /// @param borrower The account which would borrowed the asset
    function repayBorrowAllowed(
        address cToken,
        address borrower
    ) external override {
        if (!markets[cToken].isListed) {
            revert MarketNotListed(cToken);
        }
    }

    /// @notice Checks if the liquidation should be allowed to occur
    /// @param cTokenBorrowed Asset which was borrowed by the borrower
    /// @param cTokenCollateral Asset which was used as collateral and will be seized
    /// @param borrower The address of the borrower
    /// @param repayAmount The amount of underlying being repaid
    function liquidateBorrowAllowed(
        address cTokenBorrowed,
        address cTokenCollateral,
        address borrower,
        uint256 repayAmount
    ) external view override {
        if (!markets[cTokenBorrowed].isListed) {
            revert MarketNotListed(cTokenBorrowed);
        }
        if (!markets[cTokenCollateral].isListed) {
            revert MarketNotListed(cTokenCollateral);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (, uint256 shortfall) = getAccountLiquidityInternal(borrower);
        if (shortfall == 0) {
            revert InsufficientShortfall();
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint256 borrowBalance = ICToken(cTokenBorrowed).borrowBalanceStored(
            borrower
        );
        uint256 maxClose = (closeFactorScaled * borrowBalance) / expScale;

        if (repayAmount > maxClose) {
            revert TooMuchRepay();
        }
    }

    /// @notice Checks if the seizing of assets should be allowed to occur
    /// @param cTokenCollateral Asset which was used as collateral and will be seized
    /// @param cTokenBorrowed Asset which was borrowed by the borrower
    /// @param liquidator The address repaying the borrow and seizing the collateral
    /// @param borrower The address of the borrower
    function seizeAllowed(
        address cTokenCollateral,
        address cTokenBorrowed,
        address liquidator,
        address borrower
    ) external override {
        // Pausing is a very serious situation - we revert to sound the alarms
        if (seizeGuardianPaused) {
            revert Paused();
        }

        if (!markets[cTokenBorrowed].isListed) {
            revert MarketNotListed(cTokenBorrowed);
        }
        if (!markets[cTokenCollateral].isListed) {
            revert MarketNotListed(cTokenCollateral);
        }

        if (
            ICToken(cTokenCollateral).lendtroller() !=
            ICToken(cTokenBorrowed).lendtroller()
        ) {
            revert LendtrollerMismatch();
        }
    }

    /// @notice Checks if the account should be allowed to transfer tokens in the given market
    /// @param cToken The market to verify the transfer against
    /// @param src The account which sources the tokens
    /// @param dst The account which receives the tokens
    /// @param transferTokens The number of cTokens to transfer
    function transferAllowed(
        address cToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external override {
        // Pausing is a very serious situation - we revert to sound the alarms
        if (transferGuardianPaused) {
            revert Paused();
        }

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        redeemAllowedInternal(cToken, src, transferTokens);
    }

    /// Liquidity/Liquidation Calculations

    /// @notice Determine the current account liquidity wrt collateral requirements
    /// @return liquidity of account in excess of collateral requirements
    /// @return shortfall of account below collateral requirements
    function getAccountLiquidity(
        address account
    ) public view returns (uint256, uint256) {
        (
            uint256 liquidity,
            uint256 shortfall
        ) = getHypotheticalAccountLiquidityInternal(
                account,
                ICToken(address(0)),
                0,
                0
            );

        return (liquidity, shortfall);
    }

    /// @notice Determine the current account liquidity wrt collateral requirements
    /// @return uint total collateral amount of user
    /// @return uint max borrow amount of user
    /// @return uint total borrow amount of user
    function getAccountPosition(
        address account
    ) public view override returns (uint256, uint256, uint256) {
        (
            uint256 sumCollateral,
            uint256 maxBorrow,
            uint256 sumBorrow
        ) = getHypotheticalAccountPositionInternal(
                account,
                ICToken(address(0)),
                0,
                0
            );

        return (sumCollateral, maxBorrow, sumBorrow);
    }

    /// @notice Determine the current account liquidity wrt collateral requirements
    /// @return liquidity of account in excess of collateral requirements
    /// @return shortfall of account below collateral requirements
    function getAccountLiquidityInternal(
        address account
    ) internal view returns (uint256, uint256) {
        return
            getHypotheticalAccountLiquidityInternal(
                account,
                ICToken(address(0)),
                0,
                0
            );
    }

    /// @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
    /// @param cTokenModify The market to hypothetically redeem/borrow in
    /// @param account The account to determine liquidity for
    /// @param redeemTokens The number of tokens to hypothetically redeem
    /// @param borrowAmount The amount of underlying to hypothetically borrow
    /// @return uint hypothetical account liquidity in excess of collateral requirements,
    /// @return uint hypothetical account shortfall below collateral requirements)
    function getHypotheticalAccountLiquidity(
        address account,
        address cTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) public view returns (uint256, uint256) {
        (
            uint256 liquidity,
            uint256 shortfall
        ) = getHypotheticalAccountLiquidityInternal(
                account,
                ICToken(cTokenModify),
                redeemTokens,
                borrowAmount
            );

        return (liquidity, shortfall);
    }

    /// @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
    /// @param cTokenModify The market to hypothetically redeem/borrow in
    /// @param account The account to determine liquidity for
    /// @param redeemTokens The number of tokens to hypothetically redeem
    /// @param borrowAmount The amount of underlying to hypothetically borrow
    /// @dev Note that we calculate the exchangeRateStored for each collateral cToken using stored data,
    ///  without calculating accumulated interest.
    /// @return uint hypothetical account liquidity in excess of collateral requirements,
    /// @return uint hypothetical account shortfall below collateral requirements)
    function getHypotheticalAccountLiquidityInternal(
        address account,
        ICToken cTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) internal view returns (uint256, uint256) {
        (
            ,
            uint256 maxBorrow,
            uint256 sumBorrowPlusEffects
        ) = getHypotheticalAccountPositionInternal(
                account,
                cTokenModify,
                redeemTokens,
                borrowAmount
            );

        // These are safe, as the underflow condition is checked first
        if (maxBorrow > sumBorrowPlusEffects) {
            return (maxBorrow - sumBorrowPlusEffects, 0);
        } else {
            return (0, sumBorrowPlusEffects - maxBorrow);
        }
    }

    /// @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
    /// @param cTokenModify The market to hypothetically redeem/borrow in
    /// @param account The account to determine liquidity for
    /// @param redeemTokens The number of tokens to hypothetically redeem
    /// @param borrowAmount The amount of underlying to hypothetically borrow
    /// @dev Note that we calculate the exchangeRateStored for each collateral cToken using stored data,
    ///  without calculating accumulated interest.
    /// @return sumCollateral total collateral amount of user
    /// @return maxBorrow max borrow amount of user
    /// @return sumBorrowPlusEffects total borrow amount of user
    function getHypotheticalAccountPositionInternal(
        address account,
        ICToken cTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    )
        internal
        view
        returns (
            uint256 sumCollateral,
            uint256 maxBorrow,
            uint256 sumBorrowPlusEffects
        )
    {
        uint256 numAccountAssets = accountAssets[account].length;
        ICToken asset;
        bool collateralEnabled;

        // For each asset the account is in
        for (uint256 i; i < numAccountAssets; ++i) {
            asset = accountAssets[account][i];
            collateralEnabled =
                marketDisableCollateral[asset] == false &&
                userDisableCollateral[account][asset] == false;

            (
                uint256 cTokenBalance,
                uint256 borrowBalance,
                uint256 exchangeRateScaled
            ) = asset.getAccountSnapshot(account);
            uint256 oraclePrice = oracle.getUnderlyingPrice(asset);
            if (oraclePrice == 0) revert PriceError();

            uint256 assetValue = (((cTokenBalance * exchangeRateScaled) /
                expScale) * oraclePrice) / expScale;

            if (collateralEnabled) {
                sumCollateral += assetValue;
                maxBorrow +=
                    (assetValue *
                        markets[address(asset)].collateralFactorScaled) /
                    expScale;
            }

            sumBorrowPlusEffects += ((oraclePrice * borrowBalance) / expScale);

            // Calculate effects of interacting with cTokenModify
            if (asset == cTokenModify) {
                if (collateralEnabled) {
                    // Pre-compute a conversion factor from tokens -> ether (normalized price value)
                    uint256 tokensToDenom = (((markets[address(asset)]
                        .collateralFactorScaled * exchangeRateScaled) /
                        expScale) * oraclePrice) / expScale;

                    // redeem effect
                    sumBorrowPlusEffects += ((tokensToDenom * redeemTokens) /
                        expScale);
                }

                // borrow effect
                sumBorrowPlusEffects += ((oraclePrice * borrowAmount) /
                    expScale);
            }
        }
    }

    /// @notice Calculate number of tokens of collateral asset to seize given an underlying amount
    /// @dev Used in liquidation (called in cToken.liquidateBorrowFresh)
    /// @param cTokenBorrowed The address of the borrowed cToken
    /// @param cTokenCollateral The address of the collateral cToken
    /// @param actualRepayAmount The amount of cTokenBorrowed underlying to convert into cTokenCollateral tokens
    /// @return uint The number of cTokenCollateral tokens to be seized in a liquidation
    function liquidateCalculateSeizeTokens(
        address cTokenBorrowed,
        address cTokenCollateral,
        uint256 actualRepayAmount
    ) external view override returns (uint256) {
        /* Read oracle prices for borrowed and collateral markets */
        uint256 priceBorrowedScaled = oracle.getUnderlyingPrice(
            ICToken(cTokenBorrowed)
        );
        uint256 priceCollateralScaled = oracle.getUnderlyingPrice(
            ICToken(cTokenCollateral)
        );

        if (priceBorrowedScaled == 0 || priceCollateralScaled == 0) {
            revert PriceError();
        }

        // Get the exchange rate and calculate the number of collateral tokens to seize:
        //  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
        //  seizeTokens = seizeAmount / exchangeRate
        //   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
        uint256 exchangeRateScaled = ICToken(cTokenCollateral)
            .exchangeRateStored();
        uint256 numerator = liquidationIncentiveScaled * priceBorrowedScaled;
        uint256 denominator = priceCollateralScaled * exchangeRateScaled;
        uint256 ratio = (numerator * expScale) / denominator;
        uint256 seizeTokens = (ratio * actualRepayAmount) / expScale;

        return seizeTokens;
    }

    /// User Custom Functions

    /// @notice User set collateral on/off option for market token
    /// @param cTokens The addresses of the markets (tokens) to change the collateral on/off option
    /// @param disableCollateral Disable cToken from collateral
    function setUserDisableCollateral(
        ICToken[] calldata cTokens,
        bool disableCollateral
    ) external {
        uint256 numMarkets = cTokens.length;
        if (numMarkets == 0) {
            revert InvalidValue();
        }

        for (uint256 i; i < numMarkets; ++i) {
            userDisableCollateral[msg.sender][cTokens[i]] = disableCollateral;
            emit SetUserDisableCollateral(
                msg.sender,
                cTokens[i],
                disableCollateral
            );
        }

        (, uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            msg.sender,
            ICToken(address(0)),
            0,
            0
        );

        if (shortfall > 0) {
            revert InsufficientLiquidity();
        }
    }

    /// Admin Functions

    /// @notice Sets the closeFactor used when liquidating borrows
    /// @dev Admin function to set closeFactor
    /// @param newCloseFactorScaled New close factor, scaled by 1e18
    function _setCloseFactor(uint256 newCloseFactorScaled) external onlyElevatedPermissions {

        uint256 oldCloseFactorScaled = closeFactorScaled;
        closeFactorScaled = newCloseFactorScaled;
        emit NewCloseFactor(oldCloseFactorScaled, closeFactorScaled);
    }

    /// @notice Sets the collateralFactor for a market
    /// @dev Admin function to set per-market collateralFactor
    /// @param cToken The market to set the factor on
    /// @param newCollateralFactorScaled The new collateral factor, scaled by 1e18
    function _setCollateralFactor(
        ICToken cToken,
        uint256 newCollateralFactorScaled
    ) external onlyElevatedPermissions {

        // Verify market is listed
        ILendtroller.Market storage market = markets[address(cToken)];
        if (!market.isListed) {
            revert MarketNotListed(address(cToken));
        }

        // Check collateral factor <= 0.9
        if (collateralFactorMaxScaled < newCollateralFactorScaled) {
            revert InvalidValue();
        }

        // If collateral factor != 0, fail if price == 0
        if (
            newCollateralFactorScaled != 0 &&
            oracle.getUnderlyingPrice(cToken) == 0
        ) {
            revert PriceError();
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint256 oldCollateralFactorScaled = market.collateralFactorScaled;
        market.collateralFactorScaled = newCollateralFactorScaled;

        emit NewCollateralFactor(
            cToken,
            oldCollateralFactorScaled,
            newCollateralFactorScaled
        );
    }

    /// @notice Sets liquidationIncentive
    /// @dev Admin function to set liquidationIncentive
    /// @param newLiquidationIncentiveScaled New liquidationIncentive scaled by 1e18
    function _setLiquidationIncentive(
        uint256 newLiquidationIncentiveScaled
    ) external onlyElevatedPermissions {

        // Save current value for use in log
        uint256 oldLiquidationIncentiveScaled = liquidationIncentiveScaled;

        // Set liquidation incentive to new incentive
        liquidationIncentiveScaled = newLiquidationIncentiveScaled;

        emit NewLiquidationIncentive(
            oldLiquidationIncentiveScaled,
            newLiquidationIncentiveScaled
        );
    }

    /// @notice Add the market to the markets mapping and set it as listed
    /// @dev Admin function to set isListed and add support for the market
    /// @param cToken The address of the market (token) to list
    function _supportMarket(ICToken cToken) external onlyElevatedPermissions {

        if (markets[address(cToken)].isListed) {
            revert MarketAlreadyListed();
        }

        cToken.isCToken(); // Sanity check to make sure its really a ICToken

        ILendtroller.Market storage market = markets[address(cToken)];
        market.isListed = true;
        market.collateralFactorScaled = 0;

        _addMarketInternal(address(cToken));

        emit MarketListed(cToken);
    }

    /// @notice Add the market to the markets mapping and set it as listed
    /// @param cToken The address of the market (token) to list
    function _addMarketInternal(address cToken) internal {
        uint256 numMarkets = allMarkets.length;

        for (uint256 i; i < numMarkets; ++i) {
            if (allMarkets[i] == ICToken(cToken)) {
                revert MarketAlreadyListed();
            }
        }
        allMarkets.push(ICToken(cToken));
    }

    /// @notice Set the given borrow caps for the given cToken markets.
    ///   Borrowing that brings total borrows to or above borrow cap will revert.
    /// @dev Admin or borrowCapGuardian function to set the borrow caps.
    ///   A borrow cap of 0 corresponds to unlimited borrowing.
    /// @param cTokens The addresses of the markets (tokens) to change the borrow caps for
    /// @param newBorrowCaps The new borrow cap values in underlying to be set.
    ///   A value of 0 corresponds to unlimited borrowing.
    function _setMarketBorrowCaps(
        ICToken[] calldata cTokens,
        uint256[] calldata newBorrowCaps
    ) external {
        if (!centralRegistry.hasElevatedPermissions(msg.sender) && msg.sender != borrowCapGuardian) {
            revert AddressUnauthorized();
        }
        uint256 numMarkets = cTokens.length;

        if (numMarkets == 0 || numMarkets != newBorrowCaps.length) {
            revert InvalidValue();
        }

        for (uint256 i; i < numMarkets; ++i) {
            borrowCaps[address(cTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(cTokens[i], newBorrowCaps[i]);
        }
    }

    /// @notice Set collateral on/off option for market token
    /// @dev Admin can set the collateral on or off
    /// @param cTokens The addresses of the markets (tokens) to change the collateral on/off option
    /// @param disableCollateral Disable cToken from collateral
    function _setDisableCollateral(
        ICToken[] calldata cTokens,
        bool disableCollateral
    ) external onlyElevatedPermissions {

        uint256 numMarkets = cTokens.length;
        if (numMarkets == 0) {
            revert InvalidValue();
        }

        for (uint256 i; i < numMarkets; ++i) {
            marketDisableCollateral[cTokens[i]] = disableCollateral;
            emit SetDisableCollateral(cTokens[i], disableCollateral);
        }
    }

    /// @notice Admin function to change the Borrow Cap Guardian
    /// @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external onlyElevatedPermissions {

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /// @notice Admin function to change the Pause Guardian
    /// @param newPauseGuardian The address of the new Pause Guardian
    function _setPauseGuardian(address newPauseGuardian) public onlyElevatedPermissions {

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);
    }

    /// @notice Admin function to set market mint paused
    /// @param cToken market token address
    /// @param state pause or unpause
    function _setMintPaused(ICToken cToken, bool state) public returns (bool) {
        if (!markets[address(cToken)].isListed) {
            revert MarketNotListed(address(cToken));
        }

        bool hasDaoPerms = centralRegistry.hasElevatedPermissions(msg.sender);

        if (msg.sender != pauseGuardian && !hasDaoPerms) {
            revert AddressUnauthorized();
        }
        if (!hasDaoPerms && state != true) {
            revert AddressUnauthorized();
        }

        mintGuardianPaused[address(cToken)] = state;
        emit ActionPaused(cToken, "Mint", state);
        return state;
    }

    /// @notice Admin function to set market borrow paused
    /// @param cToken market token address
    /// @param state pause or unpause
    function _setBorrowPaused(
        ICToken cToken,
        bool state
    ) public returns (bool) {
        if (!markets[address(cToken)].isListed) {
            revert MarketNotListed(address(cToken));
        }

        bool hasDaoPerms = centralRegistry.hasElevatedPermissions(msg.sender);

        if (msg.sender != pauseGuardian && !hasDaoPerms) {
            revert AddressUnauthorized();
        }
        if (!hasDaoPerms && state != true) {
            revert AddressUnauthorized();
        }

        borrowGuardianPaused[address(cToken)] = state;
        emit ActionPaused(cToken, "Borrow", state);
        return state;
    }

    /// @notice Admin function to set transfer paused
    /// @param state pause or unpause
    function _setTransferPaused(bool state) public returns (bool) {
        bool hasDaoPerms = centralRegistry.hasElevatedPermissions(msg.sender);

        if (msg.sender != pauseGuardian && !hasDaoPerms) {
            revert AddressUnauthorized();
        }
        if (!hasDaoPerms && state != true) {
            revert AddressUnauthorized();
        }

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    /// @notice Admin function to set seize paused
    /// @param state pause or unpause
    function _setSeizePaused(bool state) public returns (bool) {
        bool hasDaoPerms = centralRegistry.hasElevatedPermissions(msg.sender);

        if (msg.sender != pauseGuardian && !hasDaoPerms) {
            revert AddressUnauthorized();
        }
        if (!hasDaoPerms && state != true) {
            revert AddressUnauthorized();
        }

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    /// @notice Admin function to set position folding contract address
    /// @param _newPositionFolding new position folding contract address
    function _setPositionFolding(address _newPositionFolding) public onlyElevatedPermissions {

        emit NewPositionFoldingContract(positionFolding, _newPositionFolding);

        positionFolding = _newPositionFolding;
    }

    /// @notice Returns minimum value of a and b
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a <= b) {
            return a;
        } else {
            return b;
        }
    }

    /// @notice Returns market status
    /// @param cToken market token address
    function getIsMarkets(
        address cToken
    ) external view override returns (bool, uint256) {
        return (
            markets[cToken].isListed,
            markets[cToken].collateralFactorScaled
        );
    }

    /// @notice Returns if user joined market
    /// @param cToken market token address
    /// @param user user address
    function getAccountMembership(
        address cToken,
        address user
    ) external view override returns (bool) {
        return markets[cToken].accountMembership[user];
    }

    /// @notice Returns all markets
    function getAllMarkets()
        external
        view
        override
        returns (ICToken[] memory)
    {
        return allMarkets;
    }

    /// @notice Returns all markets user joined
    /// @param user user address
    function getAccountAssets(
        address user
    ) external view override returns (ICToken[] memory) {
        return accountAssets[user];
    }
}