{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (assertEqual, assertTrue, mustRight)
import Data.List (find)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account (mkAccount)
import HKernel.Actual.Journal
  ( actualJournalValue
  , parseActualJournal
  )
import HKernel.Backing.Identity (mkBackingPoolId)
import HKernel.Budget (Pacing(..))
import HKernel.Budget.Config (parseBudgetPolicy)
import qualified HKernel.Budget.Policy as Budget
import HKernel.Budget.Remaining
  ( budgetRemainingEnvelopes
  , envelopeRemainingBalance
  , envelopeRemainingEnvelope
  )
import HKernel.Envelope.Consumption
  ( consumptionCharges
  , consumptionNet
  , consumptionRefunds
  , envelopeConsumptionFor
  , envelopeConsumptionUnmanaged
  , envelopeConsumptionUnrouted
  )
import HKernel.Envelope.Entitlement
  ( envelopeEntitlementBalance
  )
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoute(..)
  , expenseRouteAt
  )
import HKernel.Envelope.Identity
  ( envelopeRegistryContains
  , mkEnvelopeId
  )
import HKernel.Household.AccountProfile
  ( RetainedBudgetAccountKind(..)
  , mkHouseholdAccountPolicy
  )
import HKernel.Household.BudgetMovement
  ( householdBudgetMovement
  )
import HKernel.Household.BudgetObservation
  ( HouseholdBudgetError(..)
  , deriveHouseholdBudgetObservation
  , deriveHouseholdEnvelopeEntitlement
  , householdBudgetRemaining
  , householdEnvelopeConsumption
  )
import HKernel.Household.Config
  ( HouseholdEnvelopeHistoryReferenceError(..)
  , admitHouseholdEnvelopeHistoryReferences
  , householdConfigurationEnvelopeHistory
  , householdEnvelopeRegistry
  , householdExpenseRoutingHistory
  , parseHouseholdConfiguration
  )
import HKernel.Household.Policy
  ( defineHouseholdEnvelopeCoordinates
  , incomeAnchorCyclePolicy
  , mkHouseholdPolicy
  , validateHouseholdPolicyAccounts
  )
import HKernel.Journal (journalAccountRegistry)
import HKernel.Money
import HKernel.Period (mkPeriod)

main :: IO ()
main = do
  characterizeNativeConsumptionOwnsHouseholdRemaining
  characterizeCanonicalBudgetMovementsProjectNativeEntitlement
  characterizeNativeEntitlementCoordinateMismatchFailsClosed
  characterizeHistoricalEnvelopeSourceAdmission

characterizeNativeConsumptionOwnsHouseholdRemaining :: IO ()
characterizeNativeConsumptionOwnsHouseholdRemaining = do
  let jpy = mustRight (mkCommodity "JPY")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      observedThrough = fromGregorian 2026 8 10
      foodId = mustRight (mkEnvelopeId "food")
      operating = mustRight (mkBackingPoolId "operating")
      cash = mustRight (mkAccount "assets:cash")
      income = mustRight (mkAccount "income:salary")
      foodExpense = mustRight (mkAccount "expenses:food")
      unroutedExpense = mustRight (mkAccount "expenses:unrouted")
      unassigned = mustRight (mkAccount "budget:unassigned")
      foodAllocation = mustRight (mkAccount "budget:food")
      foodLabel = mustRight (Budget.mkEnvelopeLabel "Food")
      budgetPolicy = mustRight
        (Budget.mkBudgetPolicy
          [Budget.defineEnvelope
            foodId foodLabel Daily operating [foodExpense]]
          [Budget.defineBackingPool operating [cash]])
      householdPolicy = mustRight
        (mkHouseholdPolicy
          (incomeAnchorCyclePolicy income)
          budgetPolicy
          [defineHouseholdEnvelopeCoordinates foodId foodAllocation []]
          [unassigned])
      actualJournal = mustRight (parseActualJournal actualSource)
      validatedPolicy = mustRight
        (validateHouseholdPolicyAccounts
          (journalAccountRegistry (actualJournalValue actualJournal))
          householdPolicy)
      movements =
        [ householdBudgetMovement
            (fromGregorian 2026 8 1)
            "fund food"
            unassigned
            foodAllocation
            (mkAmount jpy (quantityFromInteger 150))
        ]
      observation = mustRight
        (deriveHouseholdBudgetObservation
          observedThrough period actualJournal validatedPolicy movements)
      consumption = householdEnvelopeConsumption observation
      foodConsumption = envelopeConsumptionFor foodId consumption
      remaining = householdBudgetRemaining observation
      foodRemaining = mustFindRemaining foodId remaining

  assertEqual
    "native managed charge is retained"
    (one jpy 50)
    (consumptionCharges foodConsumption)
  assertEqual
    "native managed refund is retained"
    (one jpy 10)
    (consumptionRefunds foodConsumption)
  assertEqual
    "native managed net is exact"
    (one jpy 40)
    (consumptionNet foodConsumption)
  assertEqual
    "BudgetRemaining compatibility surface subtracts native managed net"
    (one jpy 110)
    (envelopeRemainingBalance foodRemaining)
  assertEqual
    "unrouted Expense stays attention evidence rather than reducing an Envelope"
    (Just (one jpy 20))
    (consumptionNet <$> Map.lookup unroutedExpense
      (envelopeConsumptionUnrouted consumption))
  assertTrue
    "static compatibility routing never invents explicit unmanaged evidence"
    (Map.null (envelopeConsumptionUnmanaged consumption))

characterizeCanonicalBudgetMovementsProjectNativeEntitlement :: IO ()
characterizeCanonicalBudgetMovementsProjectNativeEntitlement = do
  let jpy = mustRight (mkCommodity "JPY")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      observedThrough = fromGregorian 2026 8 20
      foodId = mustRight (mkEnvelopeId "food")
      travelId = mustRight (mkEnvelopeId "travel")
      operating = mustRight (mkBackingPoolId "operating")
      cash = mustRight (mkAccount "assets:cash")
      income = mustRight (mkAccount "income:salary")
      opening = mustRight (mkAccount "budget:opening")
      unassigned = mustRight (mkAccount "budget:unassigned")
      spent = mustRight (mkAccount "budget:spent")
      food = mustRight (mkAccount "budget:food")
      travel = mustRight (mkAccount "budget:travel")
      foodLabel = mustRight (Budget.mkEnvelopeLabel "Food")
      travelLabel = mustRight (Budget.mkEnvelopeLabel "Travel")
      budgetPolicy = mustRight
        (Budget.mkBudgetPolicy
          [ Budget.defineEnvelope foodId foodLabel Daily operating []
          , Budget.defineEnvelope travelId travelLabel Flex operating []
          ]
          [Budget.defineBackingPool operating [cash]])
      householdPolicy = mustRight
        (mkHouseholdPolicy
          (incomeAnchorCyclePolicy income)
          budgetPolicy
          [ defineHouseholdEnvelopeCoordinates foodId food []
          , defineHouseholdEnvelopeCoordinates travelId travel []
          ]
          [unassigned])
      accountPolicy = mustRight
        (mkHouseholdAccountPolicy
          []
          [ (opening, RetainedOpeningBudgetAccount)
          , (unassigned, RetainedUnassignedBudgetAccount)
          , (spent, RetainedSpentBudgetAccount)
          , (food, RetainedEnvelopeBudgetAccount)
          , (travel, RetainedEnvelopeBudgetAccount)
          ]
          [] [] [])
      movements =
        [ movement jpy (fromGregorian 2026 8 1)
            opening unassigned 100 "capacity seed"
        , movement jpy (fromGregorian 2026 8 2)
            unassigned food 60 "allocate food"
        , movement jpy (fromGregorian 2026 8 2)
            unassigned travel 40 "allocate travel"
        , movement jpy (fromGregorian 2026 8 3)
            food travel 10 "rebalance"
        , movement jpy (fromGregorian 2026 8 4)
            food spent 20 "legacy execution"
        , movement jpy (fromGregorian 2026 8 5)
            spent food 5 "legacy execution reversal"
        , movement jpy (fromGregorian 2026 8 6)
            food unassigned 5 "release"
        , movement jpy (fromGregorian 2026 8 7)
            unassigned food (-5) "signed reverse release"
        , movement jpy (fromGregorian 2026 9 2)
            unassigned food 100 "outside period"
        , movement jpy (fromGregorian 2026 8 8)
            unassigned food 0 "zero movement"
        ]
      entitlement = mustRight
        (deriveHouseholdEnvelopeEntitlement
          observedThrough period householdPolicy accountPolicy movements)

  assertEqual
    "native food entitlement admits allocation/release and excludes spent execution"
    (one jpy 40)
    (envelopeEntitlementBalance foodId entitlement)
  assertEqual
    "native travel entitlement admits allocation and Envelope rebalance"
    (one jpy 50)
    (envelopeEntitlementBalance travelId entitlement)

characterizeNativeEntitlementCoordinateMismatchFailsClosed :: IO ()
characterizeNativeEntitlementCoordinateMismatchFailsClosed = do
  let jpy = mustRight (mkCommodity "JPY")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      observedThrough = fromGregorian 2026 8 20
      foodId = mustRight (mkEnvelopeId "food")
      operating = mustRight (mkBackingPoolId "operating")
      cash = mustRight (mkAccount "assets:cash")
      income = mustRight (mkAccount "income:salary")
      unassigned = mustRight (mkAccount "budget:unassigned")
      food = mustRight (mkAccount "budget:food")
      orphan = mustRight (mkAccount "budget:orphan")
      foodLabel = mustRight (Budget.mkEnvelopeLabel "Food")
      budgetPolicy = mustRight
        (Budget.mkBudgetPolicy
          [Budget.defineEnvelope foodId foodLabel Daily operating []]
          [Budget.defineBackingPool operating [cash]])
      householdPolicy = mustRight
        (mkHouseholdPolicy
          (incomeAnchorCyclePolicy income)
          budgetPolicy
          [defineHouseholdEnvelopeCoordinates foodId food []]
          [unassigned])
      accountPolicy = mustRight
        (mkHouseholdAccountPolicy
          []
          [ (unassigned, RetainedUnassignedBudgetAccount)
          , (food, RetainedEnvelopeBudgetAccount)
          , (orphan, RetainedEnvelopeBudgetAccount)
          ]
          [] [] [])
      result = deriveHouseholdEnvelopeEntitlement
        observedThrough
        period
        householdPolicy
        accountPolicy
        [movement jpy (fromGregorian 2026 8 2)
          unassigned orphan 10 "orphan"]

  assertTrue
    "Budget Envelope kind without Household Envelope coordinate fails closed"
    (case result of
      Left errors ->
        HouseholdEnvelopeEntitlementCoordinateMismatch 1 2
          `elem` NonEmpty.toList errors
      Right _ -> False)

characterizeHistoricalEnvelopeSourceAdmission :: IO ()
characterizeHistoricalEnvelopeSourceAdmission = do
  let budgetPolicy = mustRight (parseBudgetPolicy historicalBudgetConfig)
      configuration = mustRight
        (parseHouseholdConfiguration budgetPolicy historicalHouseholdConfig)
      missingConfiguration = mustRight
        (parseHouseholdConfiguration budgetPolicy historicalMissingRegistryConfig)
      history = mustJust "historical Envelope source" 
        (householdConfigurationEnvelopeHistory configuration)
      missingHistory = mustJust "missing-registry Envelope source"
        (householdConfigurationEnvelopeHistory missingConfiguration)
      actualJournal = mustRight (parseActualJournal actualSource)
      accountRegistry = journalAccountRegistry (actualJournalValue actualJournal)
      admitted = mustRight
        (admitHouseholdEnvelopeHistoryReferences
          accountRegistry budgetPolicy history)
      foodId = mustRight (mkEnvelopeId "food")
      retiredId = mustRight (mkEnvelopeId "retired")
      retiredExpense = mustRight (mkAccount "expenses:unrouted")

  assertTrue
    "stable Registry contains current policy Envelope"
    (envelopeRegistryContains foodId (householdEnvelopeRegistry admitted))
  assertTrue
    "stable Registry retains historical Envelope absent from current policy"
    (envelopeRegistryContains retiredId (householdEnvelopeRegistry admitted))
  assertEqual
    "historical routing validates target through stable Registry, not current policy"
    (Just (ManagedByEnvelope retiredId))
    (expenseRouteAt
      (fromGregorian 2026 8 10)
      retiredExpense
      (householdExpenseRoutingHistory admitted))

  assertTrue
    "current policy Envelope missing from stable Registry fails closed"
    (case admitHouseholdEnvelopeHistoryReferences
        accountRegistry budgetPolicy missingHistory of
      Left errors ->
        CurrentPolicyEnvelopeMissingFromRegistry foodId
          `elem` NonEmpty.toList errors
      Right _ -> False)

actualSource :: T.Text
actualSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "account income:salary"
  , "  type: Income"
  , "account expenses:food"
  , "  type: Expense"
  , "account expenses:unrouted"
  , "  type: Expense"
  , "account budget:unassigned"
  , "  type: Budget"
  , "account budget:food"
  , "  type: Budget"
  , ""
  , "2026-08-01 salary"
  , "  assets:cash  200 JPY"
  , "  income:salary  -200 JPY"
  , ""
  , "2026-08-02 food charge"
  , "  expenses:food  50 JPY"
  , "  assets:cash  -50 JPY"
  , ""
  , "2026-08-03 food refund"
  , "  expenses:food  -10 JPY"
  , "  assets:cash  10 JPY"
  , ""
  , "2026-08-04 unrouted charge"
  , "  expenses:unrouted  20 JPY"
  , "  assets:cash  -20 JPY"
  ]

historicalBudgetConfig :: T.Text
historicalBudgetConfig = T.unlines
  [ "[[backing-pools]]"
  , "id = \"operating\""
  , "asset-accounts = [\"assets:cash\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"food\""
  , "label = \"Food\""
  , "pacing = \"daily\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"expenses:food\"]"
  ]

historicalHouseholdConfig :: T.Text
historicalHouseholdConfig = historicalHouseholdConfigWithIdentities
  "[\"food\", \"retired\"]"

historicalMissingRegistryConfig :: T.Text
historicalMissingRegistryConfig = historicalHouseholdConfigWithIdentities
  "[\"retired\"]"

historicalHouseholdConfigWithIdentities :: T.Text -> T.Text
historicalHouseholdConfigWithIdentities identities = T.unlines
  [ "[cycle]"
  , "mode = \"income-anchor\""
  , "income-account = \"income:salary\""
  , ""
  , "[budget]"
  , "unassigned-accounts = [\"budget:unassigned\"]"
  , ""
  , "[[budget.envelopes]]"
  , "id = \"food\""
  , "allocation-account = \"budget:food\""
  , ""
  , "[envelope-history]"
  , "identities = " <> identities
  , ""
  , "[[envelope-history.expense-routing]]"
  , "effective-from = \"2026-08-01\""
  , "expense-account = \"expenses:food\""
  , "route = \"managed\""
  , "target = \"food\""
  , "note = \"current route\""
  , ""
  , "[[envelope-history.expense-routing]]"
  , "effective-from = \"2026-08-02\""
  , "expense-account = \"expenses:unrouted\""
  , "route = \"managed\""
  , "target = \"retired\""
  , "note = \"historical route\""
  ]

movement commodity day fromAccount toAccount quantity note =
  householdBudgetMovement
    day note fromAccount toAccount
    (mkAmount commodity (quantityFromInteger quantity))

mustFindRemaining envelope remaining =
  case find ((== envelope) . envelopeRemainingEnvelope)
      (budgetRemainingEnvelopes remaining) of
    Just value -> value
    Nothing -> error "invalid test fixture: expected Envelope remaining"

mustJust :: String -> Maybe value -> value
mustJust _ (Just value) = value
mustJust label Nothing = error ("invalid test fixture: expected " ++ label)

one :: Commodity -> Integer -> Balance
one commodity value =
  singletonBalance (mkAmount commodity (quantityFromInteger value))
