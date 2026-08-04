{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (when)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day, fromGregorian)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import HKernel.Account (AccountType(..), mkAccount, declareAccount, declareAccountWithDefaultCommodity, AccountDeclaration, accountName)
import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Editor.ActualAppend (ActualEditIntent(..), IntentPosting(..), prepareActualAppend, candidateBlock, candidateCompleteSource)
import HKernel.Editor.ActualReverse
import HKernel.Editor.ActualAccountAppend
import HKernel.Editor.BudgetMovementAppend
import HKernel.Editor.IssueAppend
import HKernel.Editor.PlanLifecycle
import HKernel.Editor.ActualWriter
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.BudgetMovement.TSV (parseHouseholdBudgetMovements)
import HKernel.Household.Issue.TSV (parseHouseholdIssues)
import HKernel.HouseholdIssue (IssueStatus(..), mkIssueId)
import HKernel.Money (mkCommodity, parseQuantity)
import HKernel.Money (mkAmount)
import HKernel.Plan.Completion (mkActualTransactionId)
import HKernel.Plan.Journal (parsePlanJournal)

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
  | PlanAddCmd FilePath FilePath PlanAddIntent
  | PlanFinishCmd FilePath FilePath PlanFinishIntent

parseDate :: String -> IO Day
parseDate dateStr = case parseTimeM True defaultTimeLocale "%Y-%m-%d" dateStr of
  Just d -> pure d
  Nothing -> die "Invalid date format. Expected YYYY-MM-DD."

parseCommand :: [String] -> IO EditorCommand
parseCommand ("append":journalFile:dateStr:desc:postingArgs) = do
  date <- parseDate dateStr
  postingList <- parsePostings postingArgs
  when (null postingList) (die "At least one posting is required.")
  pure (AppendCmd journalFile (ActualEditIntent date (T.pack desc) (NonEmpty.fromList postingList) []))
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
parseCommand ("plan":"add":planFile:actualFile:args) = do
  let dummyPosting = IntentPosting (either (error "") id (mkAccount "dummy:dummy")) (either (error "") id (parseQuantity "0")) Nothing
  let emptyIntent = PlanAddIntent (fromGregorian 2000 1 1) "" (dummyPosting NonEmpty.:| []) Nothing Nothing
  intent <- parsePlanAddArgs args emptyIntent
  when (isDummyPosting (NonEmpty.head (addPostings intent))) (die "At least one posting is required for plan add.")
  when (T.null (addDescription intent)) (die "--description is required for plan add.")
  pure (PlanAddCmd planFile actualFile intent)
parseCommand ("plan":"finish":planFile:actualFile:args) = do
  let emptyIntent = PlanFinishIntent "" (fromGregorian 2000 1 1) Nothing
  intent <- parsePlanFinishArgs args emptyIntent
  when (T.null (finishPlanId intent)) (die "--id is required for plan finish.")
  pure (PlanFinishCmd planFile actualFile intent)
parseCommand _ = die "Usage:\n  h-kernel-editor-cli append <journal.txt> <YYYY-MM-DD> <desc> [<acct> <qty> <comm> ...] [--commit]\n  h-kernel-editor-cli reverse <journal.txt> <event-id> <YYYY-MM-DD> <desc...> [--commit]\n  h-kernel-editor-cli account <journal.txt> <account> <type> [<commodity>] [--commit]\n  h-kernel-editor-cli budget <budget_alloc.tsv> <YYYY-MM-DD> <memo> <from> <to> <qty> <comm> [--commit]\n  h-kernel-editor-cli issue <issues.tsv> <id> <status> <YYYY-MM-DD> <category> <title> <qty|-> <comm|-> <details...> [--commit]\n  h-kernel-editor-cli plan add <plan.journal> <actual.journal> --date YYYY-MM-DD --description DESC --posting ACCT QTY COMM ... [--id ID] [--series SERIES] [--commit]\n  h-kernel-editor-cli plan finish <plan.journal> <actual.journal> --id ID --actual-date YYYY-MM-DD [--actual-amount QTY] [--commit]"

isDummyPosting :: IntentPosting -> Bool
isDummyPosting p = accountName (intentAccount p) == "dummy:dummy"

parsePlanAddArgs :: [String] -> PlanAddIntent -> IO PlanAddIntent
parsePlanAddArgs [] intent = pure intent
parsePlanAddArgs ("--date":d:rest) intent = do
  date <- parseDate d
  parsePlanAddArgs rest intent { addDate = date }
parsePlanAddArgs ("--description":desc:rest) intent =
  parsePlanAddArgs rest intent { addDescription = T.pack desc }
parsePlanAddArgs ("--posting":acct:qty:comm:rest) intent = do
  a <- either (die . show) pure (mkAccount (T.pack acct))
  q <- either (die . show) pure (parseQuantity (T.pack qty))
  c <- either (die . show) pure (mkCommodity (T.pack comm))
  let p = IntentPosting a q (Just c)
  let ps = case addPostings intent of
             p0 NonEmpty.:| [] | isDummyPosting p0 -> p NonEmpty.:| []
             ps' -> NonEmpty.fromList (NonEmpty.toList ps' ++ [p])
  parsePlanAddArgs rest intent { addPostings = ps }
parsePlanAddArgs ("--series":s:rest) intent =
  parsePlanAddArgs rest intent { addSeries = Just (T.pack s) }
parsePlanAddArgs ("--id":i:rest) intent =
  parsePlanAddArgs rest intent { addRequestedId = Just (T.pack i) }
parsePlanAddArgs ("--commit":rest) intent = parsePlanAddArgs rest intent
parsePlanAddArgs (flag:_) _ = die $ "Unknown plan add flag: " <> flag

parsePlanFinishArgs :: [String] -> PlanFinishIntent -> IO PlanFinishIntent
parsePlanFinishArgs [] intent = pure intent
parsePlanFinishArgs ("--id":i:rest) intent =
  parsePlanFinishArgs rest intent { finishPlanId = T.pack i }
parsePlanFinishArgs ("--actual-date":d:rest) intent = do
  date <- parseDate d
  parsePlanFinishArgs rest intent { finishActualDate = date }
parsePlanFinishArgs ("--actual-amount":qty:rest) intent = do
  q <- either (die . show) pure (parseQuantity (T.pack qty))
  parsePlanFinishArgs rest intent { finishActualAmount = Just q }
parsePlanFinishArgs ("--commit":rest) intent = parsePlanFinishArgs rest intent
parsePlanFinishArgs (flag:_) _ = die $ "Unknown plan finish flag: " <> flag

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
          executePreview parseActualJournal journalFile existingSource
            (HKernel.Editor.ActualAppend.candidateBlock preview)
            (HKernel.Editor.ActualAppend.candidateCompleteSource preview)
            commitFlag

    ReverseCmd journalFile intent -> do
      existingSource <- TIO.readFile journalFile
      case prepareActualReverse existingSource intent of
        Left errs -> die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview ->
          executePreview parseActualJournal journalFile existingSource
            (HKernel.Editor.ActualReverse.candidateBlock preview)
            (HKernel.Editor.ActualReverse.candidateCompleteSource preview)
            commitFlag

    AccountCmd journalFile decl -> do
      existingSource <- TIO.readFile journalFile
      case prepareActualAccountAppend existingSource decl of
        Left errs -> die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview ->
          executePreview parseActualJournal journalFile existingSource
            (HKernel.Editor.ActualAccountAppend.candidateBlock preview)
            (HKernel.Editor.ActualAccountAppend.candidateCompleteSource preview)
            commitFlag

    BudgetMovementCmd tsvFile movement -> do
      existingSource <- TIO.readFile tsvFile
      case prepareBudgetMovementAppend existingSource movement of
        Left errs -> die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview ->
          executePreview parseHouseholdBudgetMovements tsvFile existingSource
            (HKernel.Editor.BudgetMovementAppend.candidateBlock preview)
            (HKernel.Editor.BudgetMovementAppend.candidateCompleteSource preview)
            commitFlag

    IssueCmd tsvFile intent -> do
      existingSource <- TIO.readFile tsvFile
      case prepareIssueAppend existingSource intent of
        Left errs -> die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview ->
          executePreview parseHouseholdIssues tsvFile existingSource
            (HKernel.Editor.IssueAppend.candidateBlock preview)
            (HKernel.Editor.IssueAppend.candidateCompleteSource preview)
            commitFlag

    PlanAddCmd planFile actualFile intent -> do
      planSource <- TIO.readFile planFile
      actualSource <- TIO.readFile actualFile
      case preparePlanAdd planSource actualSource intent of
        Left errs -> die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview ->
          executePreview parsePlanJournal planFile planSource
            (HKernel.Editor.PlanLifecycle.addCandidateBlock preview)
            (HKernel.Editor.PlanLifecycle.addCandidateCompleteSource preview)
            commitFlag

    PlanFinishCmd planFile actualFile intent -> do
      planSource <- TIO.readFile planFile
      actualSource <- TIO.readFile actualFile
      case preparePlanFinish planSource actualSource intent of
        Left errs -> die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview ->
          executePreview parseActualJournal actualFile actualSource
            (HKernel.Editor.PlanLifecycle.finishCandidateBlock preview)
            (HKernel.Editor.PlanLifecycle.finishCandidateCompleteSource preview)
            commitFlag

executePreview
  :: Show sourceError
  => (Text -> Either (NonEmpty.NonEmpty sourceError) admitted)
  -> FilePath
  -> Text
  -> Text
  -> Text
  -> Bool
  -> IO ()
executePreview admit sourceFile existingSource block completeSource commitFlag = do
  TIO.putStrLn "--- Preview ---"
  TIO.putStr block
  TIO.putStrLn "---------------"

  if commitFlag
    then do
      let writeIntent = WriteIntent
            { targetFilePath = sourceFile
            , expectedOldBytes = existingSource
            , candidateNewBytes = completeSource
            }
      writeResult <- publishWithAdmission admit writeIntent
      case writeResult of
        Right () -> TIO.putStrLn "Successfully updated source."
        Left err -> die $ "Write failed: " <> show err
    else
      TIO.putStrLn "Run with --commit to apply changes."
