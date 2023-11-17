// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ERC165 } from "contracts/libraries/ERC165.sol";
import { ERC165Checker } from "contracts/libraries/ERC165Checker.sol";
import { GaugePool } from "contracts/gauge/GaugePool.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ILendtroller } from "contracts/interfaces/market/ILendtroller.sol";
import { IPositionFolding } from "contracts/interfaces/market/IPositionFolding.sol";
import { IPriceRouter } from "contracts/interfaces/IPriceRouter.sol";
import { IMToken, AccountSnapshot } from "contracts/interfaces/market/IMToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { WAD } from "contracts/libraries/Constants.sol";

/// @title Curvance Lendtroller
/// @notice Manages risk within the lending markets
contract Lendtroller is ILendtroller, ERC165 {
    /// TYPES ///

    struct AccountData {
        /// @notice Array of account assets.
        IMToken[] assets;
        /// @notice cooldownTimestamp Last time an account performed an action,
        ///         which activates the redeem/repay/exit market cooldown.
        uint256 cooldownTimestamp;
    }

    struct AccountMetadata {
        /// @notice Value that indicates whether an account has an active position in the token.
        /// @dev    0 or 1 for no; 2 for yes
        uint256 activePosition;
        /// @notice The amount of collateral an account has posted.
        /// @dev    Only relevant for cTokens not dTokens
        uint256 collateralPosted;
    }

    struct MarketToken {
        /// @notice Whether or not this market token is listed.
        /// @dev    false = unlisted; true = listed
        bool isListed;
        /// @notice The ratio at which this token can be collateralized.
        /// @dev    in `WAD` format, with 0.8e18 = 80% collateral value
        uint256 collRatio;
        /// @notice The collateral requirement where dipping below this will cause a soft liquidation.
        /// @dev    in `WAD` format, with 1.2e18 = 120% collateral vs debt value
        uint256 collReqA;
        /// @notice The collateral requirement where dipping below this will cause a hard liquidation.
        /// @dev    in `WAD` format, with 1.2e18 = 120% collateral vs debt value
        uint256 collReqB;
        /// @notice The base ratio at which this token will be compensated on soft liquidation.
        /// @dev    In `WAD` format, stored as (Incentive + WAD)
        ///         e.g 1.05e18 = 5% incentive, this saves gas for liquidation calculations
        uint256 liqBaseIncentive;
        /// @notice The liquidation incentive curve length between soft liquidation to hard liquidation.
        ///         e.g. 5% base incentive with 8% curve length results in 13% liquidation incentive
        ///         on hard liquidation.
        /// @dev    In `WAD` format.
        ///         e.g 05e18 = 5% maximum additional incentive
        uint256 liqCurve;
        /// @notice The protocol fee that will be taken on liquidation for this token.
        /// @dev    In `WAD` format, 0.01e18 = 1%
        ///         Note: this is stored as (Fee * WAD) / `liqIncA`
        ///         in order to save gas for liquidation calculations
        uint256 liqFee;
        /// @notice Maximum % that a liquidator can repay when soft liquidating an account,
        /// @dev    In `WAD` format.
        uint256 baseCFactor;
        /// @notice cFactor curve length between soft liquidation and hard liquidation,
        /// @dev    In `WAD` format.
        uint256 cFactorCurve;
        /// @notice Mapping that stores account information like token positions and collateral posted.
        mapping(address => AccountMetadata) accountData;
    }

    struct LiqData {
        uint256 lFactor;
        uint256 debtTokenPrice;
        uint256 collateralTokenPrice;
    }

    /// CONSTANTS ///

    /// @notice Maximum collateral requirement to avoid liquidation. 40%
    uint256 internal constant _MAX_COLLATERAL_REQUIREMENT = 0.4e18;
    /// @notice Maximum collateralization ratio. 91%
    uint256 internal constant _MAX_COLLATERALIZATION_RATIO = 0.91e18;
    /// @notice Minimum hold time to prevent oracle price attacks.
    uint256 internal constant _MIN_HOLD_PERIOD = 20 minutes;
    /// @notice The maximum liquidation incentive. 30%
    uint256 internal constant _MAX_LIQUIDATION_INCENTIVE = .3e18;
    /// @notice The minimum liquidation incentive. 1%
    uint256 internal constant _MIN_LIQUIDATION_INCENTIVE = .01e18;
    /// @notice The maximum liquidation incentive. 5%
    uint256 internal constant _MAX_LIQUIDATION_FEE = .05e18;
    /// `bytes4(keccak256(bytes("Lendtroller__InvalidParameter()")))`
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0x31765827;
    /// @notice Curvance DAO hub
    ICentralRegistry public immutable centralRegistry;
    /// @notice gaugePool contract address.
    GaugePool public immutable gaugePool;

    /// STORAGE ///

    /// @notice A list of all tokens inside this market for the frontend.
    address[] public tokensListed;

    /// @notice PositionFolding contract address.
    address public positionFolding;

    /// MARKET STATE
    /// @dev 1 = unpaused; 2 = paused
    uint256 public transferPaused = 1;
    /// @dev 1 = unpaused; 2 = paused
    uint256 public seizePaused = 1;
    /// @dev Token => 0 or 1 = unpaused; 2 = paused
    mapping(address => uint256) public mintPaused;
    /// @dev Token => 0 or 1 = unpaused; 2 = paused
    mapping(address => uint256) public borrowPaused;

    /// MARKET DATA
    /// @notice Market Token => isListed, Token Characteristics, Account Data.
    mapping(address => MarketToken) public tokenData;
    /// @notice Account => Assets, cooldownTimestamp.
    mapping(address => AccountData) public accountAssets;

    /// COLLATERAL CONSTRAINTS
    /// @notice Token => Collateral Posted
    mapping(address => uint256) public collateralPosted;
    /// @notice Token => Collateral Cap
    mapping(address => uint256) public collateralCaps;

    /// EVENTS ///

    event TokenListed(address mToken);
    event CollateralPosted(address account, address cToken, uint256 amount);
    event CollateralRemoved(address account, address cToken, uint256 amount);
    event TokenPositionCreated(address mToken, address account);
    event TokenPositionClosed(address mToken, address account);
    event NewCloseFactor(uint256 oldCloseFactor, uint256 newCloseFactor);
    event CollateralTokenUpdated(
        IMToken mToken,
        uint256 collRatio,
        uint256 collReqA,
        uint256 collReqB,
        uint256 liqIncA,
        uint256 liqIncB,
        uint256 liqFee,
        uint256 baseCFactor
    );
    event ActionPaused(string action, bool pauseState);
    event TokenActionPaused(address mToken, string action, bool pauseState);
    event NewCollateralCap(address mToken, uint256 newCollateralCap);
    event NewPositionFoldingContract(address oldPF, address newPF);

    /// ERRORS ///

    error Lendtroller__Unauthorized();
    error Lendtroller__TokenNotListed();
    error Lendtroller__TokenAlreadyListed();
    error Lendtroller__Paused();
    error Lendtroller__InsufficientCollateral();
    error Lendtroller__InsufficientLiquidity();
    error Lendtroller__NoLiquidationAvailable();
    error Lendtroller__PriceError();
    error Lendtroller__HasActiveLoan();
    error Lendtroller__CollateralCapReached();
    error Lendtroller__LendtrollerMismatch();
    error Lendtroller__InvalidParameter();
    error Lendtroller__MinimumHoldPeriod();
    error Lendtroller__InvariantError();

    /// MODIFIERS ///

    modifier onlyElevatedPermissions() {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert Lendtroller__Unauthorized();
        }
        _;
    }

    modifier onlyAuthorizedPermissions(bool state) {
        if (state) {
            if (!centralRegistry.hasDaoPermissions(msg.sender)) {
                revert Lendtroller__Unauthorized();
            }
        } else {
            if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
                revert Lendtroller__Unauthorized();
            }
        }
        _;
    }

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry centralRegistry_, address gaugePool_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }
        if (gaugePool_ == address(0)) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        centralRegistry = centralRegistry_;
        gaugePool = GaugePool(gaugePool_);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns the assets an account has entered
    /// @param account The address of the account to pull assets for
    /// @return A dynamic list with the assets the account has entered
    function getAccountAssets(
        address account
    ) external view override returns (IMToken[] memory) {
        return accountAssets[account].assets;
    }

    /// @notice Post collateral in some cToken for borrowing inside this market
    /// @param mToken The address of the mToken to post collateral for
    function postCollateral(
        address account,
        address mToken,
        uint256 tokens
    ) public {
        AccountMetadata storage accountData = tokenData[mToken].accountData[
            msg.sender
        ];

        if (!tokenData[mToken].isListed) {
            revert Lendtroller__TokenNotListed();
        }

        if (!IMToken(mToken).isCToken()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // If you are trying to post collateral for someone else,
        // make sure it is done via the mToken contract itself
        if (msg.sender != account) {
            if (msg.sender != mToken) {
                revert Lendtroller__Unauthorized();
            }
        }

        if (
            accountData.collateralPosted + tokens >
            IMToken(mToken).balanceOf(msg.sender)
        ) {
            revert Lendtroller__InsufficientCollateral();
        }

        _postCollateral(msg.sender, accountData, mToken, tokens);
    }

    /// @notice Post collateral in some cToken for borrowing inside this market
    /// @param mToken The address of the mToken to post collateral for
    function removeCollateral(
        address mToken,
        uint256 tokens,
        bool closePositionIfPossible
    ) public {
        AccountMetadata storage accountData = tokenData[mToken].accountData[
            msg.sender
        ];

        // We can check this instead of .isListed,
        // since any non-listed token will always have activePosition == 0,
        // and this lets us check for any invariant errors
        if (accountData.activePosition != 2) {
            revert Lendtroller__InvariantError();
        }

        if (!IMToken(mToken).isCToken()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (accountData.collateralPosted < tokens) {
            revert Lendtroller__InsufficientCollateral();
        }

        // Fail if the sender is not permitted to redeem `tokens`
        // note: tokens is in shares
        _canRedeem(mToken, msg.sender, tokens);
        _removeCollateral(
            msg.sender,
            accountData,
            mToken,
            tokens,
            closePositionIfPossible
        );
    }

    /// @notice Removes an asset from an account's liquidity calculation
    /// @dev Sender must not have an outstanding borrow balance in the asset,
    ///      or be providing necessary collateral for an outstanding borrow.
    /// @param mToken The address of the asset to be removed
    function closePosition(address mToken) external {
        IMToken token = IMToken(mToken);
        AccountMetadata storage accountData = tokenData[mToken].accountData[
            msg.sender
        ];

        // We do not need to update any values if the account is not ‘in’ the market
        if (accountData.activePosition < 2) {
            revert Lendtroller__InvalidParameter();
        }

        if (!token.isCToken()) {
            // Get sender tokens and debt underlying from the mToken
            (, uint256 debt, ) = token.getSnapshot(msg.sender);

            // Do not let them leave if they owe a balance
            if (debt != 0) {
                revert Lendtroller__HasActiveLoan();
            }

            _closePosition(msg.sender, accountData, token);
            return;
        }

        if (accountData.collateralPosted != 0) {
            // Fail if the sender is not permitted to redeem all of their tokens
            _canRedeem(mToken, msg.sender, accountData.collateralPosted);
            // We use collateral posted here instead of their snapshot,
            // since its possible they have not posted all their tokens as collateral
            _removeCollateral(
                msg.sender,
                accountData,
                mToken,
                accountData.collateralPosted,
                true
            );
            return;
        }

        // Its possible they have a position without collateral posted if:
        // They were liquidated
        // They removed all their collateral but did not use `closePositionIfPossible`
        // So we need to still close their position here
        _closePosition(msg.sender, accountData, token);
    }

    /// @notice Checks if the account should be allowed to mint tokens
    ///         in the given market
    /// @param mToken The token to verify mints against
    function canMint(address mToken) external view override {
        if (mintPaused[mToken] == 2) {
            revert Lendtroller__Paused();
        }

        if (!tokenData[mToken].isListed) {
            revert Lendtroller__TokenNotListed();
        }
    }

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market
    /// @param mToken The market to verify the redeem against
    /// @param redeemer The account which would redeem the tokens
    /// @param amount The number of mTokens to exchange
    ///               for the underlying asset in the market
    function canRedeem(
        address mToken,
        address redeemer,
        uint256 amount
    ) external view override {
        _canRedeem(mToken, redeemer, amount);
    }

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market, and then redeems
    /// @dev    This can only be called by the mToken itself,
    ///         this will only be cTokens calling, dTokens are never collateral
    /// @param mToken The market to verify the redeem against
    /// @param redeemer The account which would redeem the tokens
    /// @param balance The current mTokens balance of `redeemer`
    /// @param amount The number of mTokens to exchange
    ///               for the underlying asset in the market
    /// @param forceRedeemCollateral Whether the collateral should be always reduced
    function canRedeemWithCollateralRemoval(
        address mToken,
        address redeemer,
        uint256 balance,
        uint256 amount,
        bool forceRedeemCollateral
    ) external override {
        if (msg.sender != mToken) {
            revert Lendtroller__Unauthorized();
        }

        _canRedeem(mToken, redeemer, amount);
        _reduceCollateralIfNecessary(
            redeemer,
            mToken,
            balance,
            amount,
            forceRedeemCollateral
        );
    }

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market,
    ///         and notifies the market of the borrow
    /// @dev    This can only be called by the market itself
    /// @param mToken The market to verify the borrow against
    /// @param borrower The account which would borrow the asset
    /// @param amount The amount of underlying the account would borrow
    function canBorrowWithNotify(
        address mToken,
        address borrower,
        uint256 amount
    ) external override {
        if (msg.sender != mToken) {
            revert Lendtroller__Unauthorized();
        }

        accountAssets[borrower].cooldownTimestamp = block.timestamp;
        canBorrow(mToken, borrower, amount);
    }

    /// @notice Checks if the account should be allowed to repay a borrow
    ///         in the given market
    /// @param mToken The market to verify the repay against
    /// @param account The account who will have their loan repaid
    function canRepay(address mToken, address account) external view override {
        if (!tokenData[mToken].isListed) {
            revert Lendtroller__TokenNotListed();
        }

        // We require a `minimumHoldPeriod` to break flashloan manipulations attempts
        // as well as short term price manipulations if the dynamic dual oracle
        // fails to protect the market somehow
        if (
            accountAssets[account].cooldownTimestamp + _MIN_HOLD_PERIOD >
            block.timestamp
        ) {
            revert Lendtroller__MinimumHoldPeriod();
        }
    }

    /// @notice Checks if the liquidation should be allowed to occur,
    ///         and returns how many collateral tokens should be seized on liquidation
    /// @param dToken Debt token to repay which is borrowed by `account`
    /// @param cToken Collateral token which was used as collateral and will be seized
    /// @param account The address of the account to be liquidated
    /// @param amount The amount of `debtToken` underlying being repaid
    /// @param liquidateExact Whether the liquidator desires a specific liquidation amount
    /// @return The amount of `debtToken` underlying to be repaid on liquidation
    /// @return The number of `collateralToken` tokens to be seized in a liquidation
    /// @return The number of `collateralToken` tokens to be seized for the protocol
    function canLiquidateWithExecution(
        address dToken,
        address cToken,
        address account,
        uint256 amount,
        bool liquidateExact
    ) external override returns (uint256, uint256, uint256) {
        if (msg.sender != dToken) {
            revert Lendtroller__Unauthorized();
        }

        (
            uint256 dTokenRepaid,
            uint256 cTokenLiquidated,
            uint256 protocolTokens
        ) = _canLiquidate(dToken, cToken, account, amount, liquidateExact);

        // We can pass balance = 0 here since we are forcing collateral closure
        // and balance will never be lower than collateral posted
        _reduceCollateralIfNecessary(
            account,
            cToken,
            0,
            cTokenLiquidated,
            true
        );
        return (dTokenRepaid, cTokenLiquidated, protocolTokens);
    }

    /// @notice Checks if the liquidation should be allowed to occur,
    ///         and returns how many collateral tokens should be seized on liquidation
    /// @param dToken Debt token to repay which is borrowed by `account`
    /// @param cToken Collateral token collateralized by `account` and will be seized
    /// @param account The address of the account to be liquidated
    /// @param amount The amount of `debtToken` underlying being repaid
    /// @param liquidateExact Whether the liquidator desires a specific liquidation amount
    /// @return The amount of `debtToken` underlying to be repaid on liquidation
    /// @return The number of `collateralToken` tokens to be seized in a liquidation
    /// @return The number of `collateralToken` tokens to be seized for the protocol
    function canLiquidate(
        address dToken,
        address cToken,
        address account,
        uint256 amount,
        bool liquidateExact
    ) external view returns (uint256, uint256, uint256) {
        return _canLiquidate(dToken, cToken, account, amount, liquidateExact);
    }

    /// @notice Checks if the seizing of assets should be allowed to occur
    /// @param collateralToken Asset which was used as collateral
    ///                        and will be seized
    /// @param debtToken Asset which was borrowed by the borrower
    function canSeize(
        address collateralToken,
        address debtToken
    ) external view override {
        if (seizePaused == 2) {
            revert Lendtroller__Paused();
        }

        if (!tokenData[collateralToken].isListed) {
            revert Lendtroller__TokenNotListed();
        }

        if (!tokenData[debtToken].isListed) {
            revert Lendtroller__TokenNotListed();
        }

        if (
            IMToken(collateralToken).lendtroller() !=
            IMToken(debtToken).lendtroller()
        ) {
            revert Lendtroller__LendtrollerMismatch();
        }
    }

    /// @notice Checks if the account should be allowed to transfer tokens
    ///         in the given market
    /// @param mToken The market to verify the transfer against
    /// @param from The account which sources the tokens
    /// @param amount The number of mTokens to transfer
    function canTransfer(
        address mToken,
        address from,
        uint256 amount
    ) external view override {
        if (transferPaused == 2) {
            revert Lendtroller__Paused();
        }

        _canRedeem(mToken, from, amount);
    }

    /// @notice Add the market token to the market and set it as listed
    /// @dev Admin function to set isListed and add support for the market
    /// @param mToken The address of the market (token) to list
    function listToken(address mToken) external onlyElevatedPermissions {
        if (tokenData[mToken].isListed) {
            revert Lendtroller__TokenAlreadyListed();
        }

        IMToken(mToken).isCToken(); // Sanity check to make sure its really a mToken

        MarketToken storage token = tokenData[mToken];
        token.isListed = true;
        token.collRatio = 0;

        uint256 numTokens = tokensListed.length;

        for (uint256 i; i < numTokens; ) {
            unchecked {
                if (tokensListed[i++] == mToken) {
                    revert Lendtroller__TokenAlreadyListed();
                }
            }
        }
        tokensListed.push(mToken);

        // Start the market if necessary
        if (IMToken(mToken).totalSupply() == 0) {
            if (!IMToken(mToken).startMarket(msg.sender)) {
                revert Lendtroller__InvariantError();
            }
        }

        emit TokenListed(mToken);
    }

    /// @notice Sets the collRatio for a market token
    /// @param mToken The market to set the collateralization ratio on
    /// @param collRatio The ratio at which $1 of collateral can be borrowed against,
    ///                               for `mToken`, in basis points
    /// @param collReqA The premium of excess collateral required to avoid soft liquidation, in basis points
    /// @param collReqB The premium of excess collateral required to avoid hard liquidation, in basis points
    /// @param liqIncA The soft liquidation incentive for `mToken`, in basis points
    /// @param liqIncB The hard liquidation incentive for `mToken`, in basis points
    /// @param liqFee The protocol liquidation fee for `mToken`, in basis points
    function updateCollateralToken(
        IMToken mToken,
        uint256 collRatio,
        uint256 collReqA,
        uint256 collReqB,
        uint256 liqIncA,
        uint256 liqIncB,
        uint256 liqFee,
        uint256 baseCFactor
    ) external onlyElevatedPermissions {
        if (!IMToken(mToken).isCToken()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Verify mToken is listed
        MarketToken storage marketToken = tokenData[address(mToken)];
        if (!marketToken.isListed) {
            revert Lendtroller__TokenNotListed();
        }

        // Convert the parameters from basis points to `WAD` format
        // while inefficient we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config
        collRatio = _bpToWad(collRatio);
        collReqA = _bpToWad(collReqA);
        collReqB = _bpToWad(collReqB);
        liqIncA = _bpToWad(liqIncA);
        liqIncB = _bpToWad(liqIncB);
        liqFee = _bpToWad(liqFee);
        baseCFactor = _bpToWad(baseCFactor);

        // Validate collateralization ratio is not above the maximum allowed
        if (collRatio > _MAX_COLLATERALIZATION_RATIO) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that soft liquidation does not lead to full or zero liquidation
        if (baseCFactor > WAD || baseCFactor == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate collateral requirement is not above the maximum allowed
        if (collReqA > _MAX_COLLATERAL_REQUIREMENT) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation requirement is not above the soft liquidation requirement
        if (collReqB > collReqA) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate the soft liquidation collateral premium is not more strict than the asset's CR
        if (collRatio > (WAD * WAD) / (WAD + collReqA)) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate liquidation incentive is not above the maximum allowed
        if (liqIncA > _MAX_LIQUIDATION_INCENTIVE) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation incentive is higher than the soft liquidation incentive
        if (liqIncA > liqIncB) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate protocol liquidation fee is not above the maximum allowed
        if (liqFee > _MAX_LIQUIDATION_FEE) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate collateral requirement is larger than the liquidation incentive
        if (liqIncA > collReqB) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // We need to make sure that the liquidation incentive is sufficient
        // for both the protocol and the users
        if ((liqIncA - liqFee) < _MIN_LIQUIDATION_INCENTIVE) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        (, uint256 errorCode) = IPriceRouter(centralRegistry.priceRouter())
            .getPrice(address(mToken), true, true);

        // Validate that we got a price
        if (errorCode == 2) {
            revert Lendtroller__PriceError();
        }

        // Assign new collateralization ratio
        // Note that a collateralization ratio of 0 corresponds to
        // no collateralization of the mToken
        marketToken.collRatio = collRatio;

        // Store the collateral requirement as a premium above `WAD`,
        // that way we can calculate solvency via division
        // easily in _getStatusForLiquidation
        marketToken.collReqA = collReqA + WAD;
        marketToken.collReqB = collReqB + WAD;

        // Store the distance between liquidation incentive A & B,
        // that way we can quickly scale between [base, 100%] based on lFactor
        marketToken.liqCurve = liqIncB - liqIncA;
        // We use the liquidation incentive values as a premium in
        // `calculateLiquidatedTokens`, so it needs to be 1 + incentive
        marketToken.liqBaseIncentive = WAD + liqIncA;

        // Assign the base cFactor
        marketToken.baseCFactor = baseCFactor;
        // Store the distance between base cFactor and 100%,
        // that way we can quickly scale between [base, 100%] based on lFactor
        marketToken.cFactorCurve = WAD - baseCFactor;

        // We store protocol liquidation fee divided by the soft liquidation
        // incentive offset, that way we can directly multiply later instead
        // of needing extra calculations, we do not want the liquidation fee
        // to increase with the liquidation engine, as we want to offload
        // risk as quickly as possible by increasing the liquidators incentive
        marketToken.liqFee = (WAD * liqFee) / (WAD + liqIncA);

        emit CollateralTokenUpdated(
            mToken,
            collRatio,
            collReqA,
            collReqB,
            liqIncA,
            liqIncB,
            liqFee,
            baseCFactor
        );
    }

    /// @notice Set `newCollateralizationCaps` for the given `mTokens`.
    /// @dev    A collateral cap of 0 corresponds to unlimited collateralization.
    /// @param mTokens The addresses of the markets (tokens) to
    ///                change the borrow caps for
    /// @param newCollateralCaps The new collateral cap values in underlying to be set.
    function setCTokenCollateralCaps(
        address[] calldata mTokens,
        uint256[] calldata newCollateralCaps
    ) external {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            revert Lendtroller__Unauthorized();
        }

        uint256 numTokens = mTokens.length;

        assembly {
            if iszero(numTokens) {
                // store the error selector to location 0x0
                mstore(0x0, _INVALID_PARAMETER_SELECTOR)
                // return bytes 29-32 for the selector
                revert(0x1c, 0x04)
            }
        }

        if (numTokens != newCollateralCaps.length) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        for (uint256 i; i < numTokens; ++i) {
            // Make sure the mToken is a cToken
            if (!IMToken(mTokens[i]).isCToken()) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            // Do not let people collateralize assets
            // with collateralization ratio of 0
            if (tokenData[mTokens[i]].collRatio == 0) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            collateralCaps[mTokens[i]] = newCollateralCaps[i];
            emit NewCollateralCap(mTokens[i], newCollateralCaps[i]);
        }
    }

    /// @notice Returns whether `mToken` is listed in the lending market
    /// @param mToken market token address
    function isListed(address mToken) external view override returns (bool) {
        return (tokenData[mToken].isListed);
    }

    /// @notice Returns if an account has an active position in `mToken`
    /// @param mToken market token address
    /// @param account account address
    function hasPosition(
        address mToken,
        address account
    ) external view override returns (bool) {
        return tokenData[mToken].accountData[account].activePosition == 2;
    }

    /// @notice Admin function to set market mint paused
    /// @dev requires timelock authority if unpausing
    /// @param mToken market token address
    /// @param state pause or unpause
    function setMintPaused(
        address mToken,
        bool state
    ) external onlyAuthorizedPermissions(state) {
        if (!tokenData[mToken].isListed) {
            revert Lendtroller__TokenNotListed();
        }

        mintPaused[mToken] = state ? 2 : 1;
        emit TokenActionPaused(mToken, "Mint Paused", state);
    }

    /// @notice Admin function to set market borrow paused
    /// @dev requires timelock authority if unpausing
    /// @param mToken market token address
    /// @param state pause or unpause
    function setBorrowPaused(
        address mToken,
        bool state
    ) external onlyAuthorizedPermissions(state) {
        if (!tokenData[mToken].isListed) {
            revert Lendtroller__TokenNotListed();
        }

        borrowPaused[mToken] = state ? 2 : 1;
        emit TokenActionPaused(mToken, "Borrow Paused", state);
    }

    /// @notice Admin function to set transfer paused
    /// @dev requires timelock authority if unpausing
    /// @param state pause or unpause
    function setTransferPaused(
        bool state
    ) external onlyAuthorizedPermissions(state) {
        transferPaused = state ? 2 : 1;
        emit ActionPaused("Transfer Paused", state);
    }

    /// @notice Admin function to set seize paused
    /// @dev requires timelock authority if unpausing
    /// @param state pause or unpause
    function setSeizePaused(
        bool state
    ) external onlyAuthorizedPermissions(state) {
        seizePaused = state ? 2 : 1;
        emit ActionPaused("Seize Paused", state);
    }

    /// @notice Admin function to set position folding address
    /// @param newPositionFolding new position folding address
    function setPositionFolding(
        address newPositionFolding
    ) external onlyElevatedPermissions {
        if (
            !ERC165Checker.supportsInterface(
                newPositionFolding,
                type(IPositionFolding).interfaceId
            )
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Cache the current value for event log
        address oldPositionFolding = positionFolding;

        // Assign new position folding contract
        positionFolding = newPositionFolding;

        emit NewPositionFoldingContract(
            oldPositionFolding,
            newPositionFolding
        );
    }

    function reduceCollateralIfNecessary(
        address account,
        address mToken,
        uint256 balance,
        uint256 amount
    ) external override {
        if (msg.sender != mToken) {
            revert Lendtroller__Unauthorized();
        }

        _reduceCollateralIfNecessary(account, mToken, balance, amount, false);
    }

    /// @notice Updates `borrower` cooldownTimestamp to the current block timestamp
    /// @dev The caller must be a listed MToken in the `markets` mapping
    /// @param mToken   The address of the dToken that the account is borrowing
    /// @param borrower The address of the account that has just borrowed
    function notifyBorrow(address mToken, address borrower) external override {
        if (msg.sender != mToken) {
            revert Lendtroller__Unauthorized();
        }

        accountAssets[borrower].cooldownTimestamp = block.timestamp;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market
    /// @param mToken The market to verify the borrow against
    /// @param borrower The account which would borrow the asset
    /// @param amount The amount of underlying the account would borrow
    function canBorrow(
        address mToken,
        address borrower,
        uint256 amount
    ) public override {
        if (borrowPaused[mToken] == 2) {
            revert Lendtroller__Paused();
        }

        if (!tokenData[mToken].isListed) {
            revert Lendtroller__TokenNotListed();
        }

        if (tokenData[mToken].accountData[borrower].activePosition < 2) {
            // only mTokens may call borrowAllowed if borrower not in market
            if (msg.sender != mToken) {
                revert Lendtroller__Unauthorized();
            }

            // The account is not in the market yet, so make them enter
            tokenData[mToken].accountData[borrower].activePosition = 2;
            accountAssets[borrower].assets.push(IMToken(mToken));

            emit TokenPositionCreated(mToken, borrower);
        }

        // Check if the user has sufficient liquidity to borrow,
        // with heavier error code scrutiny
        (, uint256 liquidityDeficit) = _getHypotheticalLiquidity(
            borrower,
            IMToken(mToken),
            0,
            amount,
            1
        );

        if (liquidityDeficit > 0) {
            revert Lendtroller__InsufficientLiquidity();
        }
    }

    /// Liquidity/Liquidation Calculations

    /// @notice Determine `account`'s current status between collateral,
    ///         debt, and additional liquidity
    /// @param account The account to determine liquidity for
    /// @return accountCollateral total collateral amount of account
    /// @return maxDebt max borrow amount of account
    /// @return currentDebt total borrow amount of account
    function getStatus(
        address account
    )
        public
        view
        returns (
            uint256 accountCollateral,
            uint256 maxDebt,
            uint256 currentDebt
        )
    {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = _getAssetData(account, 2);
        AccountSnapshot memory snapshot;

        for (uint256 i; i < numAssets; ) {
            snapshot = snapshots[i];

            if (snapshot.isCToken) {
                // If the asset has a CR increment their collateral and max borrow value
                if (!(tokenData[snapshot.asset].collRatio == 0)) {
                    (accountCollateral, maxDebt) = _addCollateralValue(
                        snapshot,
                        account,
                        underlyingPrices[i],
                        accountCollateral,
                        maxDebt
                    );
                }
            } else {
                // If they have a debt balance we need to document it
                if (snapshot.debtBalance > 0) {
                    currentDebt += _getAssetValue(
                        snapshot.debtBalance,
                        underlyingPrices[i],
                        snapshot.decimals
                    );
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Determine whether `account` can currently be liquidated in this market
    /// @param account The account to check for liquidation flag
    /// @dev Note that we calculate the exchangeRateStored for each collateral
    ///           mToken using stored data, without calculating accumulated interest.
    /// @return Whether `account` can be liquidated currently
    function flaggedForLiquidation(
        address account
    ) internal view returns (bool) {
        LiqData memory data = _getStatusForLiquidation(
            account,
            address(0),
            address(0)
        );
        return data.lFactor > 0;
    }

    /// @notice Determine what the account liquidity would be if
    ///         the given amounts were redeemed/borrowed
    /// @param mTokenModified The market to hypothetically redeem/borrow in
    /// @param account The account to determine liquidity for
    /// @param redeemTokens The number of tokens to hypothetically redeem
    /// @param borrowAmount The amount of underlying to hypothetically borrow
    /// @return uint256 hypothetical account liquidity in excess of collateral requirements
    /// @return uint256 hypothetical account liquidity deficit below collateral requirements
    function getHypotheticalLiquidity(
        address account,
        address mTokenModified,
        uint256 redeemTokens, // in shares
        uint256 borrowAmount // in assets
    ) public view returns (uint256, uint256) {
        return
            _getHypotheticalLiquidity(
                account,
                IMToken(mTokenModified),
                redeemTokens,
                borrowAmount,
                2
            );
    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(ILendtroller).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    function _postCollateral(
        address account,
        AccountMetadata storage accountData,
        address mToken,
        uint256 amount
    ) internal {
        if (collateralPosted[mToken] + amount > collateralCaps[mToken]) {
            revert Lendtroller__CollateralCapReached();
        }

        // On collateral posting:
        // we need to flip their cooldown flag to prevent any flashloan attempts
        accountAssets[account].cooldownTimestamp = block.timestamp;
        collateralPosted[mToken] = collateralPosted[mToken] + amount;
        accountData.collateralPosted = accountData.collateralPosted + amount;
        emit CollateralPosted(account, mToken, amount);

        // If the account does not have a position in this token, open one
        if (accountData.activePosition != 2) {
            accountData.activePosition = 2;
            accountAssets[account].assets.push(IMToken(mToken));

            emit TokenPositionCreated(mToken, account);
        }
    }

    function _removeCollateral(
        address account,
        AccountMetadata storage accountData,
        address mToken,
        uint256 amount,
        bool closePositionIfPossible
    ) internal {
        accountData.collateralPosted = accountData.collateralPosted - amount;
        collateralPosted[mToken] = collateralPosted[mToken] - amount;
        emit CollateralRemoved(account, mToken, amount);

        if (closePositionIfPossible && accountData.collateralPosted == 0) {
            _closePosition(account, accountData, IMToken(mToken));
        }
    }

    function _closePosition(
        address account,
        AccountMetadata storage accountData,
        IMToken token
    ) internal {
        // Remove `token` account position flag
        accountData.activePosition = 1;

        // Delete token from the account’s list of assets
        IMToken[] memory userAssetList = accountAssets[account].assets;

        // Cache asset list
        uint256 numUserAssets = userAssetList.length;
        uint256 assetIndex = numUserAssets;

        for (uint256 i; i < numUserAssets; ++i) {
            if (userAssetList[i] == token) {
                assetIndex = i;
                break;
            }
        }

        // Validate we found the asset and remove 1 from numUserAssets
        // so it corresponds to last element index now starting at index 0
        if (assetIndex >= numUserAssets--) {
            revert Lendtroller__InvariantError();
        }

        // copy last item in list to location of item to be removed
        IMToken[] storage storedList = accountAssets[account].assets;
        // copy the last market index slot to assetIndex
        storedList[assetIndex] = storedList[numUserAssets];
        // remove the last element to remove `token` from account asset list
        storedList.pop();

        emit TokenPositionClosed(address(token), account);
    }

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market
    /// @param mToken The market to verify the redeem against
    /// @param redeemer The account which would redeem the tokens
    /// @param amount The number of `mToken` to redeem for
    ///               the underlying asset in the market
    function _canRedeem(
        address mToken,
        address redeemer,
        uint256 amount
    ) internal view {
        if (!tokenData[mToken].isListed) {
            revert Lendtroller__TokenNotListed();
        }

        // We require a `minimumHoldPeriod` to break flashloan manipulations attempts
        // as well as short term price manipulations if the dynamic dual oracle
        // fails to protect the market somehow
        if (
            accountAssets[redeemer].cooldownTimestamp + _MIN_HOLD_PERIOD >
            block.timestamp
        ) {
            revert Lendtroller__MinimumHoldPeriod();
        }

        // If the redeemer does not have an active position in the token,
        // then we can bypass the liquidity check
        if (tokenData[mToken].accountData[redeemer].activePosition < 2) {
            return;
        }

        // Check account liquidity with hypothetical redemption
        (, uint256 liquidityDeficit) = _getHypotheticalLiquidity(
            redeemer,
            IMToken(mToken),
            amount,
            0,
            2
        );

        if (liquidityDeficit > 0) {
            revert Lendtroller__InsufficientLiquidity();
        }
    }

    /// @notice Checks if the liquidation should be allowed to occur
    /// @param debtToken Asset which was borrowed by the borrower
    /// @param collateralToken Asset which was used as collateral and will be seized
    /// @param account The address of the account to be liquidated
    /// @return The maximum amount of `debtToken` that can be repaid during liquidation
    /// @return Current price for `debtToken`
    /// @return Current price for `collateralToken`
    function _canLiquidate(
        address debtToken,
        address collateralToken,
        address account,
        uint256 amount,
        bool liquidateExact
    ) internal view returns (uint256, uint256, uint256) {
        if (!tokenData[debtToken].isListed) {
            revert Lendtroller__TokenNotListed();
        }

        MarketToken storage cToken = tokenData[collateralToken];

        if (!cToken.isListed) {
            revert Lendtroller__TokenNotListed();
        }

        // Do not let people liquidate 0 collateralization ratio assets
        if (cToken.collRatio == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Calculate the users lFactor
        LiqData memory data = _getStatusForLiquidation(
            account,
            debtToken,
            collateralToken
        );

        if (data.lFactor == 0) {
            revert Lendtroller__NoLiquidationAvailable();
        }

        uint256 maxAmount;
        uint256 debtToCollateralRatio;
        {
            uint256 cFactor = cToken.baseCFactor +
                ((cToken.cFactorCurve * data.lFactor) / WAD);
            uint256 incentive = cToken.liqBaseIncentive +
                ((cToken.liqCurve * data.lFactor) / WAD);
            maxAmount =
                (cFactor * IMToken(debtToken).debtBalanceStored(account)) /
                WAD;

            // Get the exchange rate and calculate the number of collateral tokens to seize:
            debtToCollateralRatio =
                (incentive * data.debtTokenPrice * WAD) /
                (data.collateralTokenPrice *
                    IMToken(collateralToken).exchangeRateStored());
        }

        if (!liquidateExact) {
            amount = maxAmount;
        }

        uint256 amountAdjusted = (amount *
            (10 ** IERC20(collateralToken).decimals())) /
            (10 ** IERC20(debtToken).decimals());
        uint256 liquidatedTokens = (amountAdjusted * debtToCollateralRatio) /
            WAD;

        uint256 collateralAvailable = cToken
            .accountData[account]
            .collateralPosted;
        if (liquidateExact) {
            if (amount > maxAmount || liquidatedTokens > collateralAvailable) {
                // Make sure that the liquidation limit and collateral posted >= amount
                _revert(_INVALID_PARAMETER_SELECTOR);
            }
        } else {
            if (liquidatedTokens > collateralAvailable) {
                amount =
                    (amount * collateralAvailable) /
                    liquidatedTokens;
                liquidatedTokens = collateralAvailable;
            }
        }

        // Calculate the maximum amount of debt that can be liquidated
        // and what collateral will be received
        return (
            amount,
            liquidatedTokens,
            (liquidatedTokens * cToken.liqFee) / WAD
        );
    }

    /// @notice Determine what the account status if an action were done (redeem/borrow)
    /// @param account The account to determine hypothetical status for
    /// @param mTokenModified The market to hypothetically redeem/borrow in
    /// @param redeemTokens The number of tokens to hypothetically redeem
    /// @param borrowAmount The amount of underlying to hypothetically borrow
    /// @param errorCodeBreakpoint The error code that will cause liquidity operations to revert
    /// @dev Note that we calculate the exchangeRateStored for each collateral
    ///           mToken using stored data, without calculating accumulated interest.
    /// @return accountCollateral The total market value of `account`'s collateral
    /// @return maxDebt Maximum amount `account` can borrow versus current collateral
    /// @return newDebt The new debt of `account` after the hypothetical action
    function _getHypotheticalStatus(
        address account,
        IMToken mTokenModified,
        uint256 redeemTokens, // in shares
        uint256 borrowAmount, // in assets
        uint256 errorCodeBreakpoint
    )
        internal
        view
        returns (uint256 accountCollateral, uint256 maxDebt, uint256 newDebt)
    {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = _getAssetData(account, errorCodeBreakpoint);
        AccountSnapshot memory snapshot;

        for (uint256 i; i < numAssets; ) {
            snapshot = snapshots[i];

            if (snapshot.isCToken) {
                // If the asset has a Collateral Ratio,
                // increment their collateral and max borrow value
                if (!(tokenData[snapshot.asset].collRatio == 0)) {
                    (accountCollateral, maxDebt) = _addCollateralValue(
                        snapshot,
                        account,
                        underlyingPrices[i],
                        accountCollateral,
                        maxDebt
                    );
                }
            } else {
                // If they have a borrow balance we need to document it
                if (snapshot.debtBalance > 0) {
                    newDebt += _getAssetValue(
                        snapshot.debtBalance,
                        underlyingPrices[i],
                        snapshot.decimals
                    );
                }
            }

            // Calculate effects of interacting with mTokenModified
            if (IMToken(snapshot.asset) == mTokenModified) {
                // If its a CToken our only option is to redeem it since it cant be borrowed
                // If its a DToken we can redeem it but it will not have any effect on borrow amount
                // since DToken have a collateral value of 0
                if (snapshot.isCToken) {
                    if (!(tokenData[snapshot.asset].collRatio == 0)) {
                        uint256 collateralValue = _getAssetValue(
                            (redeemTokens * snapshot.exchangeRate) / WAD,
                            underlyingPrices[i],
                            snapshot.decimals
                        );

                        // hypothetical redemption
                        newDebt += ((collateralValue *
                            tokenData[snapshot.asset].collRatio) / WAD);
                    }
                } else {
                    // hypothetical borrow
                    newDebt += _getAssetValue(
                        borrowAmount,
                        underlyingPrices[i],
                        snapshot.decimals
                    );
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Determine what `account`'s liquidity would be if
    ///         `mTokenModified` were redeemed or borrowed.
    /// @param account The account to determine liquidity for.
    /// @param mTokenModified The mToken to hypothetically redeem/borrow.
    /// @param redeemTokens The number of tokens to hypothetically redeem.
    /// @param borrowAmount The amount of underlying to hypothetically borrow.
    /// @param errorCodeBreakpoint The error code that will cause liquidity operations to revert.
    /// @dev Note that we calculate the exchangeRateStored for each collateral
    ///           mToken using stored data, without calculating accumulated interest.
    /// @return uint256 Hypothetical `account` excess liquidity versus collateral requirements.
    /// @return uint256 Hypothetical `account` liquidity deficit below collateral requirements.
    function _getHypotheticalLiquidity(
        address account,
        IMToken mTokenModified,
        uint256 redeemTokens, // in shares
        uint256 borrowAmount, // in assets
        uint256 errorCodeBreakpoint
    ) internal view returns (uint256, uint256) {
        (, uint256 maxDebt, uint256 newDebt) = _getHypotheticalStatus(
            account,
            mTokenModified,
            redeemTokens,
            borrowAmount,
            errorCodeBreakpoint
        );

        // These will not underflow/overflow as condition is checked prior
        if (maxDebt > newDebt) {
            unchecked {
                return (maxDebt - newDebt, 0);
            }
        }

        unchecked {
            return (0, newDebt - maxDebt);
        }
    }

    /// @notice Determine whether `account` can be liquidated,
    ///         by calculating their lFactor, based on their
    ///         collateral versus outstanding debt
    /// @param account The account to check liquidation status for
    /// @param debtToken The dToken to be repaid during potential liquidation
    /// @param collateralToken The cToken to be seized during potential liquidation
    /// @return result Containing values:
    ///                Current `account` lFactor
    ///                Current price for `debtToken`
    ///                Current price for `collateralToken`
    function _getStatusForLiquidation(
        address account,
        address debtToken,
        address collateralToken
    ) internal view returns (LiqData memory result) {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = _getAssetData(account, 2);
        AccountSnapshot memory snapshot;
        // Collateral value for soft liquidation level
        uint256 accountCollateralA;
        // Collateral value for hard liquidation level
        uint256 accountCollateralB;
        // Current outstanding account debt
        uint256 accountDebt;

        for (uint256 i; i < numAssets; ) {
            snapshot = snapshots[i];

            if (snapshot.isCToken) {
                if (snapshot.asset == collateralToken) {
                    result.collateralTokenPrice = underlyingPrices[i];
                }

                // If the asset has a CR increment their collateral
                if (!(tokenData[snapshot.asset].collRatio == 0)) {
                    (
                        accountCollateralA,
                        accountCollateralB
                    ) = _addLiquidationValues(
                        snapshot,
                        account,
                        underlyingPrices[i],
                        accountCollateralA,
                        accountCollateralB
                    );
                }
            } else {
                if (snapshot.asset == debtToken) {
                    result.debtTokenPrice = underlyingPrices[i];
                }

                // If they have a debt balance,
                // we need to document collateral requirements
                if (snapshot.debtBalance > 0) {
                    accountDebt += _getAssetValue(
                        snapshot.debtBalance,
                        underlyingPrices[i],
                        snapshot.decimals
                    );
                }
            }

            unchecked {
                ++i;
            }
        }

        if (accountCollateralA >= accountDebt) {
            return result;
        }

        result.lFactor = _getPositiveCurveResult(
            accountDebt,
            accountCollateralA,
            accountCollateralB
        );
    }

    /// @notice Retrieves the prices and account data of multiple assets inside this market.
    /// @param account The account to retrieve data for.
    /// @param errorCodeBreakpoint The error code that will cause liquidity operations to revert.
    /// @return AccountSnapshot[] Contains assets data for `account`.
    /// @return uint256[] Contains prices for `account` assets.
    /// @return uint256 The number of assets `account` is in.
    function _getAssetData(
        address account,
        uint256 errorCodeBreakpoint
    )
        internal
        view
        returns (AccountSnapshot[] memory, uint256[] memory, uint256)
    {
        return
            IPriceRouter(centralRegistry.priceRouter()).getPricesForMarket(
                account,
                accountAssets[account].assets,
                errorCodeBreakpoint
            );
    }

    function _getAssetValue(
        uint256 amount,
        uint256 price,
        uint256 decimals
    ) internal pure returns (uint256) {
        return (amount * price) / (10 ** decimals);
    }

    function _addLiquidationValues(
        AccountSnapshot memory snapshot,
        address account,
        uint256 price,
        uint256 softLiquidationSumPrior,
        uint256 hardLiquidationSumPrior
    ) internal view returns (uint256, uint256) {
        uint256 assetValue = _getAssetValue(
            ((tokenData[snapshot.asset].accountData[account].collateralPosted *
                snapshot.exchangeRate) / WAD),
            price,
            snapshot.decimals
        ) * WAD;

        return (
            softLiquidationSumPrior +
                (assetValue / tokenData[snapshot.asset].collReqA),
            hardLiquidationSumPrior +
                (assetValue / tokenData[snapshot.asset].collReqB)
        );
    }

    function _addCollateralValue(
        AccountSnapshot memory snapshot,
        address account,
        uint256 price,
        uint256 previousCollateral,
        uint256 previousBorrow
    ) internal view returns (uint256, uint256) {
        uint256 assetValue = _getAssetValue(
            ((tokenData[snapshot.asset].accountData[account].collateralPosted *
                snapshot.exchangeRate) / WAD),
            price,
            snapshot.decimals
        );
        return (
            previousCollateral + assetValue,
            previousBorrow +
                (assetValue * tokenData[snapshot.asset].collRatio) /
                WAD
        );
    }

    /// @notice Calculates a positive curve value based on `current`,
    ///         `start`, and `end` values.
    /// @dev The function scales current, start, and end values by `WAD`
    ///      to maintain precision. It returns 1, (in `WAD`) if the
    ///      current value is greater than or equal to `end`. The formula
    ///      used is (current - start) / (end - start), ensuring the result
    ///      is scaled properly.
    /// @param current The current value, representing a point on the curve.
    /// @param start The start value of the curve, marking the beginning of
    ///              the calculation range.
    /// @param end The end value of the curve, marking the end of the
    ///            calculation range.
    /// @return The calculated positive curve value, a proportion between
    ///         the start and end points.
    function _getPositiveCurveResult(
        uint256 current,
        uint256 start,
        uint256 end
    ) internal pure returns (uint256) {
        if (current >= end) {
            return WAD;
        }
        return ((current - start) * WAD) / (end - start);
    }

    function _reduceCollateralIfNecessary(
        address account,
        address mToken,
        uint256 balance,
        uint256 amount,
        bool forceReduce
    ) internal {
        AccountMetadata storage accountData = tokenData[mToken].accountData[
            account
        ];
        if (forceReduce) {
            _removeCollateral(account, accountData, mToken, amount, false);
            return;
        }

        uint256 balanceRequired = accountData.collateralPosted + amount;

        if (balance < balanceRequired) {
            _removeCollateral(
                account,
                accountData,
                mToken,
                balanceRequired - balance,
                false
            );
        }
    }

    /// @dev Internal helper function for easily converting between scalars
    function _bpToWad(uint256 value) internal pure returns (uint256 result) {
        assembly {
            result := mul(value, 100000000000000)
        }
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }
}
