{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (assertEqual, assertTrue, mustRight)
import Data.List (find)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account (accountName, mkAccount)
import HKernel.Actual.Journal (ActualJournal, parseActualJournal)
import HKernel.Backing.Identity (mkBackingPoolId)
import HKernel.Budget
  ( EnvelopeId
  , Pacing(..)
  , mkEnvelopeId
  )
import qualified HKernel.Budget.Consumption as LegacyBudget
import HKernel.Budget.Consumption
  ( BudgetConsumption
  , budgetConsumptionEnvelopes
  , budgetConsumptionUnassignedExpenses
  , envelopeConsumptionBalance
  , envelopeConsumptionCharges
  , envelopeConsumptionEnvelope
  , envelopeConsumptionRefunds
  , unassignedExpenseAccount
  , unassignedExpenseBalance
  )
import HKernel.Budget.Policy
  ( defineBackingPool
  , defineEnvelope
  , mkBudgetPolicy
  , mkEnvelopeLabel
  )
import HKernel.Envelope.Consumption
  ( EnvelopeConsumption
  , consumptionCharges
  , consumptionNet
  , consumptionRefunds
  , envelopeConsumptionFor
  , envelopeConsumptionUnmanaged
  , envelopeConsumptionUnrouted
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.BudgetObservation
  ( deriveHouseholdBudgetObservation
  , householdBudgetConsumption
  , householdEnvelopeConsumption
  )
import HKernel.Household.Policy
  ( AccountValidatedHouseholdPolicy
  , HouseholdPolicy
  , defineHouseholdEnvelopeCoordinates
  , incomeAnchorCyclePolicy
  , mkHouseholdPolicy
  , validateHouseholdPolicyAccounts
  )
import HKernel.Journal (journalAccountRegistry, parseJournal)
import HKernel.Money
  ( Commodity
  , emptyBalance
  , mkAmount
  , mkCommodity
  , quantityFromInteger
  )
import HKernel.Period (Period, mkPeriod)

main :: IO ()
main = do
  characterizeHouseholdBudgetObservationEquivalence
  characterizeUntouchedEnvelopeZeroSemantics
  characterizeReversalChainAndRefundEquivalence
  characterizePeriodBoundaryObservations

characterizeHouseholdBudgetObservationEquivalence :: IO ()
characterizeHouseholdBudgetObservationEquivalence = do
  let obsDay = fromGregorian 2026 8 15
      householdObs = mustRight
        (deriveHouseholdBudgetObservation
          obsDay
          testPeriod
          testActualJournal
          testValidatedPolicy
          testMovements)
      legacy = householdBudgetConsumption householdObs
      native = householdEnvelopeConsumption householdObs

  assertEquivalenceLaws
    "comprehensive observation at mid-period"
    testValidatedPolicy
    legacy
    native

characterizeUntouchedEnvelopeZeroSemantics :: IO ()
characterizeUntouchedEnvelopeZeroSemantics = do
  let obsDay = fromGregorian 2026 8 15
      householdObs = mustRight
        (deriveHouseholdBudgetObservation
          obsDay
          testPeriod
          testActualJournal
          testValidatedPolicy
          testMovements)
      legacy = householdBudgetConsumption householdObs
      native = householdEnvelopeConsumption householdObs
      untouchedId = mustRight (mkEnvelopeId "untouched")
      legacyUntouched = mustFindEnvelope untouchedId legacy
      nativeUntouched = envelopeConsumptionFor untouchedId native

  assertEqual
    "untouched Envelope has empty legacy charges"
    emptyBalance
    (envelopeConsumptionCharges legacyUntouched)
  assertEqual
    "untouched Envelope has empty legacy refunds"
    emptyBalance
    (envelopeConsumptionRefunds legacyUntouched)
  assertEqual
    "untouched Envelope has empty legacy net balance"
    emptyBalance
    (envelopeConsumptionBalance legacyUntouched)
  assertEqual
    "untouched Envelope has empty native charges"
    emptyBalance
    (consumptionCharges nativeUntouched)
  assertEqual
    "untouched Envelope has empty native refunds"
    emptyBalance
    (consumptionRefunds nativeUntouched)
  assertEqual
    "untouched Envelope has empty native net balance"
    emptyBalance
    (consumptionNet nativeUntouched)

characterizeReversalChainAndRefundEquivalence :: IO ()
characterizeReversalChainAndRefundEquivalence = do
  let obsDay = fromGregorian 2026 8 6
      householdObs = mustRight
        (deriveHouseholdBudgetObservation
          obsDay
          testPeriod
          testActualJournal
          testValidatedPolicy
          testMovements)
      legacy = householdBudgetConsumption householdObs
      native = householdEnvelopeConsumption householdObs
      livingId = mustRight (mkEnvelopeId "living")
      utilitiesId = mustRight (mkEnvelopeId "utilities")
      legacyLiving = mustFindEnvelope livingId legacy
      nativeLiving = envelopeConsumptionFor livingId native
      legacyUtilities = mustFindEnvelope utilitiesId legacy
      nativeUtilities = envelopeConsumptionFor utilitiesId native

  assertEqual
    "living charges match through reversal chain and multi-commodity"
    (envelopeConsumptionCharges legacyLiving)
    (consumptionCharges nativeLiving)
  assertEqual
    "living refunds match through reversal chain and multi-commodity"
    (envelopeConsumptionRefunds legacyLiving)
    (consumptionRefunds nativeLiving)
  assertEqual
    "living net matches through reversal chain and multi-commodity"
    (envelopeConsumptionBalance legacyLiving)
    (consumptionNet nativeLiving)

  assertEqual
    "utilities charges match with ordinary refund"
    (envelopeConsumptionCharges legacyUtilities)
    (consumptionCharges nativeUtilities)
  assertEqual
    "utilities refunds match with ordinary refund"
    (envelopeConsumptionRefunds legacyUtilities)
    (consumptionRefunds nativeUtilities)
  assertEqual
    "utilities net matches with ordinary refund"
    (envelopeConsumptionBalance legacyUtilities)
    (consumptionNet nativeUtilities)

characterizePeriodBoundaryObservations :: IO ()
characterizePeriodBoundaryObservations = do
  let observationDays =
        [ fromGregorian 2026 8 1
        , fromGregorian 2026 8 3
        , fromGregorian 2026 8 5
        , fromGregorian 2026 8 15
        , fromGregorian 2026 8 25
        , fromGregorian 2026 8 31
        ]
  mapM_ verifyAtDay observationDays
  where
    verifyAtDay day = do
      let householdObs = mustRight
            (deriveHouseholdBudgetObservation
              day
              testPeriod
              testActualJournal
              testValidatedPolicy
              testMovements)
          legacy = householdBudgetConsumption householdObs
          native = householdEnvelopeConsumption householdObs
      assertEquivalenceLaws
        ("boundary observation at " ++ show day)
        testValidatedPolicy
        legacy
        native

assertEquivalenceLaws
  :: String
  -> AccountValidatedHouseholdPolicy
  -> BudgetConsumption
  -> EnvelopeConsumption
  -> IO ()
assertEquivalenceLaws context _validatedPolicy legacy native = do
  let policyEnvelopes =
        [ mustRight (mkEnvelopeId "living")
        , mustRight (mkEnvelopeId "utilities")
        , mustRight (mkEnvelopeId "untouched")
        ]
  mapM_ verifyEnvelope policyEnvelopes
  verifyUnassignedAndUnrouted
  assertTrue
    (context ++ ": native unmanaged is empty under static legacy routing")
    (Map.null (envelopeConsumptionUnmanaged native))
  where
    verifyEnvelope envId = do
      let legacyEnv = mustFindEnvelope envId legacy
          nativeAmounts = envelopeConsumptionFor envId native
      assertEqual
        (context ++ " [" ++ show envId ++ "]: charges match")
        (envelopeConsumptionCharges legacyEnv)
        (consumptionCharges nativeAmounts)
      assertEqual
        (context ++ " [" ++ show envId ++ "]: refunds match")
        (envelopeConsumptionRefunds legacyEnv)
        (consumptionRefunds nativeAmounts)
      assertEqual
        (context ++ " [" ++ show envId ++ "]: net consumption matches")
        (envelopeConsumptionBalance legacyEnv)
        (consumptionNet nativeAmounts)

    verifyUnassignedAndUnrouted = do
      let legacyUnassigned = budgetConsumptionUnassignedExpenses legacy
          nativeUnrouted = envelopeConsumptionUnrouted native
      -- For every legacy unassigned expense, net matches native unrouted net
      mapM_
        (\unassigned -> do
          let acc = unassignedExpenseAccount unassigned
              expected = unassignedExpenseBalance unassigned
              actualAmounts = Map.findWithDefault mempty acc nativeUnrouted
              actualNet = consumptionNet actualAmounts
          assertEqual
            (context ++ " [unassigned " ++ T.unpack (accountName acc) ++ "]: net matches")
            expected
            actualNet)
        legacyUnassigned
      -- For every native unrouted entry, net matches legacy unassigned
      mapM_
        (\(acc, amounts) -> do
          let actualNet = consumptionNet amounts
              legacyMatch = find ((== acc) . unassignedExpenseAccount) legacyUnassigned
              expectedNet = maybe emptyBalance unassignedExpenseBalance legacyMatch
          assertEqual
            (context ++ " [unrouted " ++ T.unpack (accountName acc) ++ "]: net matches")
            expectedNet
            actualNet)
        (Map.toAscList nativeUnrouted)

mustFindEnvelope :: EnvelopeId -> BudgetConsumption -> LegacyBudget.EnvelopeConsumption
mustFindEnvelope envId consumption =
  case find ((== envId) . envelopeConsumptionEnvelope) (budgetConsumptionEnvelopes consumption) of
    Just env -> env
    Nothing -> error ("Envelope not found in legacy consumption: " ++ show envId)

testPeriod :: Period
testPeriod = mustRight
  (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))

jpy :: Commodity
jpy = mustRight (mkCommodity "JPY")

testActualJournal :: ActualJournal
testActualJournal = mustRight (parseActualJournal actualJournalSource)

testValidatedPolicy :: AccountValidatedHouseholdPolicy
testValidatedPolicy = mustRight
  (validateHouseholdPolicyAccounts registry baseHouseholdPolicy)
  where
    registry = journalAccountRegistry (mustRight (parseJournal actualJournalSource))

testMovements :: [HouseholdBudgetMovement]
testMovements =
  [ HouseholdBudgetMovement
      { householdBudgetMovementDate = fromGregorian 2026 8 1
      , householdBudgetMovementFrom = mustRight (mkAccount "income:salary")
      , householdBudgetMovementTo = mustRight (mkAccount "budget:living")
      , householdBudgetMovementAmount = mkAmount jpy (quantityFromInteger 1000)
      , householdBudgetMovementMemo = "Living allocation"
      }
  , HouseholdBudgetMovement
      { householdBudgetMovementDate = fromGregorian 2026 8 1
      , householdBudgetMovementFrom = mustRight (mkAccount "income:salary")
      , householdBudgetMovementTo = mustRight (mkAccount "budget:utilities")
      , householdBudgetMovementAmount = mkAmount jpy (quantityFromInteger 500)
      , householdBudgetMovementMemo = "Utilities allocation"
      }
  ]

baseHouseholdPolicy :: HouseholdPolicy
baseHouseholdPolicy = mustRight (mkHouseholdPolicy cyclePolicy budgetPolicy envelopeOrder unassignedAccounts)
  where
    cyclePolicy = incomeAnchorCyclePolicy (mustRight (mkAccount "income:salary"))
    poolId = mustRight (mkBackingPoolId "cash")
    budgetPolicy = mustRight (mkBudgetPolicy
      [ defineEnvelope
          (mustRight (mkEnvelopeId "living"))
          (mustRight (mkEnvelopeLabel "Living"))
          Daily
          poolId
          [mustRight (mkAccount "expenses:living:food"), mustRight (mkAccount "expenses:living:grocery")]
      , defineEnvelope
          (mustRight (mkEnvelopeId "utilities"))
          (mustRight (mkEnvelopeLabel "Utilities"))
          Flex
          poolId
          [mustRight (mkAccount "expenses:utilities:electric")]
      , defineEnvelope
          (mustRight (mkEnvelopeId "untouched"))
          (mustRight (mkEnvelopeLabel "Untouched"))
          Flex
          poolId
          [mustRight (mkAccount "expenses:untouched")]
      ]
      [defineBackingPool poolId [mustRight (mkAccount "assets:cash")]])
    envelopeOrder =
      [ defineHouseholdEnvelopeCoordinates
          (mustRight (mkEnvelopeId "living"))
          (mustRight (mkAccount "budget:living"))
          []
      , defineHouseholdEnvelopeCoordinates
          (mustRight (mkEnvelopeId "utilities"))
          (mustRight (mkAccount "budget:utilities"))
          []
      , defineHouseholdEnvelopeCoordinates
          (mustRight (mkEnvelopeId "untouched"))
          (mustRight (mkAccount "budget:untouched"))
          []
      ]
    unassignedAccounts = [mustRight (mkAccount "budget:unassigned")]

actualJournalSource :: T.Text
actualJournalSource = declarations <> T.unlines
  [ "2026-07-31 * prior month expense outside period"
  , "  assets:cash                -99 JPY"
  , "  expenses:living:food        99 JPY"
  , ""
  , "2026-08-01 * start of period grocery root"
  , "  ; event-id: grocery-root"
  , "  assets:cash                -50 JPY"
  , "  expenses:living:grocery     50 JPY"
  , ""
  , "2026-08-02 * multi-commodity food charge"
  , "  assets:cash               -100 JPY"
  , "  assets:cash-usd             -5 USD"
  , "  expenses:living:food       100 JPY"
  , "  expenses:living:food         5 USD"
  , ""
  , "2026-08-03 * ordinary food refund"
  , "  assets:cash                 20 JPY"
  , "  expenses:living:food       -20 JPY"
  , ""
  , "2026-08-03 * utilities charge"
  , "  assets:cash                -80 JPY"
  , "  expenses:utilities:electric    80 JPY"
  , ""
  , "2026-08-04 * reverse grocery root"
  , "  ; event-id: grocery-rev-1"
  , "  ; reverses: grocery-root"
  , "  expenses:living:grocery    -50 JPY"
  , "  assets:cash                 50 JPY"
  , ""
  , "2026-08-05 * re-reverse grocery"
  , "  ; event-id: grocery-rev-2"
  , "  ; reverses: grocery-rev-1"
  , "  assets:cash                -50 JPY"
  , "  expenses:living:grocery     50 JPY"
  , ""
  , "2026-08-06 * utilities ordinary refund"
  , "  assets:cash                 10 JPY"
  , "  expenses:utilities:electric   -10 JPY"
  , ""
  , "2026-08-08 * unassigned medical charge"
  , "  assets:cash                -30 JPY"
  , "  expenses:medical            30 JPY"
  , ""
  , "2026-08-10 * unassigned zero-net charge"
  , "  assets:cash                -25 JPY"
  , "  expenses:zero-net           25 JPY"
  , ""
  , "2026-08-12 * unassigned zero-net refund"
  , "  assets:cash                 25 JPY"
  , "  expenses:zero-net          -25 JPY"
  , ""
  , "2026-08-20 * late period food charge"
  , "  assets:cash                -40 JPY"
  , "  expenses:living:food        40 JPY"
  , ""
  , "2026-09-01 * boundary next period excluded"
  , "  assets:cash                -77 JPY"
  , "  expenses:living:food        77 JPY"
  ]

declarations :: T.Text
declarations = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account assets:cash-usd"
  , "  type: Asset"
  , "  commodity: USD"
  , ""
  , "account income:salary"
  , "  type: Income"
  , "  commodity: JPY"
  , ""
  , "account budget:living"
  , "  type: Budget"
  , "  commodity: JPY"
  , ""
  , "account budget:utilities"
  , "  type: Budget"
  , "  commodity: JPY"
  , ""
  , "account budget:untouched"
  , "  type: Budget"
  , "  commodity: JPY"
  , ""
  , "account budget:unassigned"
  , "  type: Budget"
  , "  commodity: JPY"
  , ""
  , "account expenses:living:food"
  , "  type: Expense"
  , ""
  , "account expenses:living:grocery"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "account expenses:utilities:electric"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "account expenses:untouched"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "account expenses:medical"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "account expenses:zero-net"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  ]
