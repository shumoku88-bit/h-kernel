{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, mustJust, assertEqual)
import Data.List (find)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account (Account, accountName, mkAccount)
import HKernel.Budget
import HKernel.Budget.Config
import HKernel.Budget.Consumption
import HKernel.Budget.Policy
import HKernel.Journal
import HKernel.Money
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeExactConsumption
  characterizeUnassignedExpenseEvidence

characterizeExactConsumption :: IO ()
characterizeExactConsumption = do
  let journal = mustRight (parseJournal journalInput)
      policy = mustRight (parseBudgetPolicy policyInput)
      validated = mustRight
        (validateBudgetPolicyAccounts (journalAccountRegistry journal) policy)
      cycle = testCycle
      observedThrough = fromGregorian 2026 7 24
      observation = mustRight
        (mkBudgetObservation cycle observedThrough)
      consumption = mustRight
        (calculateBudgetConsumption observation validated journal)
      everyday = mustRight (mkEnvelopeId "everyday")
      unused = mustRight (mkEnvelopeId "unused")
      jpy = mustRight (mkCommodity "JPY")
      usd = mustRight (mkCommodity "USD")
      expectedCharges = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 300)
        , mkAmount usd (quantityFromInteger 2)
        ]
      expectedRefunds = balanceFromAmounts
        [mkAmount jpy (quantityFromInteger 50)]
      expectedNet = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 250)
        , mkAmount usd (quantityFromInteger 2)
        ]
      everydayConsumption = mustJust (findEnvelope everyday consumption)

  assertEqual
    "consumption retains the half-open budget cycle"
    cycle
    (budgetConsumptionCycle consumption)
  assertEqual
    "consumption retains the inclusive observation horizon"
    observedThrough
    (budgetConsumptionObservedThrough consumption)
  assertEqual
    "positive Expense postings aggregate as exact charge evidence"
    expectedCharges
    (envelopeConsumptionCharges everydayConsumption)
  assertEqual
    "negative Expense postings aggregate as positive refund evidence"
    expectedRefunds
    (envelopeConsumptionRefunds everydayConsumption)
  assertEqual
    "net consumption subtracts exact refunds from exact charges"
    expectedNet
    (envelopeConsumptionBalance everydayConsumption)
  assertEqual
    "later postings in the same cycle do not enter charge evidence"
    expectedCharges
    (envelopeConsumptionCharges everydayConsumption)
  assertEqual
    "policy envelopes with no activity retain canonical zero consumption"
    emptyBalance
    ( envelopeConsumptionBalance
        (mustJust (findEnvelope unused consumption))
    )

characterizeUnassignedExpenseEvidence :: IO ()
characterizeUnassignedExpenseEvidence = do
  let journal = mustRight (parseJournal journalInput)
      policy = mustRight (parseBudgetPolicy policyInput)
      validated = mustRight
        (validateBudgetPolicyAccounts (journalAccountRegistry journal) policy)
      observation = mustRight
        (mkBudgetObservation testCycle (fromGregorian 2026 7 24))
      consumption = mustRight
        (calculateBudgetConsumption observation validated journal)
      cancelled = mustRight (mkAccount "living:cancelled")
      medical = mustRight (mkAccount "living:medical")
      jpy = mustRight (mkCommodity "JPY")

  assertEqual
    "zero-net unassigned Expense activity remains visible"
    emptyBalance
    ( unassignedExpenseBalance
        (mustJust (findUnassigned cancelled consumption))
    )
  assertEqual
    "unassigned Expense consumption remains exact evidence"
    (balanceFromAmounts [mkAmount jpy (quantityFromInteger 30)])
    ( unassignedExpenseBalance
        (mustJust (findUnassigned medical consumption))
    )
  assertEqual
    "non-Expense transfer postings are not invented as consumption"
    ["living:cancelled", "living:medical"]
    ( map
        (accountName . unassignedExpenseAccount)
        (budgetConsumptionUnassignedExpenses consumption)
    )

findEnvelope :: EnvelopeId -> BudgetConsumption -> Maybe EnvelopeConsumption
findEnvelope envelope =
  find ((== envelope) . envelopeConsumptionEnvelope)
    . budgetConsumptionEnvelopes

findUnassigned
  :: Account
  -> BudgetConsumption
  -> Maybe UnassignedExpenseConsumption
findUnassigned account =
  find ((== account) . unassignedExpenseAccount)
    . budgetConsumptionUnassignedExpenses

testCycle :: BudgetCycle
testCycle = mustRight
  (mkBudgetCycle
    (fromGregorian 2026 7 1)
    (fromGregorian 2026 8 1))

policyInput :: T.Text
policyInput = T.unlines
  [ "[[backing-pools]]"
  , "id = \"operating\""
  , "asset-accounts = [\"wallet:cash\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"everyday\""
  , "label = \"Everyday\""
  , "pacing = \"daily\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"living:food\", \"living:coffee\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"unused\""
  , "label = \"Unused\""
  , "pacing = \"flex\""
  , "backing-pool = \"operating\""
  , "expense-accounts = []"
  ]

journalInput :: T.Text
journalInput = T.unlines
  [ "account wallet:cash"
  , "    type: asset"
  , "    commodity: JPY"
  , ""
  , "account wallet:dollars"
  , "    type: asset"
  , "    commodity: USD"
  , ""
  , "account wallet:savings"
  , "    type: asset"
  , "    commodity: JPY"
  , ""
  , "account living:food"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account living:coffee"
  , "    type: expense"
  , "    commodity: USD"
  , ""
  , "account living:medical"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account living:cancelled"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "2026-07-01 Food"
  , "    living:food       300 JPY"
  , "    wallet:cash      -300 JPY"
  , ""
  , "2026-07-12 Coffee"
  , "    living:coffee       2 USD"
  , "    wallet:dollars     -2 USD"
  , ""
  , "2026-07-15 Food refund"
  , "    living:food       -50 JPY"
  , "    wallet:cash        50 JPY"
  , ""
  , "2026-07-22 Medical"
  , "    living:medical     30 JPY"
  , "    wallet:cash       -30 JPY"
  , ""
  , "2026-07-23 Cancelled expense"
  , "    living:cancelled   10 JPY"
  , "    wallet:cash       -10 JPY"
  , ""
  , "2026-07-24 Cancel expense"
  , "    living:cancelled  -10 JPY"
  , "    wallet:cash        10 JPY"
  , ""
  , "2026-07-25 Transfer after observation"
  , "    wallet:savings    100 JPY"
  , "    wallet:cash      -100 JPY"
  , ""
  , "2026-07-26 Food after observation"
  , "    living:food       500 JPY"
  , "    wallet:cash      -500 JPY"
  , ""
  , "2026-08-01 Food at exclusive end"
  , "    living:food       700 JPY"
  , "    wallet:cash      -700 JPY"
  ]






