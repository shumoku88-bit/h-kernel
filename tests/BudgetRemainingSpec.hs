{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List (find)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Budget
import HKernel.Budget.Config (parseBudgetPolicy)
import HKernel.Budget.Consumption
import HKernel.Budget.Entitlement
import HKernel.Budget.History
import HKernel.Budget.Policy
import HKernel.Budget.Remaining
import HKernel.Journal
import HKernel.Money
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeExactRemaining
  characterizeAlignmentErrors

characterizeExactRemaining :: IO ()
characterizeExactRemaining = do
  let journal = testJournal
      policy = testPolicy
      observation = testObservation
      validatedPolicy = mustRight
        (validateBudgetPolicyAccounts (journalAccountRegistry journal) policy)
      history = testHistory
      entitlement = mustRight
        (calculateBudgetEntitlement observation policy history)
      consumption = mustRight
        (calculateBudgetConsumption observation validatedPolicy journal)
      remaining = mustRight
        (calculateBudgetRemaining entitlement consumption)
      everyday = mustRight (mkEnvelopeId "everyday")
      overspent = mustRight (mkEnvelopeId "overspent")
      unused = mustRight (mkEnvelopeId "unused")
      jpy = mustRight (mkCommodity "JPY")
      usd = mustRight (mkCommodity "USD")
      expectedEveryday = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 750)
        , mkAmount usd (quantityFromInteger 3)
        ]
      expectedOverspent = balanceFromAmounts
        [mkAmount jpy (quantityFromInteger (-20))]

  assertEqual
    "remaining retains the aligned budget cycle"
    testCycle
    (budgetRemainingCycle remaining)
  assertEqual
    "remaining retains the aligned observation horizon"
    (fromGregorian 2026 7 24)
    (budgetRemainingObservedThrough remaining)
  assertEqual
    "remaining subtracts exact multi-commodity consumption by envelope"
    expectedEveryday
    ( envelopeRemainingBalance
        (mustJust (findEnvelope everyday remaining))
    )
  assertEqual
    "overspending remains visible as an exact negative balance"
    expectedOverspent
    ( envelopeRemainingBalance
        (mustJust (findEnvelope overspent remaining))
    )
  assertEqual
    "aligned zero coordinates retain canonical zero remaining"
    emptyBalance
    ( envelopeRemainingBalance
        (mustJust (findEnvelope unused remaining))
    )

characterizeAlignmentErrors :: IO ()
characterizeAlignmentErrors = do
  let journal = testJournal
      entitlement = mustRight
        (calculateBudgetEntitlement testObservation testPolicy testHistory)
      validatedPolicy = mustRight
        (validateBudgetPolicyAccounts
          (journalAccountRegistry journal)
          testPolicy)
      nextCycle = mustRight
        (mkBudgetCycle
          (fromGregorian 2026 7 15)
          (fromGregorian 2026 8 15))
      nextObservation = mustRight
        (mkBudgetObservation nextCycle (fromGregorian 2026 7 24))
      nextConsumption = mustRight
        (calculateBudgetConsumption nextObservation validatedPolicy journal)
      earlierObservation = mustRight
        (mkBudgetObservation testCycle (fromGregorian 2026 7 23))
      earlierConsumption = mustRight
        (calculateBudgetConsumption earlierObservation validatedPolicy journal)
      differentPolicy = mustRight (parseBudgetPolicy differentPolicyInput)
      validatedDifferentPolicy = mustRight
        (validateBudgetPolicyAccounts
          (journalAccountRegistry journal)
          differentPolicy)
      differentConsumption = mustRight
        (calculateBudgetConsumption testObservation validatedDifferentPolicy journal)
      extra = mustRight (mkEnvelopeId "extra")
      unused = mustRight (mkEnvelopeId "unused")

  assertErrors
    "different cycles are rejected before subtraction"
    [RemainingCycleMismatch testCycle nextCycle]
    (calculateBudgetRemaining entitlement nextConsumption)
  assertErrors
    "different observation horizons are rejected before subtraction"
    [ RemainingObservedThroughMismatch
        (fromGregorian 2026 7 24)
        (fromGregorian 2026 7 23)
    ]
    (calculateBudgetRemaining entitlement earlierConsumption)
  assertErrors
    "different envelope coordinate sets are reported in canonical order"
    [ RemainingEnvelopeMissingFromEntitlement extra
    , RemainingEnvelopeMissingFromConsumption unused
    ]
    (calculateBudgetRemaining entitlement differentConsumption)

findEnvelope :: EnvelopeId -> BudgetRemaining -> Maybe EnvelopeRemaining
findEnvelope envelope =
  find ((== envelope) . envelopeRemainingEnvelope)
    . budgetRemainingEnvelopes

testCycle :: BudgetCycle
testCycle = mustRight
  (mkBudgetCycle
    (fromGregorian 2026 7 1)
    (fromGregorian 2026 8 1))

testObservation :: BudgetObservation
testObservation = mustRight
  (mkBudgetObservation testCycle (fromGregorian 2026 7 24))

testJournal :: Journal
testJournal = mustRight (parseJournal journalInput)

testPolicy :: BudgetPolicy
testPolicy = mustRight (parseBudgetPolicy policyInput)

testHistory :: BudgetHistory
testHistory = mustRight (mkBudgetHistory
  [ change testCycle "everyday" (fromGregorian 2026 7 1)
      "JPY" 1000 "monthly entitlement"
  , change testCycle "everyday" (fromGregorian 2026 7 1)
      "USD" 5 "travel cash entitlement"
  , change testCycle "overspent" (fromGregorian 2026 7 1)
      "JPY" 10 "small medical entitlement"
  ])

change
  :: BudgetCycle
  -> Text
  -> Day
  -> Text
  -> Integer
  -> Text
  -> BudgetChange
change cycle envelopeText effectiveDay commodityText quantity note = mustRight
  (mkBudgetChange
    effectiveDay
    cycle
    (mustRight (mkEnvelopeId envelopeText))
    (mkAmount
      (mustRight (mkCommodity commodityText))
      (quantityFromInteger quantity))
    note)

policyInput :: T.Text
policyInput = T.unlines
  [ "[[backing-pools]]"
  , "id = \"operating\""
  , "asset-accounts = [\"wallet:cash\", \"wallet:dollars\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"everyday\""
  , "label = \"Everyday\""
  , "pacing = \"daily\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"living:food\", \"living:coffee\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"overspent\""
  , "label = \"Overspent\""
  , "pacing = \"flex\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"living:medical\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"unused\""
  , "label = \"Unused\""
  , "pacing = \"flex\""
  , "backing-pool = \"operating\""
  , "expense-accounts = []"
  ]

differentPolicyInput :: T.Text
differentPolicyInput = T.unlines
  [ "[[backing-pools]]"
  , "id = \"operating\""
  , "asset-accounts = [\"wallet:cash\", \"wallet:dollars\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"everyday\""
  , "label = \"Everyday\""
  , "pacing = \"daily\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"living:food\", \"living:coffee\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"extra\""
  , "label = \"Extra\""
  , "pacing = \"flex\""
  , "backing-pool = \"operating\""
  , "expense-accounts = []"
  , ""
  , "[[envelopes]]"
  , "id = \"overspent\""
  , "label = \"Overspent\""
  , "pacing = \"flex\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"living:medical\"]"
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
  ]

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

mustJust :: Maybe value -> value
mustJust (Just value) = value
mustJust Nothing = error "invalid test fixture: expected a value"

assertErrors
  :: String
  -> [RemainingError]
  -> Either (NonEmpty.NonEmpty RemainingError) value
  -> IO ()
assertErrors label expected result = case result of
  Left errors -> assertEqual label expected (NonEmpty.toList errors)
  Right _ -> failTest label "unexpectedly accepted misaligned coordinates"

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = failTest label
      ("expected " ++ show expected ++ ", but got " ++ show actual)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
