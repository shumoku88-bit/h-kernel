{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (when)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import HKernel.Account (AccountType(..), mkAccount, declareAccount, declareAccountWithDefaultCommodity, AccountDeclaration)
import HKernel.Editor.ActualAppend (ActualEditIntent(..), IntentPosting(..), prepareActualAppend, candidateBlock, candidateCompleteSource)
import HKernel.Editor.ActualReverse
import HKernel.Editor.ActualAccountAppend
import HKernel.Editor.BudgetMovementAppend
import HKernel.Editor.IssueAppend
import HKernel.Editor.ActualWriter
import HKernel.Money (mkCommodity, parseQuantity)
import HKernel.Plan.Completion (mkActualTransactionId)
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.HouseholdIssue (IssueStatus(..), mkIssueId)
import HKernel.Money (mkAmount)

die :: String -> IO a
die msg = hPutStrLn stderr msg >> exitFailure

parsePostings :: [String] -> IO [IntentPosting]
parsePostings [] = pure []
parsePostings (acctStr:qtyStr:commStr:rest) = do
  acct <- either (die . show) pure (mkAccount (T.pack acctStr))
  qty <- either (die . show) pure (parseQuantity (T.pack qtyStr))
  commOpt <- if commStr == "-"
    then pure Nothing
    else either (die . show) (pure . Just) (mkCommodity (T.pack commStr))
  restPostings <- parsePostings rest
  pure (IntentPosting acct qty commOpt : restPostings)
parsePostings _ = die "Invalid number of arguments for postings. Expected triplets of <account> <qty> <comm> (use '-' for default commodity)."

data EditorCommand
  = AppendCmd FilePath ActualEditIntent
  | ReverseCmd FilePath ActualReverseIntent
  | AccountCmd FilePath AccountDeclaration
  | BudgetMovementCmd FilePath HouseholdBudgetMovement
  | IssueCmd FilePath IssueAppendIntent

parseDate :: String -> IO Day
parseDate dateStr = case parseTimeM True defaultTimeLocale "%Y-%m-%d" dateStr of
  Just d -> pure d
  Nothing -> die "Invalid date format. Expected YYYY-MM-DD."

parseCommand :: [String] -> IO EditorCommand
parseCommand ("append":journalFile:dateStr:desc:postingArgs) = do
  date <- parseDate dateStr
  postingList <- parsePostings postingArgs
  when (null postingList) (die "At least one posting is required.")
  pure (AppendCmd journalFile (ActualEditIntent date (T.pack desc) (NonEmpty.fromList postingList)))
parseCommand ("reverse":journalFile:targetIdStr:dateStr:descWords) = do
  date <- parseDate dateStr
  targetId <- either (die . show) pure (mkActualTransactionId (T.pack targetIdStr))
  pure (ReverseCmd journalFile (ActualReverseIntent targetId date (T.pack (unwords descWords))))
parseCommand ("account":journalFile:accountStr:typeStr:rest) = do
  account <- either (die . show) pure (mkAccount (T.pack accountStr))
  accountType <- parseAccountType typeStr
  declaration <- case rest of
    [commStr] -> do
      commodity <- either (die . show) pure (mkCommodity (T.pack commStr))
      pure (declareAccountWithDefaultCommodity account accountType commodity)
    [] -> pure (declareAccount account accountType)
    _ -> die "Invalid arguments for account. Expected: <account> <type> [<commodity>]"
  pure (AccountCmd journalFile declaration)
parseCommand ("budget":tsvFile:dateStr:memoStr:fromStr:toStr:qtyStr:commStr:_) = do
  date <- parseDate dateStr
  fromAcc <- either (die . show) pure (mkAccount (T.pack fromStr))
  toAcc <- either (die . show) pure (mkAccount (T.pack toStr))
  qty <- either (die . show) pure (parseQuantity (T.pack qtyStr))
  comm <- either (die . show) pure (mkCommodity (T.pack commStr))
  let movement = HouseholdBudgetMovement date (T.pack memoStr) fromAcc toAcc (mkAmount comm qty)
  pure (BudgetMovementCmd tsvFile movement)
parseCommand ("issue":tsvFile:idStr:statusStr:dateStr:category:title:qtyStr:commStr:detailsWords) = do
  issueId <- either (die . show) pure (mkIssueId (T.pack idStr))
  status <- parseIssueStatus statusStr
  date <- parseDate dateStr
  amount <- if qtyStr == "-" || commStr == "-"
    then pure Nothing
    else do
      qty <- either (die . show) pure (parseQuantity (T.pack qtyStr))
      comm <- either (die . show) pure (mkCommodity (T.pack commStr))
      pure (Just (mkAmount comm qty))
  let intent = IssueAppendIntent issueId status date (T.pack category) (T.pack title) amount (T.pack (unwords detailsWords))
  pure (IssueCmd tsvFile intent)
parseCommand _ = die "Usage:\n  h-kernel-editor-cli append <journal.txt> <YYYY-MM-DD> <desc> [<acct> <qty> <comm> ...] [--commit]\n  h-kernel-editor-cli reverse <journal.txt> <event-id> <YYYY-MM-DD> <desc...> [--commit]\n  h-kernel-editor-cli account <journal.txt> <account> <type> [<commodity>] [--commit]\n  h-kernel-editor-cli budget <budget_alloc.tsv> <YYYY-MM-DD> <memo> <from> <to> <qty> <comm> [--commit]\n  h-kernel-editor-cli issue <issues.tsv> <id> <status> <YYYY-MM-DD> <category> <title> <qty|-> <comm|-> <details...> [--commit]"

parseIssueStatus :: String -> IO IssueStatus
parseIssueStatus "open" = pure Open
parseIssueStatus "resolved" = pure Resolved
parseIssueStatus _ = die "Invalid status. Expected 'open' or 'resolved'."

parseAccountType :: String -> IO AccountType
parseAccountType typeStr =
  case T.toCaseFold (T.pack typeStr) of
    "asset" -> pure Asset
    "liability" -> pure Liability
    "equity" -> pure Equity
    "income" -> pure Income
    "expense" -> pure Expense
    "budget" -> pure Budget
    _ -> die "Invalid account type. Expected: Asset, Liability, Equity, Income, Expense, or Budget."

main :: IO ()
main = do
  args <- getArgs
  let commitFlag = "--commit" `elem` args
      cleanArgs = filter (/= "--commit") args

  cmd <- parseCommand cleanArgs
  case cmd of
    AppendCmd journalFile intent -> do
      existingSource <- TIO.readFile journalFile
      case prepareActualAppend existingSource intent of
        Left errs -> die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview ->
          executePreview journalFile existingSource
            (HKernel.Editor.ActualAppend.candidateBlock preview)
            (HKernel.Editor.ActualAppend.candidateCompleteSource preview)
            commitFlag

    ReverseCmd journalFile intent -> do
      existingSource <- TIO.readFile journalFile
      case prepareActualReverse existingSource intent of
        Left errs -> die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview ->
          executePreview journalFile existingSource
            (HKernel.Editor.ActualReverse.candidateBlock preview)
            (HKernel.Editor.ActualReverse.candidateCompleteSource preview)
            commitFlag

    AccountCmd journalFile decl -> do
      existingSource <- TIO.readFile journalFile
      case prepareActualAccountAppend existingSource decl of
        Left errs -> die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview ->
          executePreview journalFile existingSource
            (HKernel.Editor.ActualAccountAppend.candidateBlock preview)
            (HKernel.Editor.ActualAccountAppend.candidateCompleteSource preview)
            commitFlag

    BudgetMovementCmd tsvFile movement -> do
      existingSource <- TIO.readFile tsvFile
      case prepareBudgetMovementAppend existingSource movement of
        Left errs -> die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview ->
          executePreview tsvFile existingSource
            (HKernel.Editor.BudgetMovementAppend.candidateBlock preview)
            (HKernel.Editor.BudgetMovementAppend.candidateCompleteSource preview)
            commitFlag

    IssueCmd tsvFile intent -> do
      existingSource <- TIO.readFile tsvFile
      case prepareIssueAppend existingSource intent of
        Left errs -> die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview ->
          executePreview tsvFile existingSource
            (HKernel.Editor.IssueAppend.candidateBlock preview)
            (HKernel.Editor.IssueAppend.candidateCompleteSource preview)
            commitFlag

executePreview :: FilePath -> Text -> Text -> Text -> Bool -> IO ()
executePreview journalFile existingSource block completeSource commitFlag = do
  TIO.putStrLn "--- Preview ---"
  TIO.putStr block
  TIO.putStrLn "---------------"

  if commitFlag
    then do
      let writeIntent = WriteIntent
            { targetFilePath = journalFile
            , expectedOldBytes = existingSource
            , candidateNewBytes = completeSource
            }
      writeRes <- publishActualAppend writeIntent
      case writeRes of
        Right () -> TIO.putStrLn "Successfully updated journal."
        Left err -> die $ "Write failed: " <> show err
    else do
      TIO.putStrLn "Run with --commit to apply changes."
