{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (IOException, catch)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , removeDirectoryRecursive
  )
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>))

import HKernel.Account
  ( AccountType(..)
  , declareAccountWithDefaultCommodity
  , mkAccount
  )
import HKernel.Application.Config (HouseholdRoot, mkHouseholdRoot)
import HKernel.Editor.AccountAppend
  ( AccountJournalAppendPreview(..)
  , prepareAccountJournalAppend
  )
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteError(..)
  , WriteIntent(..)
  , publishWithPathAdmission
  )
import HKernel.Household.Application (loadCanonicalHousehold)
import HKernel.Money (mkCommodity)

main :: IO ()
main = do
  results <- sequence
    [ named "canonical Account publication succeeds through Household admission"
        testAccountWholeHouseholdSuccess
    , named "canonical Account publication rolls back on Household rejection"
        testAccountWholeHouseholdRollback
    ]
  mapM_ print results
  if all snd results then exitSuccess else exitFailure
  where
    named label action = do
      result <- action `catch` (\(_ :: IOException) -> pure False)
      pure (label, result)

testAccountWholeHouseholdSuccess :: IO Bool
testAccountWholeHouseholdSuccess = withSyntheticHousehold $ \dir root -> do
  candidate <- accountCandidate
  let accountPath = dir </> "accounts.journal"
  result <- publishWithPathAdmission
    (\_ -> loadCanonicalHousehold root)
    WriteIntent
      { targetFilePath = accountPath
      , expectedOldBytes = ExpectedSource syntheticAccounts
      , candidateNewBytes = CandidateSource candidate
      }
  loaded <- loadCanonicalHousehold root
  published <- TIO.readFile accountPath
  pure $ case (result, loaded) of
    (Right (), Right _) ->
      published == candidate
        && "account Assets:Cash" `T.isInfixOf` published
    _ -> False

testAccountWholeHouseholdRollback :: IO Bool
testAccountWholeHouseholdRollback = withSyntheticHousehold $ \dir root -> do
  candidate <- accountCandidate
  let accountPath = dir </> "accounts.journal"
      reportPath = dir </> "report.toml"
  -- The Account candidate itself remains valid. Another canonical source is
  -- made invalid after preview so Account-only admission would be insufficient.
  TIO.writeFile reportPath "[reports.trial-balance\n"
  result <- publishWithPathAdmission
    (\_ -> loadCanonicalHousehold root)
    WriteIntent
      { targetFilePath = accountPath
      , expectedOldBytes = ExpectedSource syntheticAccounts
      , candidateNewBytes = CandidateSource candidate
      }
  restored <- TIO.readFile accountPath
  pure $ case result of
    Left (PostAdmissionFailed _ True) -> restored == syntheticAccounts
    _ -> False

accountCandidate :: IO Text
accountCandidate = do
  account <- either (fail . show) pure (mkAccount "Assets:Cash")
  commodity <- either (fail . show) pure (mkCommodity "JPY")
  let declaration = declareAccountWithDefaultCommodity account Asset commodity
  preview <- either (fail . show) pure
    (prepareAccountJournalAppend syntheticAccounts declaration)
  pure (accountCandidateCompleteSource preview)

withSyntheticHousehold
  :: (FilePath -> HouseholdRoot -> IO Bool)
  -> IO Bool
withSyntheticHousehold action = do
  let dir = "/tmp/h-kernel-account-publication-spec"
  resetDirectory dir
  writeSyntheticFiles dir
  root <- either (fail . show) pure (mkHouseholdRoot dir)
  result <- action dir root
  removeDirectoryRecursive dir
  pure result

resetDirectory :: FilePath -> IO ()
resetDirectory dir = do
  exists <- doesDirectoryExist dir
  if exists then removeDirectoryRecursive dir else pure ()
  createDirectoryIfMissing True dir

writeSyntheticFiles :: FilePath -> IO ()
writeSyntheticFiles dir = do
  TIO.writeFile (dir </> "accounts.journal") syntheticAccounts
  TIO.writeFile (dir </> "actual.journal") syntheticActual
  TIO.writeFile (dir </> "plan.journal") syntheticPlan
  TIO.writeFile (dir </> "budget.journal") syntheticBudget
  TIO.writeFile (dir </> "budget.toml") syntheticBudgetToml
  TIO.writeFile (dir </> "household.toml") syntheticHouseholdToml
  TIO.writeFile (dir </> "report.toml") syntheticReportToml
  TIO.writeFile (dir </> "issues.tsv") syntheticIssues

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
  , ""
  , "account Budget:Living"
  , "  type: Budget"
  , "  commodity: JPY"
  , ""
  , "account Budget:Daily"
  , "  type: Budget"
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

syntheticBudget :: Text
syntheticBudget = T.unlines
  [ "include accounts.journal"
  , ""
  , "2026-07-01 * Allocate Daily"
  , "  Budget:Daily  100000 JPY"
  , "  Budget:Living"
  ]

syntheticBudgetToml :: Text
syntheticBudgetToml = T.unlines
  [ "[[backing-pools]]"
  , "id = \"main\""
  , "asset-accounts = [\"Assets:Bank\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"Daily\""
  , "label = \"Daily\""
  , "pacing = \"daily\""
  , "backing-pool = \"main\""
  , "expense-accounts = [\"Expenses:Groceries\"]"
  ]

syntheticHouseholdToml :: Text
syntheticHouseholdToml = T.unlines
  [ "[cycle]"
  , "mode = \"income-anchor\""
  , "income-account = \"Income:Salary\""
  , ""
  , "[budget]"
  , "unassigned-accounts = [\"Budget:Living\"]"
  , ""
  , "[[budget.envelopes]]"
  , "id = \"Daily\""
  , "allocation-account = \"Budget:Daily\""
  , ""
  , "[daily-target]"
  , ""
  , "[[daily-target.assets]]"
  , "id = \"bank\""
  , "account = \"Assets:Bank\""
  , ""
  , "[account-policy.assets]"
  , "liquid = [\"Assets:Bank\"]"
  , "savings = []"
  , "investment = []"
  , ""
  , "[account-policy.budget.kind]"
  , "opening = []"
  , "unassigned = [\"Budget:Living\"]"
  , "spent = []"
  , "envelope = [\"Budget:Daily\"]"
  , ""
  , "[account-policy.budget.envelope-role]"
  , "unassigned = [\"Budget:Living\"]"
  , "dynamic = [\"Budget:Daily\"]"
  , "execution = []"
  , ""
  , "[account-policy.budget.group]"
  , "daily = [\"Budget:Daily\"]"
  , "flex = []"
  , "reserve = [\"Budget:Living\"]"
  , ""
  , "[account-policy.expenses]"
  , "fixed = []"
  , "variable = [\"Expenses:Groceries\"]"
  , ""
  , "[envelope-history]"
  , "identities = [\"Daily\"]"
  , ""
  , "[[envelope-history.expense-routing]]"
  , "effective-from = \"initial\""
  , "expense-account = \"Expenses:Groceries\""
  , "route = \"managed\""
  , "target = \"Daily\""
  , "note = \"synthetic account publication initial routing\""
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
