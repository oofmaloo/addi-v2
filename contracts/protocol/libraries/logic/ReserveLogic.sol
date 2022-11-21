// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.10;

// import {IERC20} from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
// import {GPv2SafeERC20} from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {IStableDebtToken} from '../../../interfaces/IStableDebtToken.sol';
import {IVariableDebtToken} from '../../../interfaces/IVariableDebtToken.sol';
import {IAToken} from '../../../interfaces/IAToken.sol';
import {IReserveInterestRateStrategy} from '../../../interfaces/IReserveInterestRateStrategy.sol';
import {IAggregator} from '../../../interfaces/IAggregator.sol';
import {ReserveConfiguration} from '../configuration/ReserveConfiguration.sol';
import {MathUtils} from '../math/MathUtils.sol';
import {WadRayMath} from '../math/WadRayMath.sol';
import {PercentageMath} from '../math/PercentageMath.sol';
import {Errors} from '../helpers/Errors.sol';
import {DataTypes} from '../types/DataTypes.sol';
import {SafeCast} from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';
// import {IInterestRateOracle} from '../../../interfaces/IInterestRateOracle.sol';
import "hardhat/console.sol";


/**
 * @title ReserveLogic library
 * @author Aave
 * @notice Implements the logic to update the reserves state
 */
library ReserveLogic {
  using WadRayMath for uint256;
  using PercentageMath for uint256;
  using SafeCast for uint256;
  // using GPv2SafeERC20 for IERC20;
  using ReserveLogic for DataTypes.ReserveData;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  // See `IPool` for descriptions
  event ReserveDataUpdated(
    address indexed reserve,
    uint256 liquidityRate,
    uint256 stableBorrowRate,
    uint256 variableBorrowRate,
    uint256 liquidityIndex,
    uint256 variableBorrowIndex
  );


  struct NormalizeIncomeLocalVars {
    uint256 prevTotalStableDebt;
    uint256 prevTotalVariableDebt;
    uint256 currTotalVariableDebt;
    uint256 cumulatedStableInterest;
    uint256 totalDebtAccrued;
    uint256 amountToMint;
    uint256 normalizedDebtIncome;
    uint256 currPrincipalStableDebt;
    uint256 currTotalStableDebt;
    uint256 currAvgStableBorrowRate;
    uint256 stableDebtLastUpdateTimestamp;
  }

  /**
   * @notice Returns the ongoing normalized income for the reserve.
   * @dev A value of 1e27 means there is no income. As time passes, the income is accrued
   * @dev A value of 2*1e27 means for each unit of asset one unit of income has been accrued
   * @param reserve The reserve object
   * @return The normalized income, expressed in ray
   **/
  function getNormalizedIncome(DataTypes.ReserveData storage reserve)
    internal
    view
    returns (uint256)
  {
    uint40 timestamp = reserve.lastUpdateTimestamp;

    //solium-disable-next-line
    if (timestamp == block.timestamp) {
      //if the index was updated in the same block, no need to perform any calculation
      return reserve.liquidityIndex;
    } else {

      NormalizeIncomeLocalVars memory vars;

      //calculate the total variable debt at moment of the last interaction
      vars.prevTotalVariableDebt = IVariableDebtToken(reserve.variableDebtTokenAddress).scaledTotalSupply().rayMul(
        reserve.variableBorrowIndex
      );

      vars.normalizedDebtIncome = getNormalizedDebt(reserve);

      //calculate the new total variable debt after accumulation of the interest on the index
      vars.currTotalVariableDebt = IVariableDebtToken(reserve.variableDebtTokenAddress).scaledTotalSupply().rayMul(
        vars.normalizedDebtIncome
      );

      (
        vars.currPrincipalStableDebt,
        vars.currTotalStableDebt,
        vars.currAvgStableBorrowRate,
        vars.stableDebtLastUpdateTimestamp
      ) = IStableDebtToken(reserve.stableDebtTokenAddress).getSupplyData();

      //calculate the stable debt until the last timestamp update
      vars.cumulatedStableInterest = MathUtils.calculateCompoundedInterest(
        vars.currAvgStableBorrowRate,
        uint40(vars.stableDebtLastUpdateTimestamp),
        timestamp
      );

      vars.prevTotalStableDebt = vars.currPrincipalStableDebt.rayMul(
        vars.cumulatedStableInterest
      );

      //debt accrued is the sum of the current debt minus the sum of the debt at the last update
      vars.totalDebtAccrued =
        vars.currTotalVariableDebt +
        vars.currTotalStableDebt -
        vars.prevTotalVariableDebt -
        vars.prevTotalStableDebt;

      (
        uint256 aggregatorBalance,
        uint256 previousAggregatorBalance
      ) = IAggregator(reserve.aggregatorAddress).accrueSim();
      console.log("aggregatorBalance", aggregatorBalance);
      console.log("previousAggregatorBalance", previousAggregatorBalance);

      uint256 balanceDecreased;
      uint256 aggregatorAmountAccrued;
      if (aggregatorBalance < previousAggregatorBalance) {
        //
        // check if aggregator somehow decreased on balance
        // this is possible because we have no control over integrated protocols
        //
        balanceDecreased = previousAggregatorBalance - aggregatorBalance;
      } else {
        aggregatorAmountAccrued = (aggregatorBalance - previousAggregatorBalance).percentMul(reserve.aggregatorFactor);
      }

      // uint256 totalAccrued = vars.totalDebtAccrued + aggregatorAmountAccrued;

      uint256 totalAccrued;
      if (balanceDecreased > vars.totalDebtAccrued) {
        totalAccrued = 0;
        balanceDecreased -= vars.totalDebtAccrued;
      } else {
        totalAccrued += aggregatorAmountAccrued;
      }

      if (balanceDecreased != 0) {
        uint256 lastTotalSupply = 
          IAToken(reserve.aTokenAddress).scaledTotalSupply().rayMul(reserve.liquidityIndex);

        uint256 decreasedLiquidityInterest = balanceDecreased.rayDiv(lastTotalSupply);

        return (reserve.liquidityIndex - decreasedLiquidityInterest.rayMul(
            reserve.liquidityIndex));
      }

      if (totalAccrued != 0) {
        vars.amountToMint = totalAccrued.percentMul(reserve.configuration.getReserveFactor());

        uint256 lastTotalSupply = 
          IAToken(reserve.aTokenAddress).scaledTotalSupply().rayMul(reserve.liquidityIndex);

        uint256 cumulatedLiquidityInterest = (totalAccrued - vars.amountToMint).rayDiv(lastTotalSupply);

        return (cumulatedLiquidityInterest.rayMul(reserve.liquidityIndex) + reserve.liquidityIndex);
      } else {
        return reserve.liquidityIndex;
      }
    }
  }

  /**
   * @notice Returns the ongoing normalized variable debt for the reserve.
   * @dev A value of 1e27 means there is no debt. As time passes, the debt is accrued
   * @dev A value of 2*1e27 means that for each unit of debt, one unit worth of interest has been accumulated
   * @param reserve The reserve object
   * @return The normalized variable debt, expressed in ray
   **/
  function getNormalizedDebt(DataTypes.ReserveData storage reserve)
    internal
    view
    returns (uint256)
  {
    uint40 timestamp = reserve.lastUpdateTimestamp;

    //solium-disable-next-line
    if (timestamp == block.timestamp) {
      //if the index was updated in the same block, no need to perform any calculation
      return reserve.variableBorrowIndex;
    } else {
      return
        MathUtils.calculateCompoundedInterest(reserve.currentVariableBorrowRate, timestamp).rayMul(
          reserve.variableBorrowIndex
        );
    }
  }

  function _getAggregatorData(address aggregatorAddress) internal returns (uint256, uint256) {
    if (aggregatorAddress == address(0)) {
      return (0,0);
    }
    (
      uint256 newBalance,
      uint256 lastUpdatedBalance
    ) = IAggregator(aggregatorAddress).accrue();
    return (
      newBalance, 
      lastUpdatedBalance
    );
  }


  /**
   * @notice Updates the liquidity cumulative index and the variable borrow index.
   * @param reserve The reserve object
   * @param reserveCache The caching layer for the reserve data
   **/
  function updateState(
    DataTypes.ReserveData storage reserve,
    DataTypes.ReserveCache memory reserveCache
  ) internal {
    // update variable debt indexes
    _updateIndexes(reserve, reserveCache);
    // accrue debt and distr
    (uint256 totalDebtAccrued, uint256 balanceDecreased) = _getTotalDebtAccrued(reserve, reserveCache);
    // update liquidity indexes
    uint256 amountToMint = _updateLiquidityIndex(reserve, reserveCache, totalDebtAccrued, balanceDecreased);
    _accrueToTreasury(reserve, reserveCache, amountToMint);
  }

  /**
   * @notice Accumulates a predefined amount of asset to the reserve as a fixed, instantaneous income. Used for example
   * to accumulate the flashloan fee to the reserve, and spread it between all the suppliers.
   * @param reserve The reserve object
   * @param totalLiquidity The total liquidity available in the reserve
   * @param amount The amount to accumulate
   * @return The next liquidity index of the reserve
   **/
  function cumulateToLiquidityIndex(
    DataTypes.ReserveData storage reserve,
    uint256 totalLiquidity,
    uint256 amount
  ) internal returns (uint256) {
    //next liquidity index is calculated this way: `((amount / totalLiquidity) + 1) * liquidityIndex`
    //division `amount / totalLiquidity` done in ray for precision
    uint256 result = (amount.wadToRay().rayDiv(totalLiquidity.wadToRay()) + WadRayMath.RAY).rayMul(
      reserve.liquidityIndex
    );
    reserve.liquidityIndex = result.toUint128();

    // less gas vers
    // uint256 result = amount.rayDiv(totalLiquidity).rayMul(
    //   reserve.liquidityIndex) + reserve.liquidityIndex;

    // reserve.liquidityIndex = result.toUint128();

    return result;
  }

  /**
   * @notice Initializes a reserve.
   * @param reserve The reserve object
   * @param aTokenAddress The address of the overlying atoken contract
   * @param stableDebtTokenAddress The address of the overlying stable debt token contract
   * @param variableDebtTokenAddress The address of the overlying variable debt token contract
   * @param interestRateStrategyAddress The address of the interest rate strategy contract
   **/
  function init(
    DataTypes.ReserveData storage reserve,
    address aTokenAddress,
    address stableDebtTokenAddress,
    address variableDebtTokenAddress,
    address interestRateStrategyAddress
  ) internal {
    require(reserve.aTokenAddress == address(0), Errors.RESERVE_ALREADY_INITIALIZED);

    reserve.liquidityIndex = uint128(WadRayMath.RAY);
    reserve.variableBorrowIndex = uint128(WadRayMath.RAY);
    reserve.aTokenAddress = aTokenAddress;
    reserve.stableDebtTokenAddress = stableDebtTokenAddress;
    reserve.variableDebtTokenAddress = variableDebtTokenAddress;
    reserve.interestRateStrategyAddress = interestRateStrategyAddress;
  }

  struct UpdateInterestRatesLocalVars {
    uint256 nextLiquidityRate;
    uint256 nextStableRate;
    uint256 nextVariableRate;
    uint256 totalVariableDebt;
  }

  /**
   * @notice Updates the reserve current stable borrow rate, the current variable borrow rate and the current liquidity rate.
   * @param reserve The reserve reserve to be updated
   * @param reserveCache The caching layer for the reserve data
   * @param reserveAddress The address of the reserve to be updated
   * @param liquidityAdded The amount of liquidity added to the protocol (supply or repay) in the previous action
   * @param liquidityTaken The amount of liquidity taken from the protocol (redeem or borrow)
   **/
  function updateInterestRates(
    DataTypes.ReserveData storage reserve,
    DataTypes.ReserveCache memory reserveCache,
    address reserveAddress,
    uint256 liquidityAdded,
    uint256 liquidityTaken
  ) internal {
    UpdateInterestRatesLocalVars memory vars;
    console.log("updateInterestRates interestRateStrategyAddress, reserve.interestRateStrategyAddress");
    vars.totalVariableDebt = reserveCache.nextScaledVariableDebt.rayMul(
      reserveCache.nextVariableBorrowIndex
    );
    console.log("updateInterestRates totalVariableDebt, vars.totalVariableDebt");
    // uint256 avgBorrowRate = IInterestRateOracle(reserve.interestRateOracleAddress).getAverageBorrowRate();
    // uint256 baseRate = reserve.currentLiquidityRate < avgBorrowRate ? reserve.currentLiquidityRate : avgBorrowRate;
    (
      ,
      vars.nextStableRate,
      vars.nextVariableRate
    ) = IReserveInterestRateStrategy(reserve.interestRateStrategyAddress).calculateInterestRates(
      DataTypes.CalculateInterestRatesParams({
        unbacked: 0,
        liquidityAdded: liquidityAdded,
        liquidityTaken: liquidityTaken,
        totalStableDebt: reserveCache.nextTotalStableDebt,
        totalVariableDebt: vars.totalVariableDebt,
        averageStableBorrowRate: reserveCache.nextAvgStableBorrowRate,
        reserveFactor: reserveCache.reserveFactor,
        baseRate: reserve.currentLiquidityRate,
        reserve: reserveAddress,
        aToken: reserveCache.aTokenAddress,
        aggregator: reserveCache.aggregatorAddress
      })
    );
    // reserve.currentLiquidityRate = vars.nextLiquidityRate.toUint128();
    reserve.currentStableBorrowRate = vars.nextStableRate.toUint128();
    reserve.currentVariableBorrowRate = vars.nextVariableRate.toUint128();

    emit ReserveDataUpdated(
      reserveAddress,
      vars.nextLiquidityRate,
      vars.nextStableRate,
      vars.nextVariableRate,
      reserveCache.nextLiquidityIndex,
      reserveCache.nextVariableBorrowIndex
    );
  }

  struct AccrueToTreasuryLocalVars {
    uint256 prevTotalStableDebt;
    uint256 prevTotalVariableDebt;
    uint256 currTotalVariableDebt;
    uint256 cumulatedStableInterest;
    uint256 totalDebtAccrued;
    uint256 amountToMint;
  }

  function _getTotalDebtAccrued(
    DataTypes.ReserveData storage reserve,
    DataTypes.ReserveCache memory reserveCache
  ) internal returns (uint256, uint256) {
    AccrueToTreasuryLocalVars memory vars;

    // if (reserveCache.reserveFactor == 0) {
    //   return 0;
    // }
    console.log("_getTotalDebtAccrued 1");

    //calculate the total variable debt at moment of the last interaction
    vars.prevTotalVariableDebt = reserveCache.currScaledVariableDebt.rayMul(
      reserveCache.currVariableBorrowIndex
    );

    //calculate the new total variable debt after accumulation of the interest on the index
    vars.currTotalVariableDebt = reserveCache.currScaledVariableDebt.rayMul(
      reserveCache.nextVariableBorrowIndex
    );

    //calculate the stable debt until the last timestamp update
    vars.cumulatedStableInterest = MathUtils.calculateCompoundedInterest(
      reserveCache.currAvgStableBorrowRate,
      reserveCache.stableDebtLastUpdateTimestamp,
      reserveCache.reserveLastUpdateTimestamp
    );

    vars.prevTotalStableDebt = reserveCache.currPrincipalStableDebt.rayMul(
      vars.cumulatedStableInterest
    );

    // calculate from aggregator distribution
    (
      uint256 aggregatorBalance,
      uint256 previousAggregatorBalance
    ) = _getAggregatorData(reserveCache.aggregatorAddress);

    // if (aggregatorBalance > previousAggregatorBalance) {
    //   vars.totalDebtAccrued += 
    //     (aggregatorBalance - previousAggregatorBalance);
    // }

    // it's possible for a strategy to not be profitable and so we check here
    // if balanceDecreased is greater than 0
    uint256 balanceDecreased;
    if (aggregatorBalance < previousAggregatorBalance) {
      //
      // check if aggregator somehow decreased on balance
      // this is possible because we have no control over integrated protocols in riskier vaults
      //
      balanceDecreased = previousAggregatorBalance - aggregatorBalance;
      console.log("balanceDecreased if", balanceDecreased);
    } else {
      vars.totalDebtAccrued += 
        (aggregatorBalance - previousAggregatorBalance);
      console.log("balanceDecreased else", vars.totalDebtAccrued);
    }

    //debt accrued is the sum of the current debt minus the sum of the debt at the last update
    vars.totalDebtAccrued +=
      vars.currTotalVariableDebt +
      reserveCache.currTotalStableDebt -
      vars.prevTotalVariableDebt -
      vars.prevTotalStableDebt;

    console.log("vars.totalDebtAccrued", vars.totalDebtAccrued);

    // both cannot be greater than 0
    if (balanceDecreased > vars.totalDebtAccrued) {
      vars.totalDebtAccrued = 0;
      balanceDecreased -= vars.totalDebtAccrued;
    } else {
      // safely checks if we need to lower accrued amount
      vars.totalDebtAccrued -= balanceDecreased;
    }

    // total profit of base protocol and strategies
    // either both are 0, or one or the other is greater than 0

    return (vars.totalDebtAccrued, balanceDecreased);
  }

  /**
   * @notice Mints part of the repaid interest to the reserve treasury as a function of the reserve factor for the
   * specific asset.
   * @param reserve The reserve to be updated
   * @param reserveCache The caching layer for the reserve data
   **/
  function _accrueToTreasury(
    DataTypes.ReserveData storage reserve,
    DataTypes.ReserveCache memory reserveCache,
    uint256 amountToMint
  ) internal {
    console.log("_accrueToTreasury");
    AccrueToTreasuryLocalVars memory vars;

    console.log("_accrueToTreasury vars.amountToMint", vars.amountToMint);
    console.log("_accrueToTreasury reserveCache.nextLiquidityIndex", reserveCache.nextLiquidityIndex);
    console.log("_accrueToTreasury reserveCache.reserveFactor", reserveCache.reserveFactor);

    if (amountToMint == 0) {
      return;
    }

    console.log("_accrueToTreasury amountToMint", amountToMint);

    if (amountToMint != 0) {
      reserve.accruedToTreasury += 
        amountToMint
        .rayDiv(reserveCache.nextLiquidityIndex)
        .toUint128();
    }

    // console.log("_accrueToTreasury 1");

    // //calculate the total variable debt at moment of the last interaction
    // vars.prevTotalVariableDebt = reserveCache.currScaledVariableDebt.rayMul(
    //   reserveCache.currVariableBorrowIndex
    // );

    // //calculate the new total variable debt after accumulation of the interest on the index
    // vars.currTotalVariableDebt = reserveCache.currScaledVariableDebt.rayMul(
    //   reserveCache.nextVariableBorrowIndex
    // );

    // //calculate the stable debt until the last timestamp update
    // vars.cumulatedStableInterest = MathUtils.calculateCompoundedInterest(
    //   reserveCache.currAvgStableBorrowRate,
    //   reserveCache.stableDebtLastUpdateTimestamp,
    //   reserveCache.reserveLastUpdateTimestamp
    // );

    // vars.prevTotalStableDebt = reserveCache.currPrincipalStableDebt.rayMul(
    //   vars.cumulatedStableInterest
    // );

    // //debt accrued is the sum of the current debt minus the sum of the debt at the last update
    // vars.totalDebtAccrued =
    //   vars.currTotalVariableDebt +
    //   reserveCache.currTotalStableDebt -
    //   vars.prevTotalVariableDebt -
    //   vars.prevTotalStableDebt;

    // // vars.amountToMint = vars.totalDebtAccrued.percentMul(reserveCache.reserveFactor);

    // // reserveCache.nextLiquidityIndex = reserveCache.currLiquidityIndex;

    // console.log("_accrueToTreasury 2");

    // (
    //   uint256 aggregatorBalance,
    //   uint256 previousAggregatorBalance
    // ) = _getAggregatorData(reserve.aggregatorAddress);

    // uint256 aggregatorAmountAccrued;
    // if (aggregatorBalance > previousAggregatorBalance) {
    //   aggregatorAmountAccrued = 
    //     (aggregatorBalance - previousAggregatorBalance).percentMul(reserve.aggregatorFactor);
    // }

    // uint256 totalAccrued = vars.totalDebtAccrued + aggregatorAmountAccrued;

    // if (totalAccrued != 0) {
    //   uint256 lastTotalSupply = 
    //     IAToken(reserveCache.aTokenAddress).scaledTotalSupply().rayMul(reserveCache.nextLiquidityIndex);

    //   uint256 cumulatedLiquidityInterest = (totalAccrued - vars.amountToMint).rayDiv(lastTotalSupply);

    //   reserveCache.nextLiquidityIndex = cumulatedLiquidityInterest.rayMul(
    //       reserve.liquidityIndex) + reserve.liquidityIndex;

    //   reserve.liquidityIndex = reserveCache.nextLiquidityIndex.toUint128();

    //   uint256 newLiquidityRate = 
    //     totalAccrued.rayDiv(lastTotalSupply) * (MathUtils.SECONDS_PER_YEAR) / (
    //       block.timestamp - reserveCache.reserveLastUpdateTimestamp
    //     );

    //   reserve.currentLiquidityRate = newLiquidityRate.toUint128();

    // }

    // mint after accrue liquidity index
    // if (vars.amountToMint != 0) {
    //   reserve.accruedToTreasury += vars
    //     .amountToMint
    //     .rayDiv(reserveCache.nextLiquidityIndex)
    //     .toUint128();
    // }
  }

  function _updateLiquidityIndex(
    DataTypes.ReserveData storage reserve,
    DataTypes.ReserveCache memory reserveCache,
    uint256 totalDebtAccrued,
    uint256 balanceDecreased
  ) internal returns (uint256) {
    AccrueToTreasuryLocalVars memory vars;
    vars.totalDebtAccrued = totalDebtAccrued;

    // (
    //   uint256 aggregatorBalance,
    //   uint256 previousAggregatorBalance
    // ) = _getAggregatorData(reserveCache.aggregatorAddress);

    // console.log("_updateLiquidityIndex 1", aggregatorBalance, previousAggregatorBalance);

    // uint256 aggregatorAmountAccrued;
    // if (aggregatorBalance > previousAggregatorBalance) {
    //   aggregatorAmountAccrued = 
    //     (aggregatorBalance - previousAggregatorBalance);
    //     // (aggregatorBalance - previousAggregatorBalance).percentMul(reserve.aggregatorFactor);
    // }

    // vars.totalDebtAccrued += aggregatorAmountAccrued;

    console.log("_updateLiquidityIndex vars.totalDebtAccrued 1", vars.totalDebtAccrued);


    reserveCache.nextLiquidityIndex = reserveCache.currLiquidityIndex;

    if (balanceDecreased != 0) {
      console.log("_updateLiquidityIndex balanceDecreased");
      uint256 lastTotalSupply = 
        IAToken(reserveCache.aTokenAddress).scaledTotalSupply().rayMul(reserveCache.nextLiquidityIndex);

      uint256 decreasedLiquidityInterest = balanceDecreased.rayDiv(lastTotalSupply);

      reserveCache.nextLiquidityIndex = reserve.liquidityIndex - decreasedLiquidityInterest.rayMul(
        reserve.liquidityIndex);

      reserve.liquidityIndex = reserveCache.nextLiquidityIndex.toUint128();

      // no update to liquidity rate.  It will continue as last updated until profit is generated
    }

    if (vars.totalDebtAccrued != 0) {
      console.log("_updateLiquidityIndex vars.totalDebtAccrued 2", vars.totalDebtAccrued);
      vars.amountToMint = vars.totalDebtAccrued.percentMul(reserveCache.reserveFactor);
      console.log("_updateLiquidityIndex vars.amountToMint", vars.amountToMint);

      uint256 lastTotalSupply = 
        IAToken(reserveCache.aTokenAddress).scaledTotalSupply().rayMul(reserveCache.nextLiquidityIndex);

      uint256 cumulatedLiquidityInterest = (vars.totalDebtAccrued - vars.amountToMint).rayDiv(lastTotalSupply);
      console.log("_updateLiquidityIndex cumulatedLiquidityInterest", cumulatedLiquidityInterest);

      reserveCache.nextLiquidityIndex = cumulatedLiquidityInterest.rayMul(
          reserve.liquidityIndex) + reserve.liquidityIndex;

      reserve.liquidityIndex = reserveCache.nextLiquidityIndex.toUint128();
      console.log("_updateLiquidityIndex reserve.liquidityIndex", reserve.liquidityIndex);

      uint256 newLiquidityRate = 
        vars.totalDebtAccrued.rayDiv(lastTotalSupply) * (MathUtils.SECONDS_PER_YEAR) / (
          block.timestamp - reserveCache.reserveLastUpdateTimestamp
        );
      console.log("_updateLiquidityIndex newLiquidityRate", newLiquidityRate);

      reserve.currentLiquidityRate = newLiquidityRate.toUint128();

    }
    return vars.amountToMint;
  }

  /**
   * @notice Updates the reserve debt indexes and the timestamp of the update.
   * @param reserve The reserve reserve to be updated
   * @param reserveCache The cache layer holding the cached protocol data
   **/
  function _updateIndexes(
    DataTypes.ReserveData storage reserve,
    DataTypes.ReserveCache memory reserveCache
  ) internal {
    reserveCache.nextVariableBorrowIndex = reserveCache.currVariableBorrowIndex;

    //only cumulating if there is any income being produced
    // if (reserveCache.currLiquidityRate != 0) {
    // if (reserveCache.currScaledVariableDebt != 0) {
    console.log("_updateIndexes currLiquidityRate", reserveCache.currLiquidityRate);
    console.log("_updateIndexes borrowingEnabled", reserveCache.borrowingEnabled);
    console.log("_updateIndexes currScaledVariableDebt", reserveCache.currScaledVariableDebt);
    // if (
    //   reserveCache.currLiquidityRate != 0 &&
    //   reserveCache.borrowingEnabled
    // ) {
      // console.log("_updateIndexes 2");
      //as the liquidity rate might come only from stable rate loans, we need to ensure
      //that there is actual variable debt before accumulating
    if (
      reserveCache.currLiquidityRate != 0 && 
      reserveCache.currScaledVariableDebt != 0
    ) {
      uint256 cumulatedVariableBorrowInterest = MathUtils.calculateCompoundedInterest(
        reserveCache.currVariableBorrowRate,
        reserveCache.reserveLastUpdateTimestamp
      );
      console.log("_updateIndexes 3", cumulatedVariableBorrowInterest);
      reserveCache.nextVariableBorrowIndex = cumulatedVariableBorrowInterest.rayMul(
        reserveCache.currVariableBorrowIndex
      );
      console.log("_updateIndexes 4", reserveCache.nextVariableBorrowIndex);
      reserve.variableBorrowIndex = reserveCache.nextVariableBorrowIndex.toUint128();
      console.log("_updateIndexes 5", reserve.variableBorrowIndex);
    }
    // }

    //solium-disable-next-line
    reserve.lastUpdateTimestamp = uint40(block.timestamp);
  }

  /**
   * @notice Creates a cache object to avoid repeated storage reads and external contract calls when updating state and
   * interest rates.
   * @param reserve The reserve object for which the cache will be filled
   * @return The cache object
   */
  function cache(DataTypes.ReserveData storage reserve)
    internal
    view
    returns (DataTypes.ReserveCache memory)
  {
    console.log("ReserveLogic cache");
    DataTypes.ReserveCache memory reserveCache;

    reserveCache.reserveConfiguration = reserve.configuration;
    reserveCache.reserveFactor = reserveCache.reserveConfiguration.getReserveFactor();
    reserveCache.borrowingEnabled = reserveCache.reserveConfiguration.getBorrowingEnabled();
    reserveCache.currLiquidityIndex = reserve.liquidityIndex;

    reserveCache.currVariableBorrowIndex = reserve.variableBorrowIndex;

    reserveCache.currLiquidityRate = reserve.currentLiquidityRate;


    reserveCache.currVariableBorrowRate = reserve.currentVariableBorrowRate;

    reserveCache.aggregatorAddress = reserve.aggregatorAddress;


    reserveCache.vaultAddress = reserve.vaultAddress;

    reserveCache.aTokenAddress = reserve.aTokenAddress;
    reserveCache.stableDebtTokenAddress = reserve.stableDebtTokenAddress;
    reserveCache.variableDebtTokenAddress = reserve.variableDebtTokenAddress;

    reserveCache.reserveLastUpdateTimestamp = reserve.lastUpdateTimestamp;

    reserveCache.currScaledVariableDebt = reserveCache.nextScaledVariableDebt = IVariableDebtToken(
      reserveCache.variableDebtTokenAddress
    ).scaledTotalSupply();



    (
      reserveCache.currPrincipalStableDebt,
      reserveCache.currTotalStableDebt,
      reserveCache.currAvgStableBorrowRate,
      reserveCache.stableDebtLastUpdateTimestamp
    ) = IStableDebtToken(reserveCache.stableDebtTokenAddress).getSupplyData();


    // by default the actions are considered as not affecting the debt balances.
    // if the action involves mint/burn of debt, the cache needs to be updated
    reserveCache.nextTotalStableDebt = reserveCache.currTotalStableDebt;
    reserveCache.nextAvgStableBorrowRate = reserveCache.currAvgStableBorrowRate;

    return reserveCache;
  }
}
