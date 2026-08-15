{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight)
import Control.Exception (IOException, catch)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (Account, AccountRegistry, mkAccount)
import HKernel.Account.Journal (parseAccountJournal)
import HKernel.Actual.Journal (ActualJournal, parseActualJournal)
import HKernel.Backing.Identity (mkBackingPoolId)
import HKernel.Backing.Policy
  ( assignEnvelopeBackingPool
  , defineBackingPool
  , mkBackingPolicy
  )
import HKernel.Envelope.Identity (mkEnvelopeId)
import HKernel.Envelope.Policy
  ( Pacing(..)
  , defineEnvelope
  , mkCurrentEnvelopePolicy
  , mkEnvelopeLabel
  )
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteError(..)
  , WriteIntent(..)
  , WriterFileSystem(..)
  , defaultWriterFileSystem
  , publishWithAdmission
  , publishWithPathAdmission
  )
import HKernel.Editor.BudgetMovementAppend
  ( BudgetMovementAppendPreview(..)
  , prepareBudgetMovementAppend
  )
import HKernel.Editor.PlanBudgetSync
  ( PlanBudgetSyncError(..)
  , PlanBudgetSyncPreview(..)
  , PlanBudgetSyncResult(..)
  , preparePlanBudgetSync
  )
import HKernel.Household.AccountProfile
  ( RetainedBudgetAccountKind(..)
  , RetainedEnvelopeRole(..)
  , RetainedSpendClass(..)
  , HouseholdAccountPolicy
  , mkHouseholdAccountPolicy
  )
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement(..)
  , admitHouseholdBudgetMovementJournalFromResolvedJournal
  )
import HKernel.Household.BudgetMovement.TSV
  ( parseHouseholdBudgetMovements )
import HKernel.Household.Policy
  ( HouseholdPolicy
  , defineHouseholdEnvelopeCoordinates
  , incomeAnchorCyclePolicy
  , mkHouseholdPolicy
  )
import HKernel.Journal (parseJournal)
import HKernel.Loader (loadJournal)
import HKernel.Money (mkAmount, mkCommodity, quantityFromInteger)
import HKernel.Plan (PlanId, mkPlanId)
import HKernel.Plan.Journal (PlanJournal, parsePlanJournal)

main :: IO ()
main = do
  let tests =
        [ ("testValidBudgetMovement", pure testValidBudgetMovement)
        , ("testBudgetMovementCommit", testBudgetMovementCommit)
        , ("testPathAwareJournalCommit", testPathAwareJournalCommit)
        , ("testPathAwareJournalFailureRestores", testPathAwareJournalFailureRestores)
        , ("plan Budget sync uses completed Actual amount", pure testPlanBudgetSyncUsesActualAmount)
        , ("plan Budget sync is linkage-idempotent", pure testPlanBudgetSyncIdempotent)
        , ("plan Budget sync rejects account/order drift", pure testPlanBudgetSyncShapeMismatch)
        , ("plan Budget sync rejects direction drift", pure testPlanBudgetSyncDirectionMismatch)
        , ("plan Budget sync rejects commodity drift", pure testPlanBudgetSyncCommodityMismatch)
        , ("plan Budget sync rejects competing completions", pure testPlanBudgetSyncDuplicateCompletion)
        , ("plan Budget sync rejects mismatched existing linkage", pure testPlanBudgetSyncExistingLinkageMismatch)
        , ("plan Budget sync rejects duplicate existing linkage", pure testPlanBudgetSyncDuplicateLinkage)
        , ("plan Budget sync leaves unlinked Plan untouched", pure testPlanBudgetSyncNotLinked)
        ]
  results <- sequence [action | (_, action) <- tests]
  let namedResults = zip (map fst tests) results
  mapM_ print namedResults
  if all snd namedResults
    then exitSuccess
    else exitFailure

fixtureSource :: Text
fixtureSource = T.unlines
  [ "2026-08-01\topening\tbudget:living\tbudget:food\t1000\tcurrency=JPY"
  ]

testMovement :: HouseholdBudgetMovement
testMovement = HouseholdBudgetMovement
  { householdBudgetMovementDate = fromGregorian 2026 8 4
  , householdBudgetMovementMemo = "transfer"
  , householdBudgetMovementFrom =
      either (error "bad from") id (mkAccount "budget:food")
  , householdBudgetMovementTo =
      either (error "bad to") id (mkAccount "budget:living")
  , householdBudgetMovementAmount =
      mkAmount
        (either (error "bad comm") id (mkCommodity "JPY"))
        (quantityFromInteger 500)
  }

testValidBudgetMovement :: Bool
testValidBudgetMovement =
  case prepareBudgetMovementAppend fixtureSource testMovement of
    Right preview ->
      candidateBlock preview
        == "2026-08-04\ttransfer\tbudget:food\tbudget:living\t500\tcurrency=JPY"
    Left err -> error (show err)

testBudgetMovementCommit :: IO Bool
testBudgetMovementCommit = do
  let path = "tests/fixtures/test_editor_budget_commit.tsv"
  cleanup path
  TIO.writeFile path fixtureSource
  result <- case prepareBudgetMovementAppend fixtureSource testMovement of
    Left err -> print err >> pure False
    Right preview -> do
      writeResult <- publishWithAdmission
        parseHouseholdBudgetMovements
        WriteIntent
          { targetFilePath = path
          , expectedOldBytes = ExpectedSource fixtureSource
          , candidateNewBytes = CandidateSource (candidateCompleteSource preview)
          }
      case writeResult of
        Left err -> print err >> pure False
        Right () ->
          (== candidateCompleteSource preview) <$> TIO.readFile path
  cleanup path
  pure result

-- The root source is intentionally just an include before the candidate is
-- appended. Pure Text admission cannot prove this graph; the path-aware writer
-- can load the sibling Account declarations after publication.
testPathAwareJournalCommit :: IO Bool
testPathAwareJournalCommit = do
  let rootPath = "tests/fixtures/test_editor_path_budget.journal"
      accountsPath = "tests/fixtures/test_editor_path_accounts.journal"
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
      accountsPath = "tests/fixtures/test_editor_path_accounts.journal"
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
pathAwareRoot = "include test_editor_path_accounts.journal\n"

pathAwareCandidate :: Text
pathAwareCandidate = pathAwareRoot <> T.unlines
  [ ""
  , "2026-08-04 transfer"
  , "    budget:from    -500 JPY"
  , "    budget:to       500 JPY"
  ]

pathAwareInvalidCandidate :: Text
pathAwareInvalidCandidate = pathAwareRoot <> T.unlines
  [ ""
  , "2026-08-04 invalid transfer"
  , "    budget:from       -500 JPY"
  , "    budget:unknown     500 JPY"
  ]

-- Plan completion -> Budget movement laws

syncAccountsSource :: Text
syncAccountsSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "account assets:backing"
  , "  type: Asset"
  , "account expenses:fixed"
  , "  type: Expense"
  , "account expenses:other"
  , "  type: Expense"
  , "account budget:daily"
  , "  type: Budget"
  , "account budget:spent"
  , "  type: Budget"
  , "account budget:unassigned"
  , "  type: Budget"
  , "account income:pension"
  , "  type: Income"
  ]

syncPlanSource :: Text
syncPlanSource = syncAccountsSource <> T.unlines
  [ ""
  , "2031-01-17 planned fixed payment"
  , "  ; plan-id: plan-fixed"
  , "  expenses:fixed    300 JPY"
  , "  assets:cash      -300 JPY"
  ]

syncActualSource :: Text
syncActualSource = syncActualSourceWithPostings
  [ "  expenses:fixed    275 JPY"
  , "  assets:cash      -275 JPY"
  ]

syncActualSourceWithPostings :: [Text] -> Text
syncActualSourceWithPostings postings = syncAccountsSource <> T.unlines
  ( [ ""
    , "2031-01-18 * completed fixed payment"
    , "  ; event-id: actual-fixed"
    , "  ; plan-id: plan-fixed"
    ]
      ++ postings
  )

syncDuplicateCompletionSource :: Text
syncDuplicateCompletionSource = syncAccountsSource <> T.unlines
  [ ""
  , "2031-01-18 * first completion"
  , "  ; event-id: actual-first"
  , "  ; plan-id: plan-fixed"
  , "  expenses:fixed    275 JPY"
  , "  assets:cash      -275 JPY"
  , ""
  , "2031-01-19 * competing completion"
  , "  ; event-id: actual-second"
  , "  ; plan-id: plan-fixed"
  , "  expenses:fixed    275 JPY"
  , "  assets:cash      -275 JPY"
  ]

syncUnlinkedPlanSource :: Text
syncUnlinkedPlanSource = syncAccountsSource <> T.unlines
  [ ""
  , "2031-01-17 planned other payment"
  , "  ; plan-id: plan-other"
  , "  expenses:other    300 JPY"
  , "  assets:cash      -300 JPY"
  ]

syncUnlinkedActualSource :: Text
syncUnlinkedActualSource = syncAccountsSource <> T.unlines
  [ ""
  , "2031-01-18 * completed other payment"
  , "  ; event-id: actual-other"
  , "  ; plan-id: plan-other"
  , "  expenses:other    275 JPY"
  , "  assets:cash      -275 JPY"
  ]

syncBudgetRoot :: Text
syncBudgetRoot = "include accounts.journal\n"

syncRegistry :: AccountRegistry
syncRegistry = mustRight (parseAccountJournal syncAccountsSource)

syncPlanJournal :: PlanJournal
syncPlanJournal = mustRight (parsePlanJournal syncPlanSource)

syncActualJournal :: ActualJournal
syncActualJournal = mustRight (parseActualJournal syncActualSource)

syncPlanId :: PlanId
syncPlanId = mustRight (mkPlanId "plan-fixed")

syncUnlinkedPlanId :: PlanId
syncUnlinkedPlanId = mustRight (mkPlanId "plan-other")

syncHouseholdPolicy :: HouseholdPolicy
syncHouseholdPolicy =
  let envelope = mustRight (mkEnvelopeId "daily")
      label = mustRight (mkEnvelopeLabel "Daily")
      backingPool = mustRight (mkBackingPoolId "liquid")
      backingPolicy = mustRight (mkBackingPolicy
        [defineBackingPool backingPool [account "assets:backing"]]
        [assignEnvelopeBackingPool envelope backingPool])
      envelopePolicy = mustRight (mkCurrentEnvelopePolicy
        [ defineEnvelope
            envelope
            label
            Daily
            [account "expenses:fixed"]
        ]
        backingPolicy)
  in mustRight (mkHouseholdPolicy
      (incomeAnchorCyclePolicy (account "income:pension"))
      envelopePolicy
      [ defineHouseholdEnvelopeCoordinates
          envelope
          (account "budget:daily")
          []
      ]
      [account "budget:unassigned"])

syncAccountPolicy :: HouseholdAccountPolicy
syncAccountPolicy = mustRight (mkHouseholdAccountPolicy
  []
  [ (account "budget:daily", RetainedEnvelopeBudgetAccount)
  , (account "budget:spent", RetainedSpentBudgetAccount)
  , (account "budget:unassigned", RetainedUnassignedBudgetAccount)
  ]
  [ (account "budget:daily", RetainedExecutionEnvelopeRole) ]
  []
  [ (account "expenses:fixed", RetainedFixedSpend) ])

syncBudgetJournal source =
  mustRight
    (admitHouseholdBudgetMovementJournalFromResolvedJournal
      resolved
      source)
  where
    rootTransactions = T.unlines (drop 1 (T.lines source))
    resolved = mustRight (parseJournal (syncAccountsSource <> rootTransactions))

prepareSync
  :: PlanJournal
  -> ActualJournal
  -> Text
  -> PlanId
  -> Either (NonEmpty PlanBudgetSyncError) PlanBudgetSyncResult
prepareSync planJournal actualJournal budgetSource target =
  preparePlanBudgetSync
    syncRegistry
    syncHouseholdPolicy
    (Just syncAccountPolicy)
    planJournal
    actualJournal
    (syncBudgetJournal budgetSource)
    budgetSource
    target

testPlanBudgetSyncUsesActualAmount :: Bool
testPlanBudgetSyncUsesActualAmount =
  case prepareSync syncPlanJournal syncActualJournal syncBudgetRoot syncPlanId of
    Right (PlanBudgetSyncAppend preview) ->
      "plan-id: plan-fixed" `T.isInfixOf` planBudgetSyncCandidateBlock preview
        && "actual-event-id: actual-fixed" `T.isInfixOf` planBudgetSyncCandidateBlock preview
        && "275 JPY" `T.isInfixOf` planBudgetSyncCandidateBlock preview
        && not ("300 JPY" `T.isInfixOf` planBudgetSyncCandidateBlock preview)
    _ -> False

testPlanBudgetSyncIdempotent :: Bool
testPlanBudgetSyncIdempotent =
  case prepareSync syncPlanJournal syncActualJournal syncBudgetRoot syncPlanId of
    Right (PlanBudgetSyncAppend preview) ->
      prepareSync
        syncPlanJournal
        syncActualJournal
        (planBudgetSyncCandidateCompleteSource preview)
        syncPlanId
        == Right (PlanBudgetSyncApplied syncPlanId)
    _ -> False

testPlanBudgetSyncShapeMismatch :: Bool
testPlanBudgetSyncShapeMismatch =
  case parseActualJournal (syncActualSourceWithPostings
      [ "  assets:cash      -275 JPY"
      , "  expenses:fixed    275 JPY"
      ]) of
    Left _ -> False
    Right actualJournal -> hasSyncError isShape
      (prepareSync syncPlanJournal actualJournal syncBudgetRoot syncPlanId)
  where
    isShape err = case err of
      PlanBudgetSyncShapeMismatch target -> target == syncPlanId
      _ -> False

testPlanBudgetSyncDirectionMismatch :: Bool
testPlanBudgetSyncDirectionMismatch =
  case parseActualJournal (syncActualSourceWithPostings
      [ "  expenses:fixed   -275 JPY"
      , "  assets:cash       275 JPY"
      ]) of
    Left _ -> False
    Right actualJournal -> hasSyncError isDirection
      (prepareSync syncPlanJournal actualJournal syncBudgetRoot syncPlanId)
  where
    isDirection err = case err of
      PlanBudgetSyncDirectionMismatch target -> target == syncPlanId
      _ -> False

testPlanBudgetSyncCommodityMismatch :: Bool
testPlanBudgetSyncCommodityMismatch =
  case parseActualJournal (syncActualSourceWithPostings
      [ "  expenses:fixed    275 USD"
      , "  assets:cash      -275 USD"
      ]) of
    Left _ -> False
    Right actualJournal -> hasSyncError isCommodity
      (prepareSync syncPlanJournal actualJournal syncBudgetRoot syncPlanId)
  where
    isCommodity err = case err of
      PlanBudgetSyncCommodityMismatch target -> target == syncPlanId
      _ -> False

testPlanBudgetSyncDuplicateCompletion :: Bool
testPlanBudgetSyncDuplicateCompletion =
  case parseActualJournal syncDuplicateCompletionSource of
    Left _ -> False
    Right actualJournal -> hasSyncError isDuplicate
      (prepareSync syncPlanJournal actualJournal syncBudgetRoot syncPlanId)
  where
    isDuplicate err = case err of
      PlanBudgetSyncCompletionDuplicate target -> target == syncPlanId
      _ -> False

testPlanBudgetSyncExistingLinkageMismatch :: Bool
testPlanBudgetSyncExistingLinkageMismatch =
  case prepareSync syncPlanJournal syncActualJournal syncBudgetRoot syncPlanId of
    Right (PlanBudgetSyncAppend preview) ->
      let mismatchedSource = T.replace
            "actual-event-id: actual-fixed"
            "actual-event-id: actual-other"
            (planBudgetSyncCandidateCompleteSource preview)
      in hasSyncError isMismatch
          (prepareSync
            syncPlanJournal
            syncActualJournal
            mismatchedSource
            syncPlanId)
    _ -> False
  where
    isMismatch err = case err of
      PlanBudgetSyncExistingLinkageMismatch target -> target == syncPlanId
      _ -> False

testPlanBudgetSyncDuplicateLinkage :: Bool
testPlanBudgetSyncDuplicateLinkage =
  case prepareSync syncPlanJournal syncActualJournal syncBudgetRoot syncPlanId of
    Right (PlanBudgetSyncAppend preview) ->
      let duplicateSource = planBudgetSyncCandidateCompleteSource preview
            <> "\n"
            <> planBudgetSyncCandidateBlock preview
      in hasSyncError isDuplicate
          (prepareSync
            syncPlanJournal
            syncActualJournal
            duplicateSource
            syncPlanId)
    _ -> False
  where
    isDuplicate err = case err of
      PlanBudgetSyncDuplicateBudgetLinkage target -> target == syncPlanId
      _ -> False

testPlanBudgetSyncNotLinked :: Bool
testPlanBudgetSyncNotLinked =
  case ( parsePlanJournal syncUnlinkedPlanSource
       , parseActualJournal syncUnlinkedActualSource
       ) of
    (Right planJournal, Right actualJournal) ->
      prepareSync planJournal actualJournal syncBudgetRoot syncUnlinkedPlanId
        == Right (PlanBudgetSyncNotLinked syncUnlinkedPlanId)
    _ -> False

hasSyncError
  :: (PlanBudgetSyncError -> Bool)
  -> Either (NonEmpty PlanBudgetSyncError) PlanBudgetSyncResult
  -> Bool
hasSyncError predicate result = case result of
  Left errors -> any predicate (NonEmpty.toList errors)
  Right _ -> False

account :: Text -> Account
account = mustRight . mkAccount

jpy = mustRight (mkCommodity "JPY")



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
