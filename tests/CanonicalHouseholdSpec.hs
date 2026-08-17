{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , removeDirectoryRecursive
  , removeFile
  )
import System.Exit (exitFailure)
import System.FilePath ((</>))

import HKernel.Account
  ( AccountType(..)
  , declareAccountWithDefaultCommodity
  , mkAccount
  )
import HKernel.Account.Journal (parseAccountJournal)
import HKernel.Application.Config (mkHouseholdRoot)
import HKernel.Editor.AccountAppend
  ( accountCandidateBlock
  , prepareAccountJournalAppend
  )
import HKernel.Editor.EntitlementTransferAppend
  ( entitlementCandidateBlock
  , entitlementCandidateCompleteSource
  , prepareEntitlementTransferAppend
  )
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteError(..)
  , WriteIntent(..)
  , publishActualBlockWithPathAdmission
  , publishWithPathAdmission
  )
import qualified HKernel.Editor.IssueAppend as IssueAppend
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , EnvelopeEntitlementTransfer
  , mkEnvelopeEntitlementTransfer
  )
import HKernel.Envelope.Identity (mkEnvelopeId, mkEnvelopeRegistry)
import HKernel.Household.Application
  ( HouseholdLoadError(..)
  , HouseholdState(..)
  , HouseholdWriteSnapshot(..)
  , admitCanonicalHousehold
  , buildHouseholdReportSurfaceFromHousehold
  , loadCanonicalHousehold
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.Household.Config
  ( householdConfigurationDailyTargetAssets
  )
import HKernel.HouseholdIssue (IssueStatus(..), mkIssueId)
import HKernel.Money (mkAmount, mkCommodity, quantityFromInteger)

main :: IO ()
main = do
  putStrLn "Running CanonicalHouseholdSpec..."
  testSyntheticRootLoading
  testActualWholeHouseholdRollback
  testAccountWriteSnapshotOwnership
  testEntitlementWriteSnapshotOwnership
  testEntitlementWholeHouseholdRollback
  testIssueWriteSnapshotOwnership
  testIssueWholeHouseholdRollback
  testRegistryDisagreementFailure
  testInMemoryAdmission
  testFirstFailurePrecedence
  testNativePlanMetadataFailsClosed
  testMissingSourceFailure
  testUnknownIncludeRejected
  testNativeAccountAppend
  testNativeEntitlementTransferAppend
  putStrLn "CanonicalHouseholdSpec PASSED."

testSyntheticRootLoading :: IO ()
testSyntheticRootLoading = do
  let dir = "/tmp/synthetic_household_spec"
  resetDirectory dir
  writeSyntheticFiles dir syntheticAccounts syntheticActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues

  root <- case mkHouseholdRoot dir of
    Left err -> die ("mkHouseholdRoot failed: " <> show err)
    Right r -> pure r

  loadResult <- loadCanonicalHousehold root
  state <- case loadResult of
    Left errs -> die ("loadCanonicalHousehold failed:\n" <> unlines (map show (NonEmpty.toList errs)))
    Right s -> pure s

  unless (length (householdConfigurationDailyTargetAssets (householdStateConfiguration state)) == 1)
    (die "household.toml Daily Target asset selection was not retained")

  let observation = fromGregorian 2026 7 20
  case buildHouseholdReportSurfaceFromHousehold observation state of
    Left errs -> die ("buildHouseholdReportSurfaceFromHousehold failed:\n" <> unlines (map show (NonEmpty.toList errs)))
    Right _ -> pure ()

  removeDirectoryRecursive dir

testActualWholeHouseholdRollback :: IO ()
testActualWholeHouseholdRollback = do
  let dir = "/tmp/synthetic_household_actual_rollback_spec"
      actualPath = dir </> "actual.journal"
      reportPath = dir </> "report.toml"
  resetDirectory dir
  writeSyntheticFiles dir syntheticAccounts syntheticActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues

  root <- case mkHouseholdRoot dir of
    Left err -> die ("mkHouseholdRoot failed: " <> show err)
    Right r -> pure r

  snapshotResult <- loadCanonicalHouseholdWriteSnapshot root
  snapshot <- case snapshotResult of
    Left errs -> die
      ("loadCanonicalHouseholdWriteSnapshot failed:\n"
        <> unlines (map show (NonEmpty.toList errs)))
    Right value -> pure value

  let existingSource = householdWriteSnapshotActualSource snapshot
      candidateBlock = T.unlines
        [ "2026-07-20 * Probe"
        , "  Assets:Bank  -100 JPY"
        , "  Expenses:Groceries"
        ]

  TIO.writeFile reportPath "[reports.trial-balance\n"
  result <- publishActualBlockWithPathAdmission
    (\_ -> loadCanonicalHousehold root)
    actualPath
    existingSource
    candidateBlock
  case result of
    Left (PostAdmissionFailed _ True) -> pure ()
    other -> die ("Expected checked Actual Household rollback, got: " <> show other)

  restoredActual <- TIO.readFile actualPath
  unless (restoredActual == existingSource)
    (die "Whole-Household admission failure did not restore actual.journal")

  removeDirectoryRecursive dir

testAccountWriteSnapshotOwnership :: IO ()
testAccountWriteSnapshotOwnership = do
  let dir = "/tmp/synthetic_household_account_snapshot_spec"
  resetDirectory dir
  writeSyntheticFiles dir syntheticAccounts syntheticActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues

  root <- case mkHouseholdRoot dir of
    Left err -> die ("mkHouseholdRoot failed: " <> show err)
    Right r -> pure r

  snapshotResult <- loadCanonicalHouseholdWriteSnapshot root
  snapshot <- case snapshotResult of
    Left errs -> die
      ("loadCanonicalHouseholdWriteSnapshot failed:\n"
        <> unlines (map show (NonEmpty.toList errs)))
    Right value -> pure value

  unless (householdWriteSnapshotAccountsSource snapshot == syntheticAccounts)
    (die "Household write snapshot did not retain exact accounts.journal root bytes")

  removeDirectoryRecursive dir

testEntitlementWriteSnapshotOwnership :: IO ()
testEntitlementWriteSnapshotOwnership = do
  let dir = "/tmp/synthetic_household_entitlement_snapshot_spec"
  resetDirectory dir
  writeSyntheticFiles dir syntheticAccounts syntheticActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues

  root <- case mkHouseholdRoot dir of
    Left err -> die ("mkHouseholdRoot failed: " <> show err)
    Right r -> pure r

  snapshotResult <- loadCanonicalHouseholdWriteSnapshot root
  snapshot <- case snapshotResult of
    Left errs -> die
      ("loadCanonicalHouseholdWriteSnapshot failed:\n"
        <> unlines (map show (NonEmpty.toList errs)))
    Right value -> pure value

  unless (householdWriteSnapshotEntitlementSource snapshot == syntheticEntitlement)
    (die "Household write snapshot did not retain exact entitlement.journal root bytes")

  transfer <- syntheticEntitlementTransfer
  dailyId <- case mkEnvelopeId "Daily" of
    Left err -> die ("mkEnvelopeId failed: " <> show err)
    Right e -> pure e
  registry <- case mkEnvelopeRegistry [dailyId] of
    Left err -> die ("mkEnvelopeRegistry failed: " <> show err)
    Right r -> pure r
  case prepareEntitlementTransferAppend
      registry
      (householdWriteSnapshotEntitlementSource snapshot)
      transfer of
    Left errs -> die ("Snapshot-owned Entitlement preparation failed: " <> show errs)
    Right preview ->
      unless ("Daily" `T.isInfixOf` entitlementCandidateBlock preview)
        (die "Snapshot-owned Entitlement candidate did not use admitted Envelope")

  removeDirectoryRecursive dir

testEntitlementWholeHouseholdRollback :: IO ()
testEntitlementWholeHouseholdRollback = do
  let dir = "/tmp/synthetic_household_entitlement_rollback_spec"
      entitlementPath = dir </> "entitlement.journal"
      reportPath = dir </> "report.toml"
  resetDirectory dir
  writeSyntheticFiles dir syntheticAccounts syntheticActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues

  root <- case mkHouseholdRoot dir of
    Left err -> die ("mkHouseholdRoot failed: " <> show err)
    Right r -> pure r

  snapshotResult <- loadCanonicalHouseholdWriteSnapshot root
  snapshot <- case snapshotResult of
    Left errs -> die
      ("loadCanonicalHouseholdWriteSnapshot failed:\n"
        <> unlines (map show (NonEmpty.toList errs)))
    Right value -> pure value

  transfer <- syntheticEntitlementTransfer
  let existingSource = householdWriteSnapshotEntitlementSource snapshot
  dailyId <- case mkEnvelopeId "Daily" of
    Left err -> die ("mkEnvelopeId failed: " <> show err)
    Right e -> pure e
  registry <- case mkEnvelopeRegistry [dailyId] of
    Left err -> die ("mkEnvelopeRegistry failed: " <> show err)
    Right r -> pure r
  preview <- case prepareEntitlementTransferAppend registry existingSource transfer of
    Left errs -> die ("Entitlement transfer preparation failed: " <> show errs)
    Right value -> pure value

  TIO.writeFile reportPath "[reports.trial-balance\n"
  result <- publishWithPathAdmission
    (\_ -> loadCanonicalHousehold root)
    WriteIntent
      { targetFilePath = entitlementPath
      , expectedOldBytes = ExpectedSource existingSource
      , candidateNewBytes = CandidateSource
          (entitlementCandidateCompleteSource preview)
      }
  case result of
    Left (PostAdmissionFailed _ True) -> pure ()
    other -> die ("Expected checked Entitlement Household rollback, got: " <> show other)

  restoredEntitlement <- TIO.readFile entitlementPath
  unless (restoredEntitlement == existingSource)
    (die "Whole-Household admission failure did not restore entitlement.journal")

  removeDirectoryRecursive dir

testIssueWriteSnapshotOwnership :: IO ()
testIssueWriteSnapshotOwnership = do
  let dir = "/tmp/synthetic_household_issue_snapshot_spec"
  resetDirectory dir
  writeSyntheticFiles dir syntheticAccounts syntheticActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues

  root <- case mkHouseholdRoot dir of
    Left err -> die ("mkHouseholdRoot failed: " <> show err)
    Right r -> pure r

  snapshotResult <- loadCanonicalHouseholdWriteSnapshot root
  snapshot <- case snapshotResult of
    Left errs -> die
      ("loadCanonicalHouseholdWriteSnapshot failed:\n"
        <> unlines (map show (NonEmpty.toList errs)))
    Right value -> pure value

  unless (householdWriteSnapshotIssuesSource snapshot == syntheticIssues)
    (die "Household write snapshot did not retain exact issues.tsv bytes")

  removeDirectoryRecursive dir

testIssueWholeHouseholdRollback :: IO ()
testIssueWholeHouseholdRollback = do
  let dir = "/tmp/synthetic_household_issue_rollback_spec"
      issuesPath = dir </> "issues.tsv"
      reportPath = dir </> "report.toml"
  resetDirectory dir
  writeSyntheticFiles dir syntheticAccounts syntheticActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues

  root <- case mkHouseholdRoot dir of
    Left err -> die ("mkHouseholdRoot failed: " <> show err)
    Right r -> pure r

  snapshotResult <- loadCanonicalHouseholdWriteSnapshot root
  snapshot <- case snapshotResult of
    Left errs -> die
      ("loadCanonicalHouseholdWriteSnapshot failed:\n"
        <> unlines (map show (NonEmpty.toList errs)))
    Right value -> pure value

  issueId <- case mkIssueId "ISS2" of
    Left err -> die ("mkIssueId failed: " <> show err)
    Right value -> pure value
  let existingSource = householdWriteSnapshotIssuesSource snapshot
      intent = IssueAppend.IssueAppendIntent
        { IssueAppend.intentIssueId = issueId
        , IssueAppend.intentStatus = Open
        , IssueAppend.intentDate = fromGregorian 2026 7 20
        , IssueAppend.intentCategory = "general"
        , IssueAppend.intentTitle = "Rollback probe"
        , IssueAppend.intentAmount = Nothing
        , IssueAppend.intentDetails = "Issue publication probe"
        }
  preview <- case IssueAppend.prepareIssueAppend existingSource intent of
    Left errs -> die ("Issue append preparation failed: " <> show errs)
    Right value -> pure value

  TIO.writeFile reportPath "[reports.trial-balance\n"
  result <- publishWithPathAdmission
    (\_ -> loadCanonicalHousehold root)
    WriteIntent
      { targetFilePath = issuesPath
      , expectedOldBytes = ExpectedSource existingSource
      , candidateNewBytes = CandidateSource
          (IssueAppend.candidateCompleteSource preview)
      }
  case result of
    Left (PostAdmissionFailed _ True) -> pure ()
    other -> die ("Expected checked Issue Household rollback, got: " <> show other)

  restoredIssues <- TIO.readFile issuesPath
  unless (restoredIssues == existingSource)
    (die "Whole-Household admission failure did not restore issues.tsv")

  removeDirectoryRecursive dir

testRegistryDisagreementFailure :: IO ()
testRegistryDisagreementFailure = do
  let dir = "/tmp/synthetic_household_disagree_spec"
  resetDirectory dir
  let accountsText = syntheticAccounts <> "\naccount Assets:Crypto\n  type: Asset\n  commodity: BTC\n"
      actualAccountsText = syntheticAccounts <> "\naccount Assets:Crypto\n  type: Asset\n  commodity: ETH\n"
      actualText = "include actual_accounts.journal\n\n2026-06-01 * Income anchor\n  Income:Salary  -300000 JPY\n  Assets:Bank\n"
  TIO.writeFile (dir </> "actual_accounts.journal") actualAccountsText
  writeSyntheticFiles dir accountsText actualText syntheticPlan syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues

  root <- case mkHouseholdRoot dir of
    Left err -> die ("mkHouseholdRoot failed: " <> show err)
    Right r -> pure r

  loadResult <- loadCanonicalHousehold root
  case loadResult of
    Left errs -> case NonEmpty.head errs of
      HouseholdAccountRegistryDisagreement {} -> pure ()
      other -> die ("Expected HouseholdAccountRegistryDisagreement, got: " <> show other)
    Right _ -> die "Expected failure on registry disagreement, but succeeded"

  removeDirectoryRecursive dir

testInMemoryAdmission :: IO ()
testInMemoryAdmission = do
  let dir = "/tmp/synthetic_household_inmemory_spec"
  resetDirectory dir
  writeSyntheticFiles dir syntheticAccounts syntheticActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues

  root <- case mkHouseholdRoot dir of
    Left err -> die ("mkHouseholdRoot failed: " <> show err)
    Right r -> pure r

  loadResult <- loadCanonicalHousehold root
  fsState <- case loadResult of
    Left errs -> die ("loadCanonicalHousehold failed:\n" <> unlines (map show (NonEmpty.toList errs)))
    Right s -> pure s

  pureState <- case admitCanonicalHousehold root syntheticAccounts syntheticActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues of
    Left errs -> die ("admitCanonicalHousehold failed:\n" <> unlines (map show (NonEmpty.toList errs)))
    Right s -> pure s

  unless (fsState == pureState)
    (die "loadCanonicalHousehold and admitCanonicalHousehold produced different HouseholdState for same synthetic sources")

  unless (length (householdConfigurationDailyTargetAssets (householdStateConfiguration pureState)) == 1)
    (die "in-memory Household discarded Daily Target asset policy")
  let observation = fromGregorian 2026 7 20
  case buildHouseholdReportSurfaceFromHousehold observation pureState of
    Left errs -> die ("buildHouseholdReportSurfaceFromHousehold in memory failed:\n" <> unlines (map show (NonEmpty.toList errs)))
    Right _ -> pure ()

  removeDirectoryRecursive dir

testFirstFailurePrecedence :: IO ()
testFirstFailurePrecedence = do
  let dir = "/tmp/synthetic_household_precedence_spec"
      invalidHouseholdToml = T.unlines
        [ "[cycle]"
        , "mode = \"income-anchor\""
        , "income-account = \"Income:Salary\""
        , ""
        , "[budget]"
        , "opening-accounts = [\"Budget:Opening\"]"
        , "unassigned-accounts = [\"Budget:Living\"]"
        ]
      invalidReportToml = "[reports.trial-balance\n"

  resetDirectory dir
  writeSyntheticFiles dir syntheticAccounts syntheticActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml invalidHouseholdToml invalidReportToml syntheticIssues

  root <- case mkHouseholdRoot dir of
    Left err -> die ("mkHouseholdRoot failed: " <> show err)
    Right r -> pure r

  fsResult <- loadCanonicalHousehold root
  case fsResult of
    Left errs -> case NonEmpty.head errs of
      HouseholdPolicyParseFailed _ -> pure ()
      other -> die ("Expected retired Household policy syntax to fail before report admission, got: " <> show other <> "\nFull errors: " <> show (NonEmpty.toList errs))
    Right _ -> die "Expected failure on retired household policy syntax, but succeeded"

  let pureResult = admitCanonicalHousehold root syntheticAccounts syntheticActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml invalidHouseholdToml invalidReportToml syntheticIssues
  case pureResult of
    Left errs -> case NonEmpty.head errs of
      HouseholdPolicyParseFailed _ -> pure ()
      other -> die ("Expected retired Household policy syntax first on pure path, got: " <> show other)
    Right _ -> die "Expected failure on retired household policy syntax, but succeeded"

  removeDirectoryRecursive dir

testNativePlanMetadataFailsClosed :: IO ()
testNativePlanMetadataFailsClosed = do
  let root = case mkHouseholdRoot "." of
        Right r -> r
        Left _ -> error "unreachable"
  case admitCanonicalHousehold root syntheticAccounts syntheticActual syntheticPlanPartialReservation syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues of
    Left errs -> case NonEmpty.head errs of
      HouseholdDailyTargetPlanMetadataFailed _ -> pure ()
      other -> die ("Expected HouseholdDailyTargetPlanMetadataFailed, got: " <> show other)
    Right _ -> die "Partial native reservation metadata unexpectedly fell back or succeeded"

testMissingSourceFailure :: IO ()
testMissingSourceFailure = do
  let dir = "/tmp/synthetic_household_missing_spec"
      missingPath = dir </> "report.toml"
  resetDirectory dir
  writeSyntheticFiles dir syntheticAccounts syntheticActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues
  removeFile missingPath
  root <- case mkHouseholdRoot dir of
    Left err -> die ("mkHouseholdRoot failed: " <> show err)
    Right r -> pure r
  loadResult <- loadCanonicalHousehold root
  case loadResult of
    Left errs -> case NonEmpty.head errs of
      HouseholdSourceReadFailed path _ | path == missingPath -> pure ()
      other -> die ("Expected typed missing report.toml error, got: " <> show other)
    Right _ -> die "Missing canonical source unexpectedly loaded"
  removeDirectoryRecursive dir

testUnknownIncludeRejected :: IO ()
testUnknownIncludeRejected = do
  let root = case mkHouseholdRoot "." of
        Right r -> r
        Left _ -> error "unreachable"
      unknownActual = T.replace "include accounts.journal" "include typo-accounts.journal" syntheticActual
  case admitCanonicalHousehold root syntheticAccounts unknownActual syntheticPlan syntheticEntitlement syntheticEnvelopeToml syntheticHouseholdToml syntheticReportToml syntheticIssues of
    Left errs -> case NonEmpty.head errs of
      HouseholdActualParseFailed _ -> pure ()
      other -> die ("Expected unknown include rejection, got: " <> show other)
    Right _ -> die "Unknown in-memory include unexpectedly resolved as accounts.journal"

testNativeAccountAppend :: IO ()
testNativeAccountAppend = do
  acc <- case mkAccount "Assets:Cash" of
    Left err -> die ("mkAccount failed: " <> show err)
    Right a -> pure a
  comm <- case mkCommodity "JPY" of
    Left err -> die ("mkCommodity failed: " <> show err)
    Right c -> pure c
  let decl = declareAccountWithDefaultCommodity acc Asset comm
  case prepareAccountJournalAppend syntheticAccounts decl of
    Left errs -> die ("prepareAccountJournalAppend failed: " <> show errs)
    Right preview -> do
      let candidate = accountCandidateBlock preview
      unless ("account Assets:Cash" `T.isInfixOf` candidate)
        (die "Account candidate block missing account name")

testNativeEntitlementTransferAppend :: IO ()
testNativeEntitlementTransferAppend = do
  dailyId <- case mkEnvelopeId "Daily" of
    Left err -> die ("mkEnvelopeId failed: " <> show err)
    Right e -> pure e
  registry <- case mkEnvelopeRegistry [dailyId] of
    Left err -> die ("mkEnvelopeRegistry failed: " <> show err)
    Right r -> pure r
  comm <- case mkCommodity "JPY" of
    Left err -> die ("mkCommodity failed: " <> show err)
    Right c -> pure c
  transfer <- case mkEnvelopeEntitlementTransfer
      (fromGregorian 2026 7 1)
      Unallocated
      (Spendable dailyId)
      (mkAmount comm (quantityFromInteger 10000))
      "Allocate" of
    Left err -> die ("mkEnvelopeEntitlementTransfer failed: " <> show err)
    Right t -> pure t
  case prepareEntitlementTransferAppend registry syntheticEntitlement transfer of
    Left errs -> die ("prepareEntitlementTransferAppend failed: " <> show errs)
    Right preview -> do
      let candidate = entitlementCandidateBlock preview
      unless ("Daily" `T.isInfixOf` candidate)
        (die "Entitlement candidate block missing envelope id")

syntheticEntitlementTransfer :: IO EnvelopeEntitlementTransfer
syntheticEntitlementTransfer = do
  dailyId <- case mkEnvelopeId "Daily" of
    Left err -> die ("mkEnvelopeId failed: " <> show err)
    Right e -> pure e
  commodity <- case mkCommodity "JPY" of
    Left err -> die ("mkCommodity failed: " <> show err)
    Right value -> pure value
  case mkEnvelopeEntitlementTransfer
      (fromGregorian 2026 7 2)
      Unallocated
      (Spendable dailyId)
      (mkAmount commodity (quantityFromInteger 10000))
      "Reallocate" of
    Left err -> die ("mkEnvelopeEntitlementTransfer failed: " <> show err)
    Right t -> pure t

resetDirectory :: FilePath -> IO ()
resetDirectory dir = do
  exists <- doesDirectoryExist dir
  if exists then removeDirectoryRecursive dir else pure ()
  createDirectoryIfMissing True dir

writeSyntheticFiles
  :: FilePath
  -> Text -> Text -> Text -> Text -> Text -> Text -> Text -> Text
  -> IO ()
writeSyntheticFiles dir accounts actual plan entitlement envelopeToml householdToml reportToml issues = do
  TIO.writeFile (dir </> "accounts.journal") accounts
  TIO.writeFile (dir </> "actual.journal") actual
  TIO.writeFile (dir </> "plan.journal") plan
  TIO.writeFile (dir </> "entitlement.journal") entitlement
  TIO.writeFile (dir </> "envelope.toml") envelopeToml
  TIO.writeFile (dir </> "household.toml") householdToml
  TIO.writeFile (dir </> "report.toml") reportToml
  TIO.writeFile (dir </> "issues.tsv") issues

die :: String -> IO a
die msg = putStrLn msg >> exitFailure

syntheticAccounts :: Text
syntheticAccounts = T.unlines
  [ "account Assets:Bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account Income:Salary"
  , "  type: Income"
  , "  commodity: JPY"
  , ""
  , "account Expenses:Groceries"
  , "  type: Expense"
  , "  commodity: JPY"
  ]

syntheticActual :: Text
syntheticActual = T.unlines
  [ "include accounts.journal"
  , ""
  , "2026-06-01 * Income anchor"
  , "  Income:Salary  -300000 JPY"
  , "  Assets:Bank"
  , ""
  , "2026-07-01 * Income anchor"
  , "  Income:Salary  -300000 JPY"
  , "  Assets:Bank"
  , ""
  , "2026-07-15 * Grocery Store"
  , "  Assets:Bank  -5000 JPY"
  , "  Expenses:Groceries"
  ]

syntheticPlan :: Text
syntheticPlan = T.unlines
  [ "include accounts.journal"
  , ""
  , "2026-08-01 * Income anchor"
  , "  ; plan-id: P001"
  , "  Income:Salary  -300000 JPY"
  , "  Assets:Bank"
  , ""
  , "2026-07-25 * Planned Groceries"
  , "  ; plan-id: P100"
  , "  Assets:Bank  -4000 JPY"
  , "  Expenses:Groceries"
  ]

syntheticPlanPartialReservation :: Text
syntheticPlanPartialReservation = T.unlines
  [ "include accounts.journal"
  , ""
  , "2026-08-01 * Income anchor"
  , "  ; plan-id: P001"
  , "  Income:Salary  -300000 JPY"
  , "  Assets:Bank"
  , ""
  , "2026-07-25 * Planned Groceries"
  , "  ; plan-id: P100"
  , "  ; daily-target-id: groceries"
  , "  ; reservation-id: reservation:groceries"
  , "  ; reservation-amount: 50"
  , "  Assets:Bank  -4000 JPY"
  , "  Expenses:Groceries"
  ]

syntheticEntitlement :: Text
syntheticEntitlement = T.unlines
  [ "2026-06-01 origin JPY"
  , "2026-07-01 alloc unallocated -> Daily 100000 JPY"
  ]

syntheticEnvelopeToml :: Text
syntheticEnvelopeToml = T.unlines
  [ "[[backing-pools]]"
  , "id = \"main\""
  , "asset-accounts = [\"Assets:Bank\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"Daily\""
  , "label = \"Daily\""
  , "pacing = \"daily\""
  , "backing-pool = \"main\""
  ]

syntheticHouseholdToml :: Text
syntheticHouseholdToml = T.unlines
  [ "[cycle]"
  , "mode = \"income-anchor\""
  , "income-account = \"Income:Salary\""
  , ""
  , "[daily-target]"
  , ""
  , "[[daily-target.assets]]"
  , "id = \"bank\""
  , "account = \"Assets:Bank\""
  , ""
  , "[envelope-history]"
  , "identities = [\"Daily\"]"
  , ""
  , "[[envelope-history.expense-routing]]"
  , "effective-from = \"initial\""
  , "expense-account = \"Expenses:Groceries\""
  , "route = \"managed\""
  , "target = \"Daily\""
  , "note = \"synthetic canonical initial routing\""
  ]

syntheticReportToml :: Text
syntheticReportToml = T.unlines
  [ "[presentation.amounts]"
  , "negative-style = \"minus\""
  , ""
  , "[reports.trial-balance]"
  , "as-of = \"latest\""
  , ""
  , "[reports.balance-sheet]"
  , "as-of = \"latest\""
  , ""
  , "[reports.profit-and-loss]"
  , "from = \"2026-07-01\""
  , "through = \"latest\""
  , ""
  , "[reports.daily-flow]"
  , "from = \"2026-07-01\""
  , "through = \"latest\""
  , "max-date-columns = 5"
  , ""
  , "[reports.monthly-accounts]"
  , "from = \"2026-07-01\""
  , "through = \"latest\""
  , ""
  , "[reports.recent-transactions]"
  , "through = \"latest\""
  , "count = 5"
  ]

syntheticIssues :: Text
syntheticIssues = T.unlines
  [ "issue_id\tstatus\tdate\tcategory\ttitle\tamount\tcurrency\tdetails"
  , "ISS1\topen\t2026-07-01\tgeneral\tTest Issue\t100\tJPY\tDetails text"
  ]
