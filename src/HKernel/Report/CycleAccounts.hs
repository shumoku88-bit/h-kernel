-- | Exact Account movement inside one cycle and exact comparison across cycles.
--
-- This module keeps three related but distinct report meanings explicit:
--
-- * 'CurrentCycleAccounts' observes opening, debit, credit, movement, and
--   closing balances inside one resolved cycle through one observation day;
-- * 'CycleComparison' compares the movement lane of two such observations under
--   an explicit comparison policy;
-- * the retained 'CycleAccounts' report compares Expense movement across two
--   explicit periods and remains available for compatibility while callers move
--   to the more precise report names above.
--
-- Cycle resolution itself remains outside this module. Account meaning is never
-- inferred from names and Commodity identity remains inside exact 'Balance'
-- values throughout.
module HKernel.Report.CycleAccounts
  ( CurrentCycleAccountRow(..)
  , currentCycleAccountRowMovement
  , currentCycleAccountRowClosing
  , CurrentCycleAccounts(..)
  , CurrentCycleAccountsError(..)
  , currentCycleAccountsOpeningTotal
  , currentCycleAccountsDebitTotal
  , currentCycleAccountsCreditTotal
  , currentCycleAccountsMovementTotal
  , currentCycleAccountsClosingTotal
  , currentCycleAccountsBalanced
  , currentCycleAccounts
  , CycleComparisonPolicy(..)
  , CycleComparisonRow(..)
  , cycleComparisonRowDifference
  , CycleComparison(..)
  , CycleComparisonError(..)
  , cycleComparisonCurrentTotal
  , cycleComparisonBaselineTotal
  , cycleComparisonDifferenceTotal
  , cycleComparisonBalanced
  , cycleComparison
  , CycleAccountRow(..)
  , cycleAccountRowDelta
  , CycleAccounts(..)
  , cycleAccountsCurrentTotal
  , cycleAccountsPreviousTotal
  , cycleAccountsDeltaTotal
  , cycleAccounts
  ) where

import Data.List (find)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Time.Calendar (Day, addDays, diffDays)
import HKernel.Account
  ( Account
  , AccountType(..)
  , accountDeclarations
  , accountTypeFor
  , declaredAccount
  )
import HKernel.Engine
  ( AccountBalances
  , LedgerEntry(..)
  , accountBalance
  , accountBalanceEntries
  , journalEntries
  )
import HKernel.Engine.Facts
  ( accountBalancesFromEntries
  )
import HKernel.Journal
  ( Journal
  , journalAccountRegistry
  )
import HKernel.Money
  ( Balance
  , amountQuantity
  , emptyBalance
  , isZeroBalance
  , singletonBalance
  , subtractBalance
  , sumBalances
  , zeroQuantity
  )
import HKernel.Period
  ( Period
  , periodContains
  , periodEndExclusive
  , periodStart
  )

-- Current-cycle Account state

-- | One canonical Account coordinate inside one observed cycle window.
--
-- Credit movement retains its ledger sign. Movement and closing are derived so
-- they cannot disagree with the three stored source lanes.
data CurrentCycleAccountRow = CurrentCycleAccountRow
  { currentCycleAccount       :: Account
  , currentCycleAccountOpening :: Balance
  , currentCycleAccountDebit   :: Balance
  , currentCycleAccountCredit  :: Balance
  } deriving (Eq, Show)

currentCycleAccountRowMovement :: CurrentCycleAccountRow -> Balance
currentCycleAccountRowMovement row =
  sumBalances
    [ currentCycleAccountDebit row
    , currentCycleAccountCredit row
    ]

currentCycleAccountRowClosing :: CurrentCycleAccountRow -> Balance
currentCycleAccountRowClosing row =
  sumBalances
    [ currentCycleAccountOpening row
    , currentCycleAccountRowMovement row
    ]

-- | Account state from cycle start through one inclusive observation day.
data CurrentCycleAccounts = CurrentCycleAccounts
  { currentCycleAccountsPeriod      :: Period
  , currentCycleAccountsObservation :: Day
  , currentCycleAccountsRows        :: [CurrentCycleAccountRow]
  } deriving (Eq, Show)

newtype CurrentCycleAccountsError
  = CurrentCycleObservationOutsidePeriod Day
  deriving (Eq, Show)

currentCycleAccountsOpeningTotal :: CurrentCycleAccounts -> Balance
currentCycleAccountsOpeningTotal =
  sumBalances . map currentCycleAccountOpening . currentCycleAccountsRows

currentCycleAccountsDebitTotal :: CurrentCycleAccounts -> Balance
currentCycleAccountsDebitTotal =
  sumBalances . map currentCycleAccountDebit . currentCycleAccountsRows

currentCycleAccountsCreditTotal :: CurrentCycleAccounts -> Balance
currentCycleAccountsCreditTotal =
  sumBalances . map currentCycleAccountCredit . currentCycleAccountsRows

currentCycleAccountsMovementTotal :: CurrentCycleAccounts -> Balance
currentCycleAccountsMovementTotal =
  sumBalances . map currentCycleAccountRowMovement . currentCycleAccountsRows

currentCycleAccountsClosingTotal :: CurrentCycleAccounts -> Balance
currentCycleAccountsClosingTotal =
  sumBalances . map currentCycleAccountRowClosing . currentCycleAccountsRows

currentCycleAccountsBalanced :: CurrentCycleAccounts -> Bool
currentCycleAccountsBalanced report =
  all isZeroBalance
    [ currentCycleAccountsOpeningTotal report
    , currentCycleAccountsMovementTotal report
    , currentCycleAccountsClosingTotal report
    ]

-- | Observe every declared Account through one day inside an explicit cycle.
--
-- The Account axis comes from the canonical registry, not from whichever
-- Accounts happened to move during the observation. Opening contains all facts
-- before the cycle start. Debit and signed credit lanes contain facts from the
-- cycle start through the inclusive observation day.
currentCycleAccounts
  :: Day
  -> Period
  -> Journal
  -> Either CurrentCycleAccountsError CurrentCycleAccounts
currentCycleAccounts observation period journal
  | not (periodContains period observation) =
      Left (CurrentCycleObservationOutsidePeriod observation)
  | otherwise = Right CurrentCycleAccounts
      { currentCycleAccountsPeriod = period
      , currentCycleAccountsObservation = observation
      , currentCycleAccountsRows =
          [ CurrentCycleAccountRow
              { currentCycleAccount = account
              , currentCycleAccountOpening = accountBalance account opening
              , currentCycleAccountDebit = accountBalance account debit
              , currentCycleAccountCredit = accountBalance account credit
              }
          | declaration <- accountDeclarations (journalAccountRegistry journal)
          , let account = declaredAccount declaration
          ]
      }
  where
    entries = journalEntries journal
    opening = accountBalancesFromEntries
      (filter ((< periodStart period) . entryDate) entries)
    observedEntries = filter observed entries
    debit = accountBalancesFromEntries
      (filter ((> zeroQuantity) . amountQuantity . entryAmount) observedEntries)
    credit = accountBalancesFromEntries
      (filter ((< zeroQuantity) . amountQuantity . entryAmount) observedEntries)

    observed entry =
      entryDate entry >= periodStart period
        && entryDate entry <= observation

-- Cycle comparison

data CycleComparisonPolicy
  = AlignedElapsed
  | CompleteCycles
  deriving (Eq, Show)

data CycleComparisonRow = CycleComparisonRow
  { cycleComparisonAccount          :: Account
  , cycleComparisonCurrentMovement  :: Balance
  , cycleComparisonBaselineMovement :: Balance
  } deriving (Eq, Show)

cycleComparisonRowDifference :: CycleComparisonRow -> Balance
cycleComparisonRowDifference row =
  subtractBalance
    (cycleComparisonCurrentMovement row)
    (cycleComparisonBaselineMovement row)

data CycleComparison = CycleComparison
  { cycleComparisonPolicy       :: CycleComparisonPolicy
  , cycleComparisonCurrent      :: CurrentCycleAccounts
  , cycleComparisonBaseline     :: CurrentCycleAccounts
  , cycleComparisonRows         :: [CycleComparisonRow]
  } deriving (Eq, Show)

data CycleComparisonError
  = CycleComparisonAccountAxisMismatch
  | CycleComparisonElapsedDayCountMismatch Int Int
  | CycleComparisonRequiresCompleteCycles
  deriving (Eq, Show)

cycleComparisonCurrentTotal :: CycleComparison -> Balance
cycleComparisonCurrentTotal =
  sumBalances . map cycleComparisonCurrentMovement . cycleComparisonRows

cycleComparisonBaselineTotal :: CycleComparison -> Balance
cycleComparisonBaselineTotal =
  sumBalances . map cycleComparisonBaselineMovement . cycleComparisonRows

cycleComparisonDifferenceTotal :: CycleComparison -> Balance
cycleComparisonDifferenceTotal =
  sumBalances . map cycleComparisonRowDifference . cycleComparisonRows

cycleComparisonBalanced :: CycleComparison -> Bool
cycleComparisonBalanced report =
  all isZeroBalance
    [ cycleComparisonCurrentTotal report
    , cycleComparisonBaselineTotal report
    , cycleComparisonDifferenceTotal report
    ]

-- | Compare movement across two already admitted cycle observations.
--
-- @AlignedElapsed@ requires the same inclusive number of observed cycle days.
-- @CompleteCycles@ requires both observations to be the final included day of
-- their half-open cycle. Account axes must match exactly before any pairwise
-- difference is published.
cycleComparison
  :: CycleComparisonPolicy
  -> CurrentCycleAccounts
  -> CurrentCycleAccounts
  -> Either CycleComparisonError CycleComparison
cycleComparison policy current baseline = do
  validateComparisonPolicy policy current baseline
  if currentAccounts /= baselineAccounts
    then Left CycleComparisonAccountAxisMismatch
    else Right CycleComparison
      { cycleComparisonPolicy = policy
      , cycleComparisonCurrent = current
      , cycleComparisonBaseline = baseline
      , cycleComparisonRows =
          [ CycleComparisonRow
              { cycleComparisonAccount = account
              , cycleComparisonCurrentMovement =
                  currentCycleAccountRowMovement currentRow
              , cycleComparisonBaselineMovement =
                  currentCycleAccountRowMovement baselineRow
              }
          | currentRow <- currentCycleAccountsRows current
          , let account = currentCycleAccount currentRow
          , Just baselineRow <- [rowFor account baseline]
          ]
      }
  where
    currentAccounts = map currentCycleAccount
      (currentCycleAccountsRows current)
    baselineAccounts = map currentCycleAccount
      (currentCycleAccountsRows baseline)

validateComparisonPolicy
  :: CycleComparisonPolicy
  -> CurrentCycleAccounts
  -> CurrentCycleAccounts
  -> Either CycleComparisonError ()
validateComparisonPolicy policy current baseline = case policy of
  AlignedElapsed
    | currentDays /= baselineDays ->
        Left (CycleComparisonElapsedDayCountMismatch currentDays baselineDays)
    | otherwise -> Right ()
  CompleteCycles
    | not (complete current && complete baseline) ->
        Left CycleComparisonRequiresCompleteCycles
    | otherwise -> Right ()
  where
    currentDays = observedDayCount current
    baselineDays = observedDayCount baseline
    complete report =
      currentCycleAccountsObservation report
        == addDays (-1) (periodEndExclusive (currentCycleAccountsPeriod report))

observedDayCount :: CurrentCycleAccounts -> Int
observedDayCount report =
  fromInteger
    (diffDays
      (currentCycleAccountsObservation report)
      (periodStart (currentCycleAccountsPeriod report))
      + 1)

rowFor :: Account -> CurrentCycleAccounts -> Maybe CurrentCycleAccountRow
rowFor account =
  find ((== account) . currentCycleAccount) . currentCycleAccountsRows

-- Retained Expense movement comparison

-- | One Expense-account coordinate aligned across the two selected periods.
--
-- A canonical empty balance is retained when the account appears in only one
-- period. Delta is derived so it cannot disagree with the two source balances.
data CycleAccountRow = CycleAccountRow
  { cycleAccountRowAccount  :: Account
  , cycleAccountRowCurrent  :: Balance
  , cycleAccountRowPrevious :: Balance
  } deriving (Eq, Show)

cycleAccountRowDelta :: CycleAccountRow -> Balance
cycleAccountRowDelta row =
  subtractBalance
    (cycleAccountRowCurrent row)
    (cycleAccountRowPrevious row)

-- | Exact Expense movement for one current and one previous observation period.
--
-- Declared non-Expense accounts are deliberately outside this report.
-- Programmatically constructed undeclared accounts remain visible as separate
-- evidence instead of being classified from their names.
data CycleAccounts = CycleAccounts
  { cycleAccountsCurrentPeriod     :: Period
  , cycleAccountsPreviousPeriod    :: Period
  , cycleAccountsRows              :: [CycleAccountRow]
  , cycleAccountsUnclassifiedRows  :: [CycleAccountRow]
  } deriving (Eq, Show)

cycleAccountsCurrentTotal :: CycleAccounts -> Balance
cycleAccountsCurrentTotal =
  sumBalances . map cycleAccountRowCurrent . cycleAccountsRows

cycleAccountsPreviousTotal :: CycleAccounts -> Balance
cycleAccountsPreviousTotal =
  sumBalances . map cycleAccountRowPrevious . cycleAccountsRows

cycleAccountsDeltaTotal :: CycleAccounts -> Balance
cycleAccountsDeltaTotal report =
  subtractBalance
    (cycleAccountsCurrentTotal report)
    (cycleAccountsPreviousTotal report)

-- | Compare exact Expense-account movement across two explicit half-open periods.
--
-- The calculation has four semantic stages:
--
-- * select posting-grain facts belonging to each period,
-- * reduce both selections into canonical per-account balances,
-- * align the union of account identities observed in either period,
-- * partition declared Expense rows from undeclared evidence.
--
-- Account rows are published in canonical identity order. Commodity identity
-- remains inside each exact 'Balance'. Cycle definition, resolution, storage,
-- and selection remain outside this pure report; it receives only resolved
-- observation periods.
cycleAccounts :: Period -> Period -> Journal -> CycleAccounts
cycleAccounts currentPeriod previousPeriod journal = CycleAccounts
  { cycleAccountsCurrentPeriod = currentPeriod
  , cycleAccountsPreviousPeriod = previousPeriod
  , cycleAccountsRows = rowsWithType (Just Expense)
  , cycleAccountsUnclassifiedRows = rowsWithType Nothing
  }
  where
    registry = journalAccountRegistry journal
    currentBalances = balancesInPeriod currentPeriod journal
    previousBalances = balancesInPeriod previousPeriod journal
    alignedRows =
      [ CycleAccountRow
          { cycleAccountRowAccount = account
          , cycleAccountRowCurrent = accountBalance account currentBalances
          , cycleAccountRowPrevious = accountBalance account previousBalances
          }
      | account <- Set.toAscList
          (observedAccounts currentBalances previousBalances)
      ]
    rowsWithType accountType =
      [ row
      | row <- alignedRows
      , accountTypeFor (cycleAccountRowAccount row) registry == accountType
      ]

balancesInPeriod :: Period -> Journal -> AccountBalances
balancesInPeriod period =
  accountBalancesFromEntries
    . filter (periodContains period . entryDate)
    . journalEntries

observedAccounts :: AccountBalances -> AccountBalances -> Set Account
observedAccounts current previous =
  Set.fromList
    (map fst (accountBalanceEntries current)
      ++ map fst (accountBalanceEntries previous))
