{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (IOException, catch)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (mkAccount)
import HKernel.Account.Journal (parseAccountJournal)
import HKernel.Editor.BudgetMovementAppend
  ( BudgetJournalMovementAppendError(..)
  , BudgetJournalMovementAppendPreview(..)
  , prepareBudgetJournalMovementAppend
  )
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteError(..)
  , WriteIntent(..)
  , WriterFileSystem(..)
  , defaultWriterFileSystem
  , publishWithPathAdmission
  )
import HKernel.Household.BudgetMovement
import HKernel.Journal (parseJournal)
import HKernel.Loader (loadJournal)
import HKernel.Money (mkAmount, mkCommodity, quantityFromInteger)

main :: IO ()
main = do
  let tests =
        [ ("testNativeBudgetMovement", pure testNativeBudgetMovement)
        , ("testNativeBudgetMovementRejectsNonBudget", pure testNativeBudgetMovementRejectsNonBudget)
        , ("testNativeJournalRoundTrip", pure testNativeJournalRoundTrip)
        , ("testResolvedSourceAdmission", pure testResolvedSourceAdmission)
        , ("testNativeAdmissionFailures", pure testNativeAdmissionFailures)
        , ("testRendererRejectsUnrepresentable", pure testRendererRejectsUnrepresentable)
        , ("testPathAwareJournalCommit", testPathAwareJournalCommit)
        , ("testPathAwareJournalFailureRestores", testPathAwareJournalFailureRestores)
        ]
  results <- sequence [action | (_, action) <- tests]
  let namedResults = zip (map fst tests) results
  mapM_ print namedResults
  if all snd namedResults
    then exitSuccess
    else exitFailure

testMovement :: HouseholdBudgetMovement
testMovement = HouseholdBudgetMovement
  { householdBudgetMovementDate = fromGregorian 2026 8 4
  , householdBudgetMovementMemo = "transfer"
  , householdBudgetMovementFrom = account "budget:from"
  , householdBudgetMovementTo = account "budget:to"
  , householdBudgetMovementAmount =
      mkAmount
        (mustRight (mkCommodity "JPY"))
        (quantityFromInteger 500)
  }

testNativeBudgetMovement :: Bool
testNativeBudgetMovement =
  case prepareBudgetJournalMovementAppend registry pathAwareRoot testMovement of
    Right preview ->
      budgetJournalCandidateBlock preview == expectedBlock
        && budgetJournalCandidateCompleteSource preview == pathAwareCandidate
    Left err -> error (show err)
  where
    registry = mustRight (parseAccountJournal pathAwareAccounts)
    expectedBlock = T.unlines
      [ "2026-08-04 transfer"
      , "    budget:from    -500 JPY"
      , "    budget:to    500 JPY"
      ]

testNativeBudgetMovementRejectsNonBudget :: Bool
testNativeBudgetMovementRejectsNonBudget =
  case prepareBudgetJournalMovementAppend mixedRegistry pathAwareRoot invalidMovement of
    Left (BudgetJournalMovementNotBudgetAccount found :| _) ->
      found == account "assets:cash"
    _ -> False
  where
    mixedRegistry = mustRight (parseAccountJournal (pathAwareAccounts <> T.unlines
      [ "account assets:cash"
      , "    type: asset"
      , "    commodity: JPY"
      ]))
    invalidMovement = testMovement
      { householdBudgetMovementFrom = account "assets:cash" }

testNativeJournalRoundTrip :: Bool
testNativeJournalRoundTrip =
  admitHouseholdBudgetMovementJournal journal == Right movements
  where
    jpy = mustRight (mkCommodity "JPY")
    movements =
      [ householdBudgetMovement
          (fromGregorian 2026 6 15)
          "allocate"
          (account "budget:opening")
          (account "budget:food")
          (mkAmount jpy (quantityFromInteger 1000))
      , householdBudgetMovement
          (fromGregorian 2026 6 16)
          "signed-adjustment"
          (account "budget:food")
          (account "budget:unassigned")
          (mkAmount jpy (quantityFromInteger (-25)))
      , householdBudgetMovement
          (fromGregorian 2026 6 17)
          "zero-evidence"
          (account "budget:unassigned")
          (account "budget:food")
          (mkAmount jpy (quantityFromInteger 0))
      ]
    rendered = mustRight (renderHouseholdBudgetMovementTransactions movements)
    journal = mustRight (parseJournal (budgetDeclarations <> "\n" <> rendered))

testResolvedSourceAdmission :: Bool
testResolvedSourceAdmission =
  length (householdBudgetMovementJournalMovements admitted) == 1
    && mismatched == Left
      (BudgetMovementJournalTransactionSourceAlignmentMismatch 1 :| [])
  where
    resolvedJournal = mustRight (parseJournal nativeResolvedBudgetJournal)
    admitted = mustRight
      (admitHouseholdBudgetMovementJournalFromResolvedJournal
        resolvedJournal
        nativeResolvedBudgetJournal)
    mismatched = admitHouseholdBudgetMovementJournalFromResolvedJournal
      resolvedJournal
      equalCountDifferentBudgetSource

testNativeAdmissionFailures :: Bool
testNativeAdmissionFailures =
  nonBudget == Left (BudgetMovementJournalPostingNotBudget 1 1 :| [])
    && threePosting == Left (BudgetMovementJournalRequiresBinaryTransaction 1 3 :| [])
    && crossCommodity == Left
      (BudgetMovementJournalPostingsNotExactOpposites 1 :| [])
  where
    nonBudget = admitHouseholdBudgetMovementJournal
      (mustRight (parseJournal nonBudgetJournal))
    threePosting = admitHouseholdBudgetMovementJournal
      (mustRight (parseJournal threePostingJournal))
    crossCommodity = admitHouseholdBudgetMovementJournal
      (mustRight (parseJournal crossCommodityZeroJournal))

testRendererRejectsUnrepresentable :: Bool
testRendererRejectsUnrepresentable =
  renderHouseholdBudgetMovementTransactions [unrepresentable]
    == Left (BudgetMovementJournalUnrepresentableTransaction 1 :| [])
  where
    unrepresentable = householdBudgetMovement
      (fromGregorian 2026 6 15)
      "line one\nline two"
      (account "budget:opening")
      (account "budget:food")
      (mkAmount (mustRight (mkCommodity "JPY")) (quantityFromInteger 1))

-- The root source is intentionally just an include before the candidate is
-- appended. Pure Text admission cannot prove this graph; the path-aware writer
-- can load the sibling Account declarations after publication.
testPathAwareJournalCommit :: IO Bool
testPathAwareJournalCommit = do
  let rootPath = "tests/fixtures/test_editor_path_budget.journal"
      accountsPath = "tests/fixtures/accounts.journal"
  cleanup rootPath
  cleanup accountsPath
  TIO.writeFile accountsPath pathAwareAccounts
  TIO.writeFile rootPath pathAwareRoot
  result <- publishWithPathAdmission admitJournalPath
    WriteIntent
      { targetFilePath = rootPath
      , expectedOldBytes = ExpectedSource pathAwareRoot
      , candidateNewBytes = CandidateSource pathAwareCandidate
      }
  current <- TIO.readFile rootPath
  cleanup rootPath
  cleanup accountsPath
  pure (result == Right () && current == pathAwareCandidate)

testPathAwareJournalFailureRestores :: IO Bool
testPathAwareJournalFailureRestores = do
  let rootPath = "tests/fixtures/test_editor_path_reject.journal"
      accountsPath = "tests/fixtures/accounts.journal"
  cleanup rootPath
  cleanup accountsPath
  TIO.writeFile accountsPath pathAwareAccounts
  TIO.writeFile rootPath pathAwareRoot
  result <- publishWithPathAdmission admitJournalPath
    WriteIntent
      { targetFilePath = rootPath
      , expectedOldBytes = ExpectedSource pathAwareRoot
      , candidateNewBytes = CandidateSource pathAwareInvalidCandidate
      }
  current <- TIO.readFile rootPath
  cleanup rootPath
  cleanup accountsPath
  pure $ case result of
    Left (PostAdmissionFailed _ True) -> current == pathAwareRoot
    _ -> False

data PathAdmissionError = PathAdmissionError
  deriving (Eq, Show)

admitJournalPath path = do
  result <- loadJournal path
  pure $ case result of
    Left _ -> Left (PathAdmissionError :| [])
    Right journal -> Right journal

pathAwareAccounts :: Text
pathAwareAccounts = T.unlines
  [ "account budget:from"
  , "    type: budget"
  , "    commodity: JPY"
  , "account budget:to"
  , "    type: budget"
  , "    commodity: JPY"
  ]

pathAwareRoot :: Text
pathAwareRoot = "include accounts.journal\n"

pathAwareCandidate :: Text
pathAwareCandidate = pathAwareRoot <> T.unlines
  [ ""
  , "2026-08-04 transfer"
  , "    budget:from    -500 JPY"
  , "    budget:to    500 JPY"
  ]

pathAwareInvalidCandidate :: Text
pathAwareInvalidCandidate = pathAwareRoot <> T.unlines
  [ ""
  , "2026-08-04 invalid transfer"
  , "    budget:from    -500 JPY"
  , "    budget:unknown    500 JPY"
  ]

budgetDeclarations :: Text
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

nativeResolvedBudgetJournal :: Text
nativeResolvedBudgetJournal = budgetDeclarations <> T.unlines
  [ "2026-06-15 move-to-reserve"
  , "    budget:opening    -100 JPY"
  , "    budget:reserve     100 JPY"
  ]

equalCountDifferentBudgetSource :: Text
equalCountDifferentBudgetSource = budgetDeclarations <> T.unlines
  [ "2026-06-15 different-move"
  , "    budget:opening    -101 JPY"
  , "    budget:reserve     101 JPY"
  ]

nonBudgetJournal :: Text
nonBudgetJournal = budgetDeclarations <> T.unlines
  [ "2026-06-15 invalid-role"
  , "    assets:cash    -10 JPY"
  , "    budget:food     10 JPY"
  ]

threePostingJournal :: Text
threePostingJournal = budgetDeclarations <> T.unlines
  [ "2026-06-15 split"
  , "    budget:opening    -100 JPY"
  , "    budget:food         50 JPY"
  , "    budget:reserve      50 JPY"
  ]

crossCommodityZeroJournal :: Text
crossCommodityZeroJournal = budgetDeclarations <> T.unlines
  [ "2026-06-15 zero-cross-commodity"
  , "    budget:opening    0 JPY"
  , "    budget:food       0 USD"
  ]

account value = mustRight (mkAccount value)

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

cleanup :: FilePath -> IO ()
cleanup path = do
  removeIfPresent path
  removeIfPresent (path <> ".backup.tmp")
  removeIfPresent (path <> ".new.tmp")

removeIfPresent :: FilePath -> IO ()
removeIfPresent path =
  catch
    (removeTextFile defaultWriterFileSystem path)
    (\(_ :: IOException) -> pure ())
