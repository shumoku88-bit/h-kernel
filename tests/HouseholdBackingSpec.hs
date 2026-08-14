{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account (mkAccount)
import HKernel.Actual.Journal (actualJournalValue, parseActualJournal)
import HKernel.Backing
import HKernel.Backing.Identity
import HKernel.Backing.Policy
  ( assignEnvelopeBackingPool
  , backingPolicyEnvelopeAssignments
  , backingPolicyPoolDefinitions
  , backingPolicyPoolForAsset
  , backingPolicyPoolForEnvelope
  , defineBackingPool
  )
import HKernel.Budget
  ( Pacing(..)
  , mkBudgetChange
  , mkBudgetCycle
  , mkBudgetObservation
  )
import HKernel.Budget.Consumption (calculateBudgetConsumption)
import HKernel.Budget.Entitlement (calculateBudgetEntitlement)
import HKernel.Budget.History (mkBudgetHistory)
import qualified HKernel.Budget.Policy as Budget
import HKernel.Budget.Remaining (calculateBudgetRemaining)
import HKernel.Envelope.Consumption
  ( ConsumptionAmounts(ConsumptionAmounts)
  , consumptionCharges
  , consumptionRefunds
  , envelopeConsumptionUnmanaged
  , observeEnvelopeConsumption
  )
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoute(..)
  , ExpenseRouteResolver(..)
  )
import HKernel.Envelope.Identity (mkEnvelopeId)
import HKernel.Household.Backing
import HKernel.Household.Policy
import HKernel.Journal (journalAccountRegistry)
import HKernel.Money
import HKernel.Period
import HKernel.Plan (mkPositiveAmount)
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeHouseholdBackingLines
  characterizeBudgetPolicyCompatibilityProjection
  characterizeHouseholdBackingDerivation
  characterizeHouseholdBackingNativeConsumptionRouting

characterizeHouseholdBackingLines :: IO ()
characterizeHouseholdBackingLines = do
  let jpy = mustRight (mkCommodity "JPY")
      usd = mustRight (mkCommodity "USD")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      foodId = mustRight (mkEnvelopeId "food")
      travelId = mustRight (mkEnvelopeId "travel")
      cashPoolId = mustRight (mkBackingPoolId "cash")
      reservePoolId = mustRight (mkBackingPoolId "reserve")
      food = EnvelopeBackingLine
        { envelopeBackingName = "Food"
        , envelopeEntitlement = one jpy 150
        , envelopeActualConsumption = one jpy 30
        , envelopeActualRefunds = mempty
        , envelopeBudgetRemaining = one jpy 120 <> one usd (-5)
        , envelopeOpenPlanReserve = one jpy 30
        }
      travel = EnvelopeBackingLine
        { envelopeBackingName = "Travel"
        , envelopeEntitlement = one usd 3
        , envelopeActualConsumption = one jpy 20
        , envelopeActualRefunds = mempty
        , envelopeBudgetRemaining = one jpy (-20) <> one usd 3
        , envelopeOpenPlanReserve = mempty
        }
      cashPool = mustRight (deriveBackingPoolPosition
        cashPoolId
        (one jpy 100)
        (one jpy 40)
        [ BackedEnvelopeClaim
            { backedEnvelopeId = foodId
            , backedEnvelopeRemaining = envelopeLedgerRemaining food
            , backedEnvelopeHeadroom = envelopePostPlanHeadroom food
            }
        ])
      reservePool = mustRight (deriveBackingPoolPosition
        reservePoolId
        (one jpy 150 <> one usd 4)
        mempty
        [ BackedEnvelopeClaim
            { backedEnvelopeId = travelId
            , backedEnvelopeRemaining = envelopeLedgerRemaining travel
            , backedEnvelopeHeadroom = envelopePostPlanHeadroom travel
            }
        ])
      report = EnvelopeBacking
        { envelopeBackingPeriod = period
        , envelopeBackingObservedOn = fromGregorian 2026 8 10
        , envelopeBackingLines = [food, travel]
        , envelopeBackingPools = [cashPool, reservePool]
        , envelopeLedgerUnassigned = one jpy 10 <> one usd 1
        , envelopeUnassignedExpenses = []
        }

  assertEqual
    "signed total preserves overspent and positive envelope evidence"
    (one jpy 100 <> one usd (-2))
    (envelopeSignedTotal report)
  assertEqual
    "native pool positions preserve aggregate funding without becoming one owner"
    (one jpy 250 <> one usd 4)
    (envelopeFundingBalance report)
  assertEqual
    "Backing required does not let negative envelopes cancel positive claims"
    (one jpy 120 <> one usd 3)
    (envelopeBackingRequired report)
  assertEqual
    "gross Household summary remains available"
    (one jpy 130 <> one usd 1)
    (envelopeBackingSurplus report)
  assertEqual
    "available Household summary includes source funding and Envelope commitments"
    (one jpy 120 <> one usd 1)
    (envelopeAvailableBackingSurplus report)
  assertEqual
    "reconciliation subtracts unassigned Budget evidence and normalizes zero"
    (one jpy 120)
    (envelopeReconciliationDelta report)
  assertEqual
    "post-Plan headroom remains distinct from ledger remaining"
    (one jpy 90 <> one usd (-5))
    (envelopePostPlanHeadroom food)
  assertEqual
    "pool-local shortage survives despite another pool's surplus"
    (one jpy (-20))
    (backingPoolGrossSurplus cashPool)
  assertEqual
    "pool-local available shortage keeps source funding commitment separate"
    (one jpy (-30))
    (backingPoolAvailableSurplus cashPool)
  assertEqual
    "another pool keeps its independent surplus coordinates"
    (one jpy 150 <> one usd 1)
    (backingPoolAvailableSurplus reservePool)

characterizeBudgetPolicyCompatibilityProjection :: IO ()
characterizeBudgetPolicyCompatibilityProjection = do
  let operating = mustRight (mkBackingPoolId "operating")
      reserve = mustRight (mkBackingPoolId "reserve")
      food = mustRight (mkEnvelopeId "food")
      savings = mustRight (mkEnvelopeId "savings")
      cash = mustRight (mkAccount "assets:cash")
      bank = mustRight (mkAccount "assets:bank")
      income = mustRight (mkAccount "income:salary")
      unassigned = mustRight (mkAccount "budget:unassigned")
      foodAlloc = mustRight (mkAccount "budget:food")
      savingsAlloc = mustRight (mkAccount "budget:savings")
      foodExpense = mustRight (mkAccount "expenses:food")
      foodLabel = mustRight (Budget.mkEnvelopeLabel "Food")
      savingsLabel = mustRight (Budget.mkEnvelopeLabel "Savings")
      -- Intentionally reverse input order to characterize that compatibility
      -- projection extracts in Map canonical key order rather than legacy source order.
      budgetPools =
        [ Budget.defineBackingPool reserve [bank]
        , Budget.defineBackingPool operating [cash]
        ]
      budgetEnvelopes =
        [ Budget.defineEnvelope savings savingsLabel Flex reserve []
        , Budget.defineEnvelope food foodLabel Daily operating [foodExpense]
        ]
      budgetPolicy = mustRight (Budget.mkBudgetPolicy budgetEnvelopes budgetPools)
      coords =
        [ defineHouseholdEnvelopeCoordinates food foodAlloc []
        , defineHouseholdEnvelopeCoordinates savings savingsAlloc []
        ]
      householdPolicy = mustRight
        (mkHouseholdPolicy
          (incomeAnchorCyclePolicy income)
          budgetPolicy
          coords
          [unassigned])
      projectedBackingPolicy = householdBackingPolicy householdPolicy

  assertEqual "projected policy preserves Envelope backing lookup"
    (Just operating)
    (backingPolicyPoolForEnvelope food projectedBackingPolicy)
  assertEqual "projected policy preserves another Envelope backing lookup"
    (Just reserve)
    (backingPolicyPoolForEnvelope savings projectedBackingPolicy)
  assertEqual "projected policy preserves Asset pool membership lookup"
    (Just operating)
    (backingPolicyPoolForAsset cash projectedBackingPolicy)
  assertEqual "projected policy preserves another Asset pool membership lookup"
    (Just reserve)
    (backingPolicyPoolForAsset bank projectedBackingPolicy)
  assertEqual "projected policy extracts pool definitions in Map canonical key order"
    [ defineBackingPool operating [cash]
    , defineBackingPool reserve [bank]
    ]
    (backingPolicyPoolDefinitions projectedBackingPolicy)
  assertEqual "projected policy extracts envelope assignments in Map canonical key order"
    [ assignEnvelopeBackingPool food operating
    , assignEnvelopeBackingPool savings reserve
    ]
    (backingPolicyEnvelopeAssignments projectedBackingPolicy)

characterizeHouseholdBackingDerivation :: IO ()
characterizeHouseholdBackingDerivation = do
  let jpy = mustRight (mkCommodity "JPY")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      obsDay = fromGregorian 2026 8 10
      foodId = mustRight (mkEnvelopeId "food")
      travelId = mustRight (mkEnvelopeId "travel")
      cashPoolId = mustRight (mkBackingPoolId "cash")
      reservePoolId = mustRight (mkBackingPoolId "reserve")
      cash = mustRight (mkAccount "assets:cash")
      bank = mustRight (mkAccount "assets:bank")
      income = mustRight (mkAccount "income:salary")
      unassigned = mustRight (mkAccount "budget:unassigned")
      foodAlloc = mustRight (mkAccount "budget:food")
      travelAlloc = mustRight (mkAccount "budget:travel")
      foodExpense = mustRight (mkAccount "expenses:food")
      travelExpense = mustRight (mkAccount "expenses:travel")
      foodLabel = mustRight (Budget.mkEnvelopeLabel "Food")
      travelLabel = mustRight (Budget.mkEnvelopeLabel "Travel")

      budgetPools =
        [ Budget.defineBackingPool cashPoolId [cash]
        , Budget.defineBackingPool reservePoolId [bank]
        ]
      budgetEnvelopes =
        [ Budget.defineEnvelope foodId foodLabel Daily cashPoolId [foodExpense]
        , Budget.defineEnvelope travelId travelLabel Flex reservePoolId [travelExpense]
        ]
      budgetPolicy = mustRight (Budget.mkBudgetPolicy budgetEnvelopes budgetPools)

      coords =
        [ defineHouseholdEnvelopeCoordinates foodId foodAlloc []
        , defineHouseholdEnvelopeCoordinates travelId travelAlloc []
        ]
      householdPolicy = mustRight
        (mkHouseholdPolicy
          (incomeAnchorCyclePolicy income)
          budgetPolicy
          coords
          [unassigned])

      journalSource = T.unlines
        [ "account assets:cash"
        , "  type: Asset"
        , "account assets:bank"
        , "  type: Asset"
        , "account income:salary"
        , "  type: Income"
        , "account expenses:food"
        , "  type: Expense"
        , "account expenses:travel"
        , "  type: Expense"
        , "account budget:unassigned"
        , "  type: Budget"
        , "account budget:food"
        , "  type: Budget"
        , "account budget:travel"
        , "  type: Budget"
        , ""
        , "2026-08-01 salary"
        , "  assets:cash  100 JPY"
        , "  assets:bank  300 JPY"
        , "  income:salary  -400 JPY"
        , ""
        , "2026-08-02 expenses"
        , "  expenses:food  30 JPY"
        , "  expenses:travel  50 JPY"
        , "  assets:cash  -30 JPY"
        , "  assets:bank  -50 JPY"
        ]
      actualJournal = mustRight (parseActualJournal journalSource)
      journal = actualJournalValue actualJournal
      cycleVal = mustRight
        (mkBudgetCycle (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      obs = mustRight (mkBudgetObservation cycleVal obsDay)
      history = mustRight (mkBudgetHistory
        [ mustRight (mkBudgetChange (fromGregorian 2026 8 1) cycleVal foodId (mkAmount jpy (quantityFromInteger 150)) "food entitlement")
        , mustRight (mkBudgetChange (fromGregorian 2026 8 1) cycleVal travelId (mkAmount jpy (quantityFromInteger 200)) "travel entitlement")
        ])
      validatedBudget = mustRight
        (Budget.validateBudgetPolicyAccounts
          (HKernel.Journal.journalAccountRegistry journal)
          budgetPolicy)
      legacyConsumption = mustRight
        (calculateBudgetConsumption obs validatedBudget journal)
      envelopeConsumption = mustRight
        (observeEnvelopeConsumption period obsDay actualJournal
          (ExpenseRouteResolver (\_day acc ->
            case Budget.budgetPolicyEnvelopeForExpense acc budgetPolicy of
              Just env -> Just (ManagedByEnvelope env)
              Nothing  -> Nothing)))
      entitlement = mustRight
        (calculateBudgetEntitlement obs budgetPolicy history)
      remaining = mustRight
        (calculateBudgetRemaining entitlement legacyConsumption)

      plans =
        [ HouseholdBackingPlan
            { householdBackingPlanSource = cash
            , householdBackingPlanDestination = foodAlloc
            , householdBackingPlanAmount =
                mustRight (mkPositiveAmount (mkAmount jpy (quantityFromInteger 30)))
            }
        ]

      backingResult = mustRight
        (deriveHouseholdBacking
          obsDay
          period
          journal
          householdPolicy
          []
          entitlement
          envelopeConsumption
          remaining
          plans)

  assertEqual
    "derived backing contains native pool positions"
    2
    (length (envelopeBackingPools backingResult))
  assertEqual
    "derived funding balance matches journal assets"
    (one jpy 320)
    (envelopeFundingBalance backingResult)
  assertEqual
    "derived backing required sums pool gross requirements"
    (one jpy 270)
    (envelopeBackingRequired backingResult)
  assertEqual
    "derived backing gross surplus matches aggregate"
    (one jpy 50)
    (envelopeBackingSurplus backingResult)
  assertEqual
    "derived backing available surplus matches aggregate"
    (one jpy 50)
    (envelopeAvailableBackingSurplus backingResult)

  case envelopeBackingLines backingResult of
    [foodLine, travelLine] -> do
      assertEqual
        "food line receives actual consumption"
        (one jpy 30)
        (envelopeActualConsumption foodLine)
      assertEqual
        "food line receives actual refunds"
        mempty
        (envelopeActualRefunds foodLine)
      assertEqual
        "travel line receives actual consumption"
        (one jpy 50)
        (envelopeActualConsumption travelLine)
      assertEqual
        "travel line receives actual refunds"
        mempty
        (envelopeActualRefunds travelLine)
    _ -> failTest "derived lines layout" "expected exactly two envelope backing lines [foodLine, travelLine]"

  case envelopeBackingPools backingResult of
    [cashPoolPos, reservePoolPos] -> do
      assertEqual
        "cash pool funding balance matches cash asset"
        (one jpy 70)
        (backingPoolFundingBalance cashPoolPos)
      assertEqual
        "cash pool funding commitment matches open plan source"
        (one jpy 30)
        (backingPoolFundingCommitment cashPoolPos)
      assertEqual
        "cash pool available funding subtracts commitment"
        (one jpy 40)
        (backingPoolAvailableFunding cashPoolPos)
      assertEqual
        "cash pool gross required receives food envelope remaining"
        (one jpy 120)
        (backingPoolGrossEnvelopeRequired cashPoolPos)
      assertEqual
        "cash pool available required receives food envelope headroom after plan reserve"
        (one jpy 90)
        (backingPoolAvailableEnvelopeRequired cashPoolPos)
      assertEqual
        "cash pool gross surplus reflects local shortage"
        (one jpy (-50))
        (backingPoolGrossSurplus cashPoolPos)
      assertEqual
        "cash pool available surplus preserves local shortage"
        (one jpy (-50))
        (backingPoolAvailableSurplus cashPoolPos)

      assertEqual
        "reserve pool funding balance matches bank asset"
        (one jpy 250)
        (backingPoolFundingBalance reservePoolPos)
      assertEqual
        "reserve pool funding commitment is zero"
        mempty
        (backingPoolFundingCommitment reservePoolPos)
      assertEqual
        "reserve pool available funding equals funding balance"
        (one jpy 250)
        (backingPoolAvailableFunding reservePoolPos)
      assertEqual
        "reserve pool gross required receives travel envelope remaining"
        (one jpy 150)
        (backingPoolGrossEnvelopeRequired reservePoolPos)
      assertEqual
        "reserve pool available required receives travel envelope headroom"
        (one jpy 150)
        (backingPoolAvailableEnvelopeRequired reservePoolPos)
      assertEqual
        "reserve pool gross surplus reflects local surplus"
        (one jpy 100)
        (backingPoolGrossSurplus reservePoolPos)
      assertEqual
        "reserve pool available surplus reflects local surplus"
        (one jpy 100)
        (backingPoolAvailableSurplus reservePoolPos)

    _ -> failTest "derived pools layout" "expected exactly two pool positions [cashPoolPos, reservePoolPos]"

characterizeHouseholdBackingNativeConsumptionRouting :: IO ()
characterizeHouseholdBackingNativeConsumptionRouting = do
  let jpy = mustRight (mkCommodity "JPY")
      period = mustRight
        (mkPeriod (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      obsDay = fromGregorian 2026 8 15
      foodId = mustRight (mkEnvelopeId "food")
      travelId = mustRight (mkEnvelopeId "travel")
      cashPoolId = mustRight (mkBackingPoolId "cash")
      reservePoolId = mustRight (mkBackingPoolId "reserve")
      cash = mustRight (mkAccount "assets:cash")
      bank = mustRight (mkAccount "assets:bank")
      income = mustRight (mkAccount "income:salary")
      unassigned = mustRight (mkAccount "budget:unassigned")
      foodAlloc = mustRight (mkAccount "budget:food")
      travelAlloc = mustRight (mkAccount "budget:travel")
      foodExpense = mustRight (mkAccount "expenses:food")
      travelExpense = mustRight (mkAccount "expenses:travel")
      taxExpense = mustRight (mkAccount "expenses:tax")
      unroutedExpense = mustRight (mkAccount "expenses:unrouted")
      foodLabel = mustRight (Budget.mkEnvelopeLabel "Food")
      travelLabel = mustRight (Budget.mkEnvelopeLabel "Travel")

      budgetPools =
        [ Budget.defineBackingPool cashPoolId [cash]
        , Budget.defineBackingPool reservePoolId [bank]
        ]
      budgetEnvelopes =
        [ Budget.defineEnvelope foodId foodLabel Daily cashPoolId [foodExpense]
        , Budget.defineEnvelope travelId travelLabel Flex reservePoolId [travelExpense]
        ]
      budgetPolicy = mustRight (Budget.mkBudgetPolicy budgetEnvelopes budgetPools)

      coords =
        [ defineHouseholdEnvelopeCoordinates foodId foodAlloc []
        , defineHouseholdEnvelopeCoordinates travelId travelAlloc []
        ]
      householdPolicy = mustRight
        (mkHouseholdPolicy
          (incomeAnchorCyclePolicy income)
          budgetPolicy
          coords
          [unassigned])

      journalSource = T.unlines
        [ "account assets:cash"
        , "  type: Asset"
        , "account assets:bank"
        , "  type: Asset"
        , "account income:salary"
        , "  type: Income"
        , "account expenses:food"
        , "  type: Expense"
        , "account expenses:travel"
        , "  type: Expense"
        , "account expenses:tax"
        , "  type: Expense"
        , "account expenses:unrouted"
        , "  type: Expense"
        , "account budget:unassigned"
        , "  type: Budget"
        , "account budget:food"
        , "  type: Budget"
        , "account budget:travel"
        , "  type: Budget"
        , ""
        , "2026-08-01 salary"
        , "  assets:cash  500 JPY"
        , "  income:salary  -500 JPY"
        , ""
        , "2026-08-02 food charge"
        , "  expenses:food  50 JPY"
        , "  assets:cash  -50 JPY"
        , ""
        , "2026-08-03 food refund"
        , "  expenses:food  -10 JPY"
        , "  assets:cash  10 JPY"
        , ""
        , "2026-08-04 tax expense (unmanaged)"
        , "  expenses:tax  100 JPY"
        , "  assets:cash  -100 JPY"
        , ""
        , "2026-08-05 unrouted expense charge"
        , "  expenses:unrouted  20 JPY"
        , "  assets:cash  -20 JPY"
        , ""
        , "2026-08-06 unrouted expense refund"
        , "  expenses:unrouted  -5 JPY"
        , "  assets:cash  5 JPY"
        ]
      actualJournal = mustRight (parseActualJournal journalSource)
      journal = actualJournalValue actualJournal

      cycleVal = mustRight
        (mkBudgetCycle (fromGregorian 2026 8 1) (fromGregorian 2026 9 1))
      obs = mustRight (mkBudgetObservation cycleVal obsDay)
      history = mustRight (mkBudgetHistory
        [ mustRight (mkBudgetChange (fromGregorian 2026 8 1) cycleVal foodId (mkAmount jpy (quantityFromInteger 150)) "food entitlement")
        , mustRight (mkBudgetChange (fromGregorian 2026 8 1) cycleVal travelId (mkAmount jpy (quantityFromInteger 200)) "travel entitlement")
        ])
      validatedBudget = mustRight
        (Budget.validateBudgetPolicyAccounts
          (HKernel.Journal.journalAccountRegistry journal)
          budgetPolicy)
      legacyBudgetConsumption = mustRight
        (calculateBudgetConsumption obs validatedBudget journal)
      entitlement = mustRight
        (calculateBudgetEntitlement obs budgetPolicy history)
      remaining = mustRight
        (calculateBudgetRemaining entitlement legacyBudgetConsumption)

      customResolver = ExpenseRouteResolver (\_day acc ->
        if acc == foodExpense then Just (ManagedByEnvelope foodId)
        else if acc == travelExpense then Just (ManagedByEnvelope travelId)
        else if acc == taxExpense then Just NotEnvelopeManaged
        else Nothing)

      envelopeConsumption = mustRight
        (observeEnvelopeConsumption period obsDay actualJournal customResolver)

      backingResult = mustRight
        (deriveHouseholdBacking
          obsDay
          period
          journal
          householdPolicy
          []
          entitlement
          envelopeConsumption
          remaining
          [])

  case envelopeBackingLines backingResult of
    [foodLine, travelLine] -> do
      assertEqual
        "native managed charges reach Backing line"
        (one jpy 50)
        (envelopeActualConsumption foodLine)
      assertEqual
        "native managed refunds reach Backing line"
        (one jpy 10)
        (envelopeActualRefunds foodLine)
      assertEqual
        "travel line without activity has empty charges"
        mempty
        (envelopeActualConsumption travelLine)
      assertEqual
        "travel line without activity has empty refunds"
        mempty
        (envelopeActualRefunds travelLine)
    _ -> failTest "routing test lines layout" "expected exactly two envelope backing lines"

  assertEqual
    "native unrouted expense reaches existing unassigned attention"
    [(unroutedExpense, one jpy 15)]
    (envelopeUnassignedExpenses backingResult)

  assertEqual
    "native unmanaged expense does not mix into unassigned attention"
    Nothing
    (lookup taxExpense (envelopeUnassignedExpenses backingResult))

  assertEqual
    "native unmanaged expense remains preserved in EnvelopeConsumption"
    (Just (ConsumptionAmounts (one jpy 100) mempty))
    (Map.lookup taxExpense (envelopeConsumptionUnmanaged envelopeConsumption))

one :: Commodity -> Integer -> Balance
one commodity value =
  singletonBalance (mkAmount commodity (quantityFromInteger value))

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = failTest label
      ("expected: " ++ show expected ++ "\n    actual:   " ++ show actual)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
