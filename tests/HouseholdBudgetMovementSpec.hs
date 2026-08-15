{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (assertEqual, mustRight)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account (mkAccount)
import HKernel.Household.BudgetMovement
import HKernel.Journal (parseJournal)
import HKernel.Money

main :: IO ()
main = do
  characterizeNativeJournalRoundTrip
  characterizeNativeResolvedSourceAdmission
  characterizeNativeJournalFailures

characterizeNativeJournalRoundTrip :: IO ()
characterizeNativeJournalRoundTrip = do
  let jpy = mustRight (mkCommodity "JPY")
      opening = mustRight (mkAccount "budget:opening")
      food = mustRight (mkAccount "budget:food")
      unassigned = mustRight (mkAccount "budget:unassigned")
      movements =
        [ householdBudgetMovement
            (fromGregorian 2026 6 15)
            "allocate"
            opening
            food
            (mkAmount jpy (quantityFromInteger 1000))
        , householdBudgetMovement
            (fromGregorian 2026 6 16)
            "signed-adjustment"
            food
            unassigned
            (mkAmount jpy (quantityFromInteger (-25)))
        , householdBudgetMovement
            (fromGregorian 2026 6 17)
            "zero-evidence"
            unassigned
            food
            (mkAmount jpy (quantityFromInteger 0))
        ]
      rendered = mustRight (renderHouseholdBudgetMovementTransactions movements)
      journal = mustRight (parseJournal (budgetDeclarations <> "\n" <> rendered))

  assertEqual
    "native Journal round-trip preserves ordered signed movement values"
    movements
    (mustRight (admitHouseholdBudgetMovementJournal journal))

characterizeNativeResolvedSourceAdmission :: IO ()
characterizeNativeResolvedSourceAdmission = do
  let resolvedJournal = mustRight (parseJournal nativeResolvedBudgetJournal)
      admitted = mustRight
        (admitHouseholdBudgetMovementJournalFromResolvedJournal
          resolvedJournal
          nativeResolvedBudgetJournal)

  assertEqual
    "resolved native Budget admission accepts matching root transaction evidence"
    1
    (length (householdBudgetMovementJournalMovements admitted))

  assertEqual
    "resolved native Budget admission rejects equal-count evidence for another transaction"
    (Left
      (BudgetMovementJournalTransactionSourceAlignmentMismatch 1
        NonEmpty.:| []))
    (admitHouseholdBudgetMovementJournalFromResolvedJournal
      resolvedJournal
      equalCountDifferentBudgetSource)

characterizeNativeJournalFailures :: IO ()
characterizeNativeJournalFailures = do
  assertEqual
    "native Journal rejects a non-Budget posting without retaining Account text"
    (Left (BudgetMovementJournalPostingNotBudget 1 1 NonEmpty.:| []))
    (admitHouseholdBudgetMovementJournal
      (mustRight (parseJournal nonBudgetJournal)))

  assertEqual
    "native Journal rejects a movement with more than two postings"
    (Left (BudgetMovementJournalRequiresBinaryTransaction 1 3 NonEmpty.:| []))
    (admitHouseholdBudgetMovementJournal
      (mustRight (parseJournal threePostingJournal)))

  assertEqual
    "native Journal requires exact opposite Amounts including Commodity"
    (Left
      (BudgetMovementJournalPostingsNotExactOpposites 1 NonEmpty.:| []))
    (admitHouseholdBudgetMovementJournal
      (mustRight (parseJournal crossCommodityZeroJournal)))

  let jpy = mustRight (mkCommodity "JPY")
      opening = mustRight (mkAccount "budget:opening")
      food = mustRight (mkAccount "budget:food")
      unrepresentable = householdBudgetMovement
        (fromGregorian 2026 6 15)
        "line one\nline two"
        opening
        food
        (mkAmount jpy (quantityFromInteger 1))
  assertEqual
    "renderer rejects text that cannot round-trip as one transaction"
    (Left (BudgetMovementJournalUnrepresentableTransaction 1 NonEmpty.:| []))
    (renderHouseholdBudgetMovementTransactions [unrepresentable])

budgetDeclarations :: T.Text
budgetDeclarations = T.unlines
  [ "account budget:opening"
  , "  type: budget"
  , "account budget:food"
  , "  type: budget"
  , "account budget:unassigned"
  , "  type: budget"
  , "account budget:reserve"
  , "  type: budget"
  , "account assets:cash"
  , "  type: asset"
  ]

nativeResolvedBudgetJournal :: T.Text
nativeResolvedBudgetJournal = budgetDeclarations <> T.unlines
  [ "2026-06-15 move-to-reserve"
  , "    budget:opening    -100 JPY"
  , "    budget:reserve     100 JPY"
  ]

equalCountDifferentBudgetSource :: T.Text
equalCountDifferentBudgetSource = budgetDeclarations <> T.unlines
  [ "2026-06-15 different-move"
  , "    budget:opening    -101 JPY"
  , "    budget:reserve     101 JPY"
  ]

nonBudgetJournal :: T.Text
nonBudgetJournal = budgetDeclarations <> T.unlines
  [ "2026-06-15 invalid-role"
  , "    assets:cash    -10 JPY"
  , "    budget:food     10 JPY"
  ]

threePostingJournal :: T.Text
threePostingJournal = budgetDeclarations <> T.unlines
  [ "2026-06-15 split"
  , "    budget:opening    -100 JPY"
  , "    budget:food         50 JPY"
  , "    budget:reserve      50 JPY"
  ]

crossCommodityZeroJournal :: T.Text
crossCommodityZeroJournal = budgetDeclarations <> T.unlines
  [ "2026-06-15 zero-cross-commodity"
  , "    budget:opening    0 JPY"
  , "    budget:food       0 USD"
  ]
