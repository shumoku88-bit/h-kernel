{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import System.FilePath ((</>))
import System.Exit (exitFailure)

import HKernel.Account
  ( AccountType(..)
  , declareAccountWithDefaultCommodity
  , mkAccount
  )
import HKernel.Account.Journal (parseAccountJournal)
import HKernel.Application.Config (mkHouseholdRoot)
import HKernel.Editor.ActualAccountAppend (prepareAccountJournalAppend, accountCandidateBlock)
import HKernel.Editor.BudgetMovementAppend (prepareBudgetJournalMovementAppend, budgetJournalCandidateBlock)
import HKernel.Household.Application
  ( HouseholdLoadError(..)
  , admitCanonicalHousehold
  , buildHouseholdReportSurfaceFromHousehold
  , loadCanonicalHousehold
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Money (mkAmount, mkCommodity, quantityFromInteger)

main :: IO ()
main = do
  putStrLn "Running CanonicalHouseholdSpec..."
  testSyntheticRootLoading
  testRegistryDisagreementFailure
  testInMemoryAdmission
  testNativeAccountAppend
  testNativeBudgetMovementAppend
  putStrLn "CanonicalHouseholdSpec PASSED."

testSyntheticRootLoading :: IO ()
testSyntheticRootLoading = do
  let dir = "/tmp/synthetic_household_spec"
  createDirectoryIfMissing True dir
  writeSyntheticFiles dir syntheticAccounts syntheticActual syntheticPlan syntheticBudget syntheticBudgetToml syntheticHouseholdToml syntheticReportToml syntheticIssues
  
  root <- case mkHouseholdRoot dir of
    Left err -> die ("mkHouseholdRoot failed: " <> show err)
    Right r -> pure r
    
  loadResult <- loadCanonicalHousehold root
  state <- case loadResult of
    Left errs -> die ("loadCanonicalHousehold failed:\n" <> unlines (map show (NonEmpty.toList errs)))
    Right s -> pure s
    
  let observation = fromGregorian 2026 7 20
  case buildHouseholdReportSurfaceFromHousehold observation state of
    Left errs -> die ("buildHouseholdReportSurfaceFromHousehold failed:\n" <> unlines (map show (NonEmpty.toList errs)))
    Right _ -> pure ()
    
  removeDirectoryRecursive dir

testRegistryDisagreementFailure :: IO ()
testRegistryDisagreementFailure = do
  let dir = "/tmp/synthetic_household_disagree_spec"
  createDirectoryIfMissing True dir
  let accountsText = syntheticAccounts <> "\naccount Assets:Crypto\n  type: Asset\n  commodity: BTC\n"
      actualAccountsText = syntheticAccounts <> "\naccount Assets:Crypto\n  type: Asset\n  commodity: ETH\n"
      actualText = "include actual_accounts.journal\n\n2026-06-01 * Income anchor\n  Income:Salary  -300000 JPY\n  Assets:Bank\n"
  TIO.writeFile (dir </> "actual_accounts.journal") actualAccountsText
  writeSyntheticFiles dir accountsText actualText syntheticPlan syntheticBudget syntheticBudgetToml syntheticHouseholdToml syntheticReportToml syntheticIssues
  
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
  let root = case mkHouseholdRoot "." of
        Right r -> r
        Left _ -> error "unreachable"
  case admitCanonicalHousehold root syntheticAccounts syntheticActual syntheticPlan syntheticBudget syntheticBudgetToml syntheticHouseholdToml syntheticReportToml syntheticIssues of
    Left errs -> die ("admitCanonicalHousehold failed:\n" <> unlines (map show (NonEmpty.toList errs)))
    Right state -> do
      let observation = fromGregorian 2026 7 20
      case buildHouseholdReportSurfaceFromHousehold observation state of
        Left errs -> die ("buildHouseholdReportSurfaceFromHousehold in memory failed:\n" <> unlines (map show (NonEmpty.toList errs)))
        Right _ -> pure ()

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

testNativeBudgetMovementAppend :: IO ()
testNativeBudgetMovementAppend = do
  registry <- case parseAccountJournal syntheticAccounts of
    Left errs -> die ("parseAccountJournal failed: " <> show errs)
    Right r -> pure r
  fromAcc <- case mkAccount "Budget:Daily" of
    Left err -> die ("mkAccount from failed: " <> show err)
    Right a -> pure a
  toAcc <- case mkAccount "Budget:Daily" of
    Left err -> die ("mkAccount to failed: " <> show err)
    Right a -> pure a
  comm <- case mkCommodity "JPY" of
    Left err -> die ("mkCommodity failed: " <> show err)
    Right c -> pure c
  let movement = HouseholdBudgetMovement
        { householdBudgetMovementDate = fromGregorian 2026 7 1
        , householdBudgetMovementMemo = "Allocate"
        , householdBudgetMovementFrom = fromAcc
        , householdBudgetMovementTo = toAcc
        , householdBudgetMovementAmount = mkAmount comm (quantityFromInteger 10000)
        }
  case prepareBudgetJournalMovementAppend registry syntheticBudget movement of
    Left errs -> die ("prepareBudgetJournalMovementAppend failed: " <> show errs)
    Right preview -> do
      let candidate = budgetJournalCandidateBlock preview
      unless ("Budget:Daily" `T.isInfixOf` candidate)
        (die "Budget candidate block missing account name")

writeSyntheticFiles
  :: FilePath
  -> Text -> Text -> Text -> Text -> Text -> Text -> Text -> Text
  -> IO ()
writeSyntheticFiles dir accounts actual plan budget budgetToml householdToml reportToml issues = do
  TIO.writeFile (dir </> "accounts.journal") accounts
  TIO.writeFile (dir </> "actual.journal") actual
  TIO.writeFile (dir </> "plan.journal") plan
  TIO.writeFile (dir </> "budget.journal") budget
  TIO.writeFile (dir </> "budget.toml") budgetToml
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
