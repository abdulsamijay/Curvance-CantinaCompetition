// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract DynamicInterestRateModel {
    /// TYPES ///

    struct RatesConfiguration {
        /// @notice Base rate at which interest is accumulated, per compound.
        uint256 baseInterestRate;
        /// @notice Vertex rate at which interest is accumulated, per compound.
        uint256 vertexInterestRate;
        /// @notice Utilization rate point where vertex rate is used,
        ///         instead of base rate.
        uint256 vertexStartingPoint;
        /// @notice The rate at which the vertex multiplier is adjusted,
        ///         in seconds.
        uint256 adjustmentRate;
        /// @notice The maximum rate at with the vertex multiplier is adjusted,
        ///         in `WAD`.
        uint256 adjustmentVelocity;
        /// @notice The maximum value that vertexMultiplier can be.
        uint256 vertexMultiplierMax;
        /// @notice Rate at which the vertex multiplier will decay per update,
        ///         in `WAD`.
        uint256 decayRate;
        /// @notice The utilization rate at which the vertex multiplier
        ///         will begin to increase.
        uint256 increaseThreshold;
        /// @notice The utilization rate at which the vertex multiplier
        ///         positive velocity will max out.
        uint256 increaseThresholdMax;
        /// @notice The utilization rate at which the vertex multiplier
        ///         will begin to decrease.
        uint256 decreaseThreshold;
        /// @notice The utilization rate at which the vertex multiplier
        ///         negative velocity will max out.
        uint256 decreaseThresholdMax;
    }

    /// CONSTANTS ///

    /// @notice For external contract's to call for validation.
    bool public constant IS_INTEREST_RATE_MODEL = true;
    /// @notice Rate at which interest is compounded, in seconds.
    uint256 public constant INTEREST_COMPOUND_RATE = 600;
    /// @notice Maximum Rate at which the vertex multiplier will
    ///         decay per adjustment, in `WAD`.
    uint256 public constant MAX_VERTEX_DECAY_RATE = .05e18; // 5%.
    /// @notice The maximum frequency in which the vertex can have
    ///         between adjustments. It is important that this value is not
    ///         too high as users could in theory borrow a ton of assets
    ///         right before adjustment shifts, artificially increasing rates.
    uint256 public constant MAX_VERTEX_ADJUSTMENT_RATE = 12 hours;
    /// @notice The minimum frequency in which the vertex can have
    ///         between adjustments.
    uint256 public constant MIN_VERTEX_ADJUSTMENT_RATE = 1 hours;
    /// @notice The maximum rate at with the vertex multiplier is adjusted,
    ///         in WAD on top of base rate (1 `WAD`).
    ///         E.g. 3 * WAD = triples vertex interest rate per adjustment
    ///         at 100% utilization.
    uint256 public constant MAX_VERTEX_ADJUSTMENT_VELOCITY = 3 * WAD;
    /// @notice The minimum rate at with the vertex multiplier is adjusted,
    ///         in WAD on top of base rate (1 `WAD`).
    ///         E.g. 1.5 * WAD = 50% increase to vertex interest rate per
    ///         adjustment at 100% utilization.
    uint256 public constant MIN_VERTEX_ADJUSTMENT_VELOCITY = 1.5e18;

    /// @notice Unix time has 31,536,000 seconds per year.
    ///         All my homies hate leap seconds and leap years.
    uint256 internal constant _SECONDS_PER_YEAR = 31_536_000;
    /// @notice Mask of `vertexMultiplier` in `_currentRates`.
    uint256 internal constant _BITMASK_VERTEX_MULTIPLIER = (1 << 192) - 1;
    /// @notice Mask of `nextUpdateTimestamp` in `_currentRates`.
    uint256 internal constant _BITMASK_UPDATE_TIMESTAMP = (1 << 64) - 1;
    /// @notice The bit position of `nextUpdateTimestamp` in `_currentRates`.
    uint256 internal constant _BITPOS_UPDATE_TIMESTAMP = 192;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice Struct containing current configuration data for the
    ///         dynamic interest rate model.
    RatesConfiguration public ratesConfig;
    /// Internal stored rates data.
    /// Bits Layout:
    /// - [0..191]    `vertexMultiplier`.
    /// - [192..255] `nextUpdateTimestamp`.
    uint256 internal _currentRates;

    /// EVENTS ///

    event NewDynamicInterestRateModel(
        uint256 baseInterestRate,
        uint256 vertexInterestRate,
        uint256 vertexStartingPoint,
        uint256 adjustmentRate,
        uint256 adjustmentVelocity,
        uint256 vertexMultiplierMax,
        uint256 decayRate,
        uint256 increaseThreshold,
        uint256 increaseThresholdMax,
        uint256 decreaseThreshold,
        uint256 decreaseThresholdMax,
        bool vertexReset
    );

    /// ERRORS ///

    error DynamicInterestRateModel__Unauthorized();
    error DynamicInterestRateModel__InvalidCentralRegistry();
    error DynamicInterestRateModel__InvalidAdjustmentRate();
    error DynamicInterestRateModel__InvalidAdjustmentVelocity();
    error DynamicInterestRateModel__InvalidDecayRate();
    error DynamicInterestRateModel__InvalidMultiplierMax();

    /// CONSTRUCTOR ///

    /// @param baseRatePerYear The rate of increase in interest rate by
    ///                        utilization rate, in `basis points`.
    /// @param vertexRatePerYear The rate of increase in interest rate by
    ///                          utilization rate after `vertexUtilizationStart`,
    ///                          in `basis points`.
    /// @param vertexUtilizationStart The utilization point at which the vertex
    ///                               rate is applied, in `basis points`.
    /// @param adjustmentRate The rate at which the vertex multiplier is adjusted,
    ///                             in `seconds`.
    /// @param adjustmentVelocity The maximum rate at with the vertex multiplier
    ///                           is adjusted, in `basis points`.
    /// @param vertexMultiplierMax The maximum value that vertexMultiplier can be.
    /// @param decayRate Rate at which the vertex multiplier will decay per update,
    ///                  in `basis points`.
    constructor(
        ICentralRegistry centralRegistry_,
        uint256 baseRatePerYear,
        uint256 vertexRatePerYear,
        uint256 vertexUtilizationStart,
        uint256 adjustmentRate,
        uint256 adjustmentVelocity,
        uint256 vertexMultiplierMax,
        uint256 decayRate
    ) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert DynamicInterestRateModel__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;

        _updateDynamicInterestRateModel(
            baseRatePerYear,
            vertexRatePerYear,
            vertexUtilizationStart,
            adjustmentRate,
            adjustmentVelocity,
            vertexMultiplierMax,
            decayRate,
            true
        );
    }

    /// EXTERNAL FUNCTIONS ///

    /// @param baseRatePerYear The rate of increase in interest rate by
    ///                        utilization rate, in `basis points`.
    /// @param vertexRatePerYear The rate of increase in interest rate by
    ///                          utilization rate after `vertexUtilizationStart`,
    ///                          in `basis points`.
    /// @param vertexUtilizationStart The utilization point at which the vertex
    ///                               rate is applied, in `basis points`.
    /// @param adjustmentRate The rate at which the vertex multiplier is adjusted,
    ///                             in `seconds`.
    /// @param adjustmentVelocity The maximum rate at with the vertex multiplier
    ///                           is adjusted, in `basis points`.
    /// @param vertexMultiplierMax The maximum value that vertexMultiplier can be.
    /// @param decayRate Rate at which the vertex multiplier will decay per update,
    ///                  in `basis points`.
    /// @param vertexReset Whether the vertex multiplier should be reset back to
    ///                    its default value.
    function updateDynamicInterestRateModel(
        uint256 baseRatePerYear,
        uint256 vertexRatePerYear,
        uint256 vertexUtilizationStart,
        uint256 adjustmentRate,
        uint256 adjustmentVelocity,
        uint256 vertexMultiplierMax,
        uint256 decayRate,
        bool vertexReset
    ) external {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert DynamicInterestRateModel__Unauthorized();
        }

        _updateDynamicInterestRateModel(
            baseRatePerYear,
            vertexRatePerYear,
            vertexUtilizationStart,
            adjustmentRate,
            adjustmentVelocity,
            vertexMultiplierMax,
            decayRate,
            vertexReset
        );
    }

    /// @notice Calculates the current borrow rate per year.
    /// @param cash The amount of cash in the market.
    /// @param borrows The amount of borrows in the market.
    /// @param reserves The amount of reserves in the market.
    /// @return The borrow rate percentage per year, in `WAD`.
    function getBorrowRatePerYear(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) external view returns (uint256) {
        return
            _SECONDS_PER_YEAR *
            (getBorrowRate(cash, borrows, reserves) / INTEREST_COMPOUND_RATE);
    }

    /// @notice Calculates the current supply rate per year.
    /// @param cash The amount of cash in the market.
    /// @param borrows The amount of borrows in the market.
    /// @param reserves The amount of reserves in the market.
    /// @param interestFee The current interest rate reserve factor
    ///                    for the market.
    /// @return The supply rate percentage per year, in `WAD`.
    function getSupplyRatePerYear(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 interestFee
    ) external view returns (uint256) {
        return
            _SECONDS_PER_YEAR *
            (getSupplyRate(cash, borrows, reserves, interestFee) /
                INTEREST_COMPOUND_RATE);
    }

    /// @notice Returns the rate at which interest compounds, in seconds.
    function compoundRate() external pure returns (uint256) {
        return INTEREST_COMPOUND_RATE;
    }

    /// @notice Returns the unpacked `DynamicRatesData` struct 
    ///         from `_currentRates`.
    /// @return Current rates data in unpacked `DynamicRatesData` struct.
    function currentRatesData() external view returns (uint256, uint256) {
        uint256 currentRates = _currentRates;
        return (
            uint192(currentRates),
            uint64(currentRates >> _BITPOS_UPDATE_TIMESTAMP)
        );
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Calculates the utilization rate of the market:
    ///         `borrows / (cash + borrows - reserves)`.
    /// @param cash The amount of cash in the market.
    /// @param borrows The amount of borrows in the market.
    /// @param reserves The amount of reserves in the market.
    /// @return The utilization rate between [0, WAD].
    function utilizationRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public pure returns (uint256) {
        // Utilization rate is 0 when there are no borrows.
        if (borrows == 0) {
            return 0;
        }

        return (borrows * WAD) / (cash + borrows - reserves);
    }

    /// @notice Calculates the current borrow rate per compound,
    ///          and updates the vertex multiplier if necessary.
    /// @param cash The amount of cash in the market.
    /// @param borrows The amount of borrows in the market.
    /// @param reserves The amount of reserves in the market.
    /// @return borrowRate The borrow rate percentage per compound, in `WAD`.
    function getBorrowRateWithUpdate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public returns (uint256 borrowRate) {
        uint256 util = utilizationRate(cash, borrows, reserves);
        RatesConfiguration memory config = ratesConfig;
        uint256 vertexPoint = config.vertexStartingPoint;

        bool belowVertex = (util <= vertexPoint);

        if (belowVertex) {
            unchecked {
                borrowRate = getBaseInterestRate(util);
            }
        } else {
            /// We know this will not underflow or overflow,
            /// because of Interest Rate Model configurations.
            unchecked {
                borrowRate = (getVertexInterestRate(util - vertexPoint) +
                    getBaseInterestRate(vertexPoint));
            }
        }
        if (block.timestamp >= updateTimestamp()) {
            // If the vertex multiplier is already at its minimum,
            // and would decrease more, can break here.
            if (vertexMultiplier() == WAD && util < config.increaseThreshold) {
                _setUpdateTimestamp(
                    uint64(block.timestamp + config.adjustmentRate)
                );
                return borrowRate;
            }

            if (belowVertex) {
                _currentRates = _packRatesData(
                    _updateForBelowVertex(config, util),
                    uint64(block.timestamp + config.adjustmentRate)
                );
                return borrowRate;
            }

            _currentRates = _packRatesData(
                _updateForAboveVertex(config, util),
                uint64(block.timestamp + config.adjustmentRate)
            );
        }
    }

    /// @notice Calculates the current borrow rate, per compound.
    /// @param cash The amount of cash in the market.
    /// @param borrows The amount of borrows in the market.
    /// @param reserves The amount of reserves in the market.
    /// @return The borrow rate percentage, per compound, in `WAD`.
    function getBorrowRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public view returns (uint256) {
        uint256 util = utilizationRate(cash, borrows, reserves);
        uint256 vertexPoint = ratesConfig.vertexStartingPoint;

        if (util <= vertexPoint) {
            unchecked {
                return getBaseInterestRate(util);
            }
        }

        /// We know this will not underflow or overflow,
        /// because of Interest Rate Model configurations.
        unchecked {
            return (getVertexInterestRate(util - vertexPoint) +
                getBaseInterestRate(vertexPoint));
        }
    }

    /// @notice Calculates the current supply rate, per compound.
    /// @param cash The amount of cash in the market.
    /// @param borrows The amount of borrows in the market.
    /// @param reserves The amount of reserves in the market.
    /// @param interestFee The current interest rate reserve factor
    ///                    for the market.
    /// @return The supply rate percentage, per compound, in `WAD`.
    function getSupplyRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 interestFee
    ) public view returns (uint256) {
        /// RateToPool = (borrowRate * oneMinusReserveFactor) / WAD.
        uint256 rateToPool = (getBorrowRate(cash, borrows, reserves) *
            (WAD - interestFee)) / WAD;

        /// Supply Rate = (utilizationRate * rateToPool) / WAD;
        return (utilizationRate(cash, borrows, reserves) * rateToPool) / WAD;
    }

    /// @notice Returns the multiplier applied to the vertex interest rate,
    ///         in `WAD`.
    function vertexMultiplier() public view returns (uint256) {
        return _currentRates & _BITMASK_VERTEX_MULTIPLIER;
    }

    /// @notice Returns the next timestamp when `vertexMultiplier` 
    ///        will be updated.
    function updateTimestamp() public view returns (uint256) {
        return uint64(_currentRates >> _BITPOS_UPDATE_TIMESTAMP);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Calculates the interest rate for `util` market utilization.
    /// @param util The utilization rate of the market.
    /// @return Returns the calculated interest rate, in `WAD`.
    function getBaseInterestRate(
        uint256 util
    ) internal view returns (uint256) {
        return (util * ratesConfig.baseInterestRate) / WAD;
    }

    /// @notice Calculates the interest rate under `vertexInterestRate`
    ///         conditions, e.g. `util` > `vertex ` based on market utilization.
    /// @param util The utilization rate of the market above `vertexStartingPoint`.
    /// @return Returns the calculated interest rate, in `WAD`.
    function getVertexInterestRate(
        uint256 util
    ) internal view returns (uint256) {
        // We divide by 1e36 since we need to divide by WAD twice for proper
        // precision and can optimize by using a precalculated constant.
        return
            (util * ratesConfig.vertexInterestRate * vertexMultiplier()) /
            WAD_SQUARED;
    }

    /// @notice Calculates and returns the updated multiplier for scenarios
    ///         where the utilization rate is below the vertex.
    /// @dev This function is used to adjust the vertex multiplier based on
    ///      the dToken's current borrow utilization.
    ///      A decay mechanism is incorporated to gradually decrease the
    ///      multiplier, and ensures the multiplier does not fall below 1 (in WAD).
    ///      NOTE: The multiplier is updated with the following logic:
    ///      If the utilization is below the 'decreaseThresholdMax',
    ///      decay rate and maximum adjustment velocity is applied.
    ///      For higher utilizations (but still below the vertex),
    ///      a new multiplier is calculated by applying a negative curve value
    ///      to the adjustment. This new multiplier is also subjected to the
    ///      decay multiplier.
    /// @param config The cached version of the current `RatesConfiguration`.
    /// @param util The current utilization value, used to determine how the
    ///             multiplier should be adjusted.
    /// @return The updated multiplier after applying decay and
    ///         adjustments based on the current utilization level.
    function _updateForBelowVertex(
        RatesConfiguration memory config,
        uint256 util
    ) internal view returns (uint256) {
        uint256 currentMultiplier = vertexMultiplier();
        // Calculate decay rate.
        uint256 decay = (currentMultiplier * config.decayRate) / WAD;
        uint256 newMultiplier;

        if (util <= config.decreaseThresholdMax) {
            newMultiplier =
                ((currentMultiplier * WAD) / config.adjustmentVelocity) -
                decay;

            // Check if decay rate sends multiplier below 1.
            return newMultiplier < WAD ? WAD : newMultiplier;
        }

        uint256 curveResult = _getNegativeCurveResult(
            util,
            config.decreaseThreshold,
            config.decreaseThresholdMax
        );

        // If utilization is equal to decrease threshold the curve will
        // result in 0, causing a divide by 0 error.
        if (curveResult == 0) {
            newMultiplier = currentMultiplier - decay;
            return newMultiplier < WAD ? WAD : newMultiplier;
        }

        newMultiplier = ((currentMultiplier * WAD_SQUARED) / 
        (curveResult * config.adjustmentVelocity)) - decay;

        // Update and return with adjustment and decay rate applied.
        // But first check if new rate sends multiplier below 1.
        return newMultiplier < WAD ? WAD : newMultiplier;
    }

    /// @notice Calculates and returns the updated multiplier for scenarios
    ///         where the utilization is above the vertex.
    /// @dev This function is used to adjust the vertex multiplier based on
    ///      the dToken's current borrow utilization.
    ///      A decay mechanism is incorporated to gradually decrease the
    ///      multiplier, and ensures the multiplier does not fall below 1 (in WAD).
    ///      NOTE: The multiplier is updated with the following logic:
    ///      If the utilization is below the 'increaseThreshold',
    ///      it simply applies the decay to the current multiplier.
    ///      If the utilization is higher, it calculates a new multiplier by
    ///      applying a positive curve value to the adjustment. This adjustment
    ///      is also subjected to the decay multiplier.
    /// @param config The cached version of the current `RatesConfiguration`.
    /// @param util The current utilization value, used to determine how the
    ///             multiplier should be adjusted.
    /// @return The updated multiplier after applying decay and
    ///         adjustments based on the current utilization level.
    function _updateForAboveVertex(
        RatesConfiguration memory config,
        uint256 util
    ) internal view returns (uint256) {
        uint256 currentMultiplier = vertexMultiplier();
        // Calculate decay rate.
        uint256 decay = (currentMultiplier * config.decayRate) / WAD;
        uint256 newMultiplier;

        if (util < config.increaseThreshold) {
            newMultiplier = currentMultiplier - decay;

            // Check if decay rate sends new rate below 1.
            return newMultiplier < WAD ? WAD : newMultiplier;
        }

        newMultiplier =
            ((currentMultiplier *
                (config.adjustmentVelocity *
                    _getPositiveCurveResult(
                        util,
                        config.increaseThreshold,
                        config.increaseThresholdMax
                    ))) /
                WAD_SQUARED) -
            decay;

        // Update and return with adjustment and decay rate applied.
        // Its theorectically possible for the multiplier to be below 1
        // due to decay, so we need to check like in below vertex.
        if (newMultiplier < WAD) {
            return WAD;
        }

        // Make sure we are not above the vertex multiplier maximum.
        return
            newMultiplier < config.vertexMultiplierMax
                ? newMultiplier
                : config.vertexMultiplierMax;
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

    /// @notice Calculates a negative curve value based on `current`,
    ///         `start`, and `end` values.
    /// @dev The function scales current, start, and end values by WAD
    ///      to maintain precision. It returns 1, (`in WAD`) if the
    ///      current value is less than or equal to `end`. The formula
    ///      used is (start - current) / (start - end), ensuring the result
    ///      is scaled properly.
    /// @param current The current value, representing a point on the curve.
    /// @param start The start value of the curve, marking the beginning of
    ///              the calculation range.
    /// @param end The end value of the curve, marking the end of the
    ///            calculation range.
    /// @return The calculated negative curve value, a proportion between
    ///         the start and end points.
    function _getNegativeCurveResult(
        uint256 current,
        uint256 start,
        uint256 end
    ) internal pure returns (uint256) {
        if (current <= end) {
            return WAD;
        }

        return ((start - current) * WAD) / (start - end);
    }

    /// @notice Updates the parameters of the dynamic interest rate model
    ///         used in the market.
    /// @dev This function sets various parameters for the dynamic interest
    ///      rate model, adjusting how interest rates are calculated based on
    ///      system utilization.
    /// @param baseRatePerYear The base interest rate per year,
    ///                        in `basis points`.
    /// @param vertexRatePerYear The vertex interest rate per year,
    ///                          in `basis points`.
    /// @param vertexUtilizationStart The starting point of the vertex
    ///                               utilization, in `basis points`.
    /// @param adjustmentRate The rate at which the interest model adjusts.
    /// @param adjustmentVelocity The velocity of adjustment for the interest model.
    /// @param vertexMultiplierMax The maximum value that vertexMultiplier can be
    /// @param decayRate The decay rate applied to the interest model.
    /// @param vertexReset A boolean flag indicating whether the vertex multiplier
    ///                    should be reset.
    function _updateDynamicInterestRateModel(
        uint256 baseRatePerYear,
        uint256 vertexRatePerYear,
        uint256 vertexUtilizationStart,
        uint256 adjustmentRate,
        uint256 adjustmentVelocity,
        uint256 vertexMultiplierMax,
        uint256 decayRate,
        bool vertexReset
    ) internal {
        // Convert the parameters from basis points to `WAD` format.
        // While inefficient, we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config.
        baseRatePerYear = _bpToWad(baseRatePerYear);
        vertexRatePerYear = _bpToWad(vertexRatePerYear);
        vertexUtilizationStart = _bpToWad(vertexUtilizationStart);
        // This is a multiplier/divisor so it needs to be on top
        // of the base value (1 `WAD`).
        adjustmentVelocity = _bpToWad(adjustmentVelocity) + WAD;
        vertexMultiplierMax = _bpToWad(vertexMultiplierMax);
        decayRate = _bpToWad(decayRate);

        if (
            adjustmentVelocity > MAX_VERTEX_ADJUSTMENT_VELOCITY || 
            adjustmentVelocity < MIN_VERTEX_ADJUSTMENT_VELOCITY
        ) {
            revert DynamicInterestRateModel__InvalidAdjustmentVelocity();
        }

        if (
            adjustmentRate > MAX_VERTEX_ADJUSTMENT_RATE ||
            adjustmentRate < MIN_VERTEX_ADJUSTMENT_RATE
        ) {
            revert DynamicInterestRateModel__InvalidAdjustmentRate();
        }

        if (decayRate > MAX_VERTEX_DECAY_RATE) {
            revert DynamicInterestRateModel__InvalidDecayRate();
        }

        // Validate that if the model is at the theoretical maximum multiplier
        // no overflow will be created via bitshifting.
        if (vertexMultiplierMax * vertexRatePerYear > type(uint192).max) {
            revert DynamicInterestRateModel__InvalidMultiplierMax();
        }

        RatesConfiguration storage config = ratesConfig;

        config.baseInterestRate =
            (INTEREST_COMPOUND_RATE * baseRatePerYear * WAD) /
            (_SECONDS_PER_YEAR * vertexUtilizationStart);
        config.vertexInterestRate =
            (INTEREST_COMPOUND_RATE * vertexRatePerYear) /
            _SECONDS_PER_YEAR;

        config.vertexStartingPoint = vertexUtilizationStart;
        config.adjustmentRate = adjustmentRate;
        config.adjustmentVelocity = adjustmentVelocity;

        {
            // Scoping to avoid stack too deep.
            uint256 newMultiplier = vertexReset ? WAD : vertexMultiplier();
            _currentRates = _packRatesData(
                    newMultiplier,
                    uint64(block.timestamp + config.adjustmentRate)
                );
        }

        config.decayRate = decayRate;

        uint256 thresholdLength = (WAD - vertexUtilizationStart) / 2;

        // Dynamic rates start increase halfway between desired utilization
        // and 100%.
        config.increaseThreshold = vertexUtilizationStart + thresholdLength;
        config.increaseThresholdMax = WAD;

        // Dynamic rates start decreasing as soon as we are below desired
        // utilization.
        config.decreaseThreshold = vertexUtilizationStart;
        config.decreaseThresholdMax = vertexUtilizationStart - thresholdLength;

        RatesConfiguration memory cachedConfig = config;

        emit NewDynamicInterestRateModel(
            cachedConfig.baseInterestRate, // base rate.
            cachedConfig.vertexInterestRate, // vertex base rate.
            vertexUtilizationStart, // Vertex utilization rate start.
            adjustmentRate, // Adjustment rate.
            adjustmentVelocity, // Adjustment velocity.
            vertexMultiplierMax, // Vertex multiplier max.
            decayRate, // Decay rate.
            cachedConfig.increaseThreshold, // Vertex increase threshold.
            WAD, // Vertex increase threshold max.
            cachedConfig.decreaseThreshold, // Vertex decrease threshold.
            cachedConfig.decreaseThresholdMax, // Vertex decrease threshold max.
            vertexReset // Was vertex multiplier reset.
        );
    }

    /// @notice Packs `newVertexMultiplier` together with `newTimestamp`,
    ///         to create new packed `_currentRates` value.
    /// @param newVertexMultiplier The new rate at which vertexInterestRate
    ///                            is multiplied, in `WAD`.
    /// @param newTimestamp The new timestamp when the vertex multiplier
    ///                     will be updated.
    function _packRatesData(
        uint256 newVertexMultiplier,
        uint256 newTimestamp
    ) internal pure returns (uint256 result) {
        assembly {
            // Mask `newVertexMultiplier` to the lower 192 b.its,
            // in case the upper bits somehow aren't clean
            newVertexMultiplier := and(
                newVertexMultiplier,
                _BITMASK_VERTEX_MULTIPLIER
            )
            // `newVertexMultiplier | block.timestamp`.
            result := or(
                newVertexMultiplier,
                shl(_BITPOS_UPDATE_TIMESTAMP, newTimestamp)
            )
        }
    }

    /// @notice Packs `newTimestamp` with the current vertex multiplier,
    ///         to create new packed `_currentRates` value.
    /// @param newTimestamp The new timestamp when the vertex multiplier
    ///                     will be updated.
    function _setUpdateTimestamp(uint64 newTimestamp) internal {
        uint256 packedRatesData = _currentRates;
        uint256 timestampCasted;
        // Cast `timestampCasted` with assembly to avoid redundant masking.
        assembly {
            timestampCasted := newTimestamp
        }
        packedRatesData =
            (packedRatesData & _BITMASK_VERTEX_MULTIPLIER) |
            (timestampCasted << _BITPOS_UPDATE_TIMESTAMP);
        _currentRates = packedRatesData;
    }

    /// @notice Multiplies `value` by 1e14 to convert it from `basis points`
    ///         to WAD.
    /// @dev Internal helper function for easily converting between scalars.
    function _bpToWad(uint256 value) internal pure returns (uint256) {
        return value * 100000000000000;
    }
}