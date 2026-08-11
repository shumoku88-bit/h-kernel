{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, mustJust)
import Data.List (find)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Budget
import HKernel.Budget.Config (parseBudgetPolicy)
import HKernel.Budget.Entitlement
import HKernel.Budget.History
import HKernel.Budget.Policy (BudgetPolicy)
import HKernel.Money
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeExactEntitlement
  characterizeUnknownEnvelopeAdmission

characterizeExactEntitlement :: IO ()
characterizeExactEntitlement = do
  let policy = testPolicy
      cycle = testCycle
      observedThrough = fromGregorian 2026 9 1
      observation = mustRight
        (mkBudgetObservation cycle observedThrough)
      futureCycle = mustRight
        (mkBudgetCycle
          (fromGregorian 2026 10 15)
          (fromGregorian 2026 12 15))
      everyday = mustRight (mkEnvelopeId "everyday")
      unused = mustRight (mkEnvelopeId "unused")
      futureOnly = mustRight (mkEnvelopeId "future-only")
      jpy = mustRight (mkCommodity "JPY")
      usd = mustRight (mkCommodity "USD")
      history = mustRight (mkBudgetHistory
        [ change futureCycle futureOnly (fromGregorian 2026 10 15)
            jpy 999 "future cycle"
        , change cycle everyday (fromGregorian 2026 8 15)
            jpy 10000 "initial"
        , change cycle everyday (fromGregorian 2026 9 1)
            jpy (-1500) "adjustment"
        , change cycle everyday (fromGregorian 2026 9 2)
            usd 2 "later dollar allowance"
        ])
      entitlement = mustRight
        (calculateBudgetEntitlement observation policy history)
      expectedEveryday = balanceFromAmounts
        [mkAmount jpy (quantityFromInteger 8500)]

  assertEqual
    "entitlement retains the selected half-open budget cycle"
    cycle
    (budgetEntitlementCycle entitlement)
  assertEqual
    "entitlement retains the inclusive observation horizon"
    observedThrough
    (budgetEntitlementObservedThrough entitlement)
  assertEqual
    "changes through the observation day aggregate exactly"
    expectedEveryday
    ( envelopeEntitlementBalance
        (mustJust (findEnvelope everyday entitlement))
    )
  assertEqual
    "later changes in the same cycle do not enter the observation"
    expectedEveryday
    ( envelopeEntitlementBalance
        (mustJust (findEnvelope everyday entitlement))
    )
  assertEqual
    "policy envelopes with no changes retain canonical zero entitlement"
    emptyBalance
    ( envelopeEntitlementBalance
        (mustJust (findEnvelope unused entitlement))
    )
  assertEqual
    "changes from another cycle do not enter the selected entitlement"
    [everyday, unused]
    (map envelopeEntitlementEnvelope (budgetEntitlementEnvelopes entitlement))

characterizeUnknownEnvelopeAdmission :: IO ()
characterizeUnknownEnvelopeAdmission = do
  let cycle = testCycle
      observation = mustRight
        (mkBudgetObservation cycle (fromGregorian 2026 8 16))
      policy = testPolicy
      ghost = mustRight (mkEnvelopeId "ghost")
      orphan = mustRight (mkEnvelopeId "orphan")
      jpy = mustRight (mkCommodity "JPY")
      history = mustRight (mkBudgetHistory
        [ change cycle orphan (fromGregorian 2026 8 15)
            jpy 5 "unknown orphan"
        , change cycle ghost (fromGregorian 2026 8 16)
            jpy 10 "unknown ghost"
        , change cycle ghost (fromGregorian 2026 8 17)
            jpy 20 "same unknown identity after observation"
        ])

  assertErrors
    "visible unknown envelope identities are reported once"
    [ EntitlementUnknownEnvelope ghost
    , EntitlementUnknownEnvelope orphan
    ]
    (calculateBudgetEntitlement observation policy history)

findEnvelope :: EnvelopeId -> BudgetEntitlement -> Maybe EnvelopeEntitlement
findEnvelope envelope =
  find ((== envelope) . envelopeEntitlementEnvelope)
    . budgetEntitlementEnvelopes

testCycle :: BudgetCycle
testCycle = mustRight
  (mkBudgetCycle
    (fromGregorian 2026 8 15)
    (fromGregorian 2026 10 15))

testPolicy :: BudgetPolicy
testPolicy = mustRight (parseBudgetPolicy policyInput)

change
  :: BudgetCycle
  -> EnvelopeId
  -> Day
  -> Commodity
  -> Integer
  -> Text
  -> BudgetChange
change cycle envelope effectiveDay commodity quantity note = mustRight
  (mkBudgetChange
    effectiveDay
    cycle
    envelope
    (mkAmount commodity (quantityFromInteger quantity))
    note)

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
  , "expense-accounts = []"
  , ""
  , "[[envelopes]]"
  , "id = \"unused\""
  , "label = \"Unused\""
  , "pacing = \"flex\""
  , "backing-pool = \"operating\""
  , "expense-accounts = []"
  ]





assertErrors
  :: String
  -> [EntitlementError]
  -> Either (NonEmpty.NonEmpty EntitlementError) value
  -> IO ()
assertErrors label expected result = case result of
  Left errors -> assertEqual label expected (NonEmpty.toList errors)
  Right _ -> failTest label "unexpectedly accepted unknown envelopes"

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
