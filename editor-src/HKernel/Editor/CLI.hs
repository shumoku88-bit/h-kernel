{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.CLI
  ( CommitMode(..)
  , EditorCommand(..)
  , CliError(..)
  , parseEditorCommand
  , renderCliError
  , usageText
  ) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)

import HKernel.Account
  ( Account
  , AccountDeclaration
  , AccountType(..)
  , declareAccount
  , declareAccountWithDefaultCommodity
  , mkAccount
  )
import HKernel.Editor.ActualAppend (ActualEditIntent(..))
import HKernel.Editor.ActualIdentity
  ( actualEventIdentityMetadata
  , admitActualEventIdentityText
  )
import HKernel.Editor.ActualReverse (ActualReverseIntent(..))
import HKernel.Editor.IssueAppend (IssueAppendIntent(..))
import HKernel.Editor.PlanLifecycle
  ( PlanAddIntent(..)
  , PlanFinishIntent(..)
  , PositivePlanFinishAmount
  , mkPositivePlanFinishAmount
  )
import HKernel.Editor.TransactionBlock (IntentPosting(..))
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.HouseholdIssue (IssueStatus(..), mkIssueId)
import HKernel.Money
  ( Amount
  , Commodity
  , Quantity
  , mkAmount
  , mkCommodity
  , parseQuantity
  )
import HKernel.Plan.Completion (ActualTransactionId, mkActualTransactionId)

data CommitMode
  = PreviewOnly
  | CommitRequested
  deriving (Eq, Show)

data EditorCommand
  = AppendCmd FilePath ActualEditIntent
  | ReverseCmd FilePath ActualReverseIntent
  | AccountCmd FilePath AccountDeclaration
  | BudgetMovementCmd FilePath HouseholdBudgetMovement
  | IssueCmd FilePath IssueAppendIntent
  | PlanAddCmd FilePath FilePath PlanAddIntent
  | PlanFinishCmd FilePath FilePath PlanFinishIntent
  deriving (Eq, Show)

data CliError
  = CliUsage
  | CliInvalidDate
  | CliInvalidAccount
  | CliInvalidQuantity
  | CliInvalidCommodity
  | CliInvalidActualTransactionId
  | CliInvalidIssueId
  | CliInvalidIssueStatus
  | CliInvalidAccountType
  | CliPostingTripletsRequired
  | CliPostingRequired
  | CliInvalidAccountArguments
  | CliInvalidBudgetArguments
  | CliInvalidIssueArguments
  | CliIssueAmountPairRequired
  | CliPlanAddDateRequired
  | CliPlanAddDescriptionRequired
  | CliPlanAddPostingRequired
  | CliPlanAddOptionInvalid
  | CliPlanFinishIdRequired
  | CliPlanFinishEventIdRequired
  | CliPlanFinishDateRequired
  | CliPlanFinishAmountMustBePositive
  | CliPlanFinishOptionInvalid
  deriving (Eq, Show)

parseEditorCommand :: [String] -> Either CliError (CommitMode, EditorCommand)
parseEditorCommand ("append":args) = parseLeaf parseAppend args
parseEditorCommand ("reverse":args) = parseLeaf parseReverse args
parseEditorCommand ("account":args) = parseLeaf parseAccount args
parseEditorCommand ("budget":args) = parseLeaf parseBudget args
parseEditorCommand ("issue":args) = parseLeaf parseIssue args
parseEditorCommand ("plan":"add":args) = parseLeaf parsePlanAdd args
parseEditorCommand ("plan":"finish":args) = parseLeaf parsePlanFinish args
parseEditorCommand _ = Left CliUsage

parseLeaf
  :: ([String] -> Either CliError EditorCommand)
  -> [String]
  -> Either CliError (CommitMode, EditorCommand)
parseLeaf parser args = do
  let (commitMode, commandArgs) = admitCommit args
  command <- parser commandArgs
  pure (commitMode, command)

-- | The mutation flag belongs to one leaf command and is admitted only in the
-- first position after that leaf. Later occurrences remain ordinary user data.
admitCommit :: [String] -> (CommitMode, [String])
admitCommit ("--commit":rest) = (CommitRequested, rest)
admitCommit rest = (PreviewOnly, rest)

parseAppend :: [String] -> Either CliError EditorCommand
parseAppend (journalFile:eventIdText:dateText:description:postingArgs) = do
  eventId <- mapDomainError CliInvalidActualTransactionId
    (admitActualEventIdentityText (T.pack eventIdText))
  date <- parseDate dateText
  postings <- parsePostings postingArgs
  nonEmptyPostings <- maybe (Left CliPostingRequired) Right
    (NonEmpty.nonEmpty postings)
  pure
    (AppendCmd journalFile
      (ActualEditIntent
        date
        (T.pack description)
        nonEmptyPostings
        [actualEventIdentityMetadata eventId]))
parseAppend _ = Left CliUsage

parseReverse :: [String] -> Either CliError EditorCommand
parseReverse
  (journalFile:reversalIdText:targetIdText:dateText:descriptionWords) = do
  reversalId <- mapDomainError CliInvalidActualTransactionId
    (mkActualTransactionId (T.pack reversalIdText))
  targetId <- mapDomainError CliInvalidActualTransactionId
    (mkActualTransactionId (T.pack targetIdText))
  date <- parseDate dateText
  pure
    (ReverseCmd journalFile
      (ActualReverseIntent
        reversalId
        targetId
        date
        (T.pack (unwords descriptionWords))))
parseReverse _ = Left CliUsage

parseAccount :: [String] -> Either CliError EditorCommand
parseAccount (journalFile:accountText:typeText:rest) = do
  account <- parseAccountValue accountText
  accountType <- parseAccountType typeText
  declaration <- case rest of
    [] -> Right (declareAccount account accountType)
    [commodityText] -> do
      commodity <- parseCommodity commodityText
      Right (declareAccountWithDefaultCommodity account accountType commodity)
    _ -> Left CliInvalidAccountArguments
  pure (AccountCmd journalFile declaration)
parseAccount _ = Left CliInvalidAccountArguments

parseBudget :: [String] -> Either CliError EditorCommand
parseBudget [tsvFile, dateText, memo, fromText, toText, quantityText, commodityText] = do
  date <- parseDate dateText
  fromAccount <- parseAccountValue fromText
  toAccount <- parseAccountValue toText
  quantity <- parseQuantityValue quantityText
  commodity <- parseCommodity commodityText
  pure
    (BudgetMovementCmd tsvFile
      (HouseholdBudgetMovement
        date
        (T.pack memo)
        fromAccount
        toAccount
        (mkAmount commodity quantity)))
parseBudget _ = Left CliInvalidBudgetArguments

parseIssue :: [String] -> Either CliError EditorCommand
parseIssue (tsvFile:idText:statusText:dateText:category:title:quantityText:commodityText:detailsWords) = do
  issueId <- mapDomainError CliInvalidIssueId (mkIssueId (T.pack idText))
  status <- parseIssueStatus statusText
  date <- parseDate dateText
  amount <- parseIssueAmount quantityText commodityText
  pure
    (IssueCmd tsvFile
      (IssueAppendIntent
        issueId
        status
        date
        (T.pack category)
        (T.pack title)
        amount
        (T.pack (unwords detailsWords))))
parseIssue _ = Left CliInvalidIssueArguments

parseIssueAmount :: String -> String -> Either CliError (Maybe Amount)
parseIssueAmount "-" "-" = Right Nothing
parseIssueAmount "-" _ = Left CliIssueAmountPairRequired
parseIssueAmount _ "-" = Left CliIssueAmountPairRequired
parseIssueAmount quantityText commodityText = do
  quantity <- parseQuantityValue quantityText
  commodity <- parseCommodity commodityText
  pure (Just (mkAmount commodity quantity))

data PlanAddFields = PlanAddFields
  { planAddDateField        :: Maybe Day
  , planAddDescriptionField :: Maybe Text
  , planAddPostingsReversed :: [IntentPosting]
  , planAddRequestedIdField :: Maybe Text
  , planAddSeriesField      :: Maybe Text
  }

emptyPlanAddFields :: PlanAddFields
emptyPlanAddFields = PlanAddFields Nothing Nothing [] Nothing Nothing

parsePlanAdd :: [String] -> Either CliError EditorCommand
parsePlanAdd (planFile:actualFile:optionArgs) = do
  fields <- parsePlanAddOptions emptyPlanAddFields optionArgs
  date <- maybe (Left CliPlanAddDateRequired) Right (planAddDateField fields)
  description <- case planAddDescriptionField fields of
    Just value | not (T.null value) -> Right value
    _ -> Left CliPlanAddDescriptionRequired
  postings <- maybe (Left CliPlanAddPostingRequired) Right
    (NonEmpty.nonEmpty (reverse (planAddPostingsReversed fields)))
  pure
    (PlanAddCmd planFile actualFile
      (PlanAddIntent
        date
        description
        postings
        (planAddRequestedIdField fields)
        (planAddSeriesField fields)))
parsePlanAdd _ = Left CliUsage

parsePlanAddOptions
  :: PlanAddFields
  -> [String]
  -> Either CliError PlanAddFields
parsePlanAddOptions fields [] = Right fields
parsePlanAddOptions fields ("--date":dateText:rest) = do
  date <- parseDate dateText
  parsePlanAddOptions fields { planAddDateField = Just date } rest
parsePlanAddOptions fields ("--description":description:rest) =
  parsePlanAddOptions fields
    { planAddDescriptionField = Just (T.pack description) }
    rest
parsePlanAddOptions fields ("--posting":accountText:quantityText:commodityText:rest) = do
  account <- parseAccountValue accountText
  quantity <- parseQuantityValue quantityText
  commodity <- parseCommodity commodityText
  let posting = IntentPosting account quantity (Just commodity)
  parsePlanAddOptions fields
    { planAddPostingsReversed = posting : planAddPostingsReversed fields }
    rest
parsePlanAddOptions fields ("--id":requestedId:rest) =
  parsePlanAddOptions fields
    { planAddRequestedIdField = Just (T.pack requestedId) }
    rest
parsePlanAddOptions fields ("--series":series:rest) =
  parsePlanAddOptions fields
    { planAddSeriesField = Just (T.pack series) }
    rest
parsePlanAddOptions _ _ = Left CliPlanAddOptionInvalid

data PlanFinishFields = PlanFinishFields
  { planFinishIdField      :: Maybe Text
  , planFinishEventIdField :: Maybe ActualTransactionId
  , planFinishDateField    :: Maybe Day
  , planFinishAmountField  :: Maybe PositivePlanFinishAmount
  }

emptyPlanFinishFields :: PlanFinishFields
emptyPlanFinishFields = PlanFinishFields Nothing Nothing Nothing Nothing

parsePlanFinish :: [String] -> Either CliError EditorCommand
parsePlanFinish (planFile:actualFile:optionArgs) = do
  fields <- parsePlanFinishOptions emptyPlanFinishFields optionArgs
  planId <- case planFinishIdField fields of
    Just value | not (T.null value) -> Right value
    _ -> Left CliPlanFinishIdRequired
  eventId <- maybe (Left CliPlanFinishEventIdRequired) Right
    (planFinishEventIdField fields)
  actualDate <- maybe (Left CliPlanFinishDateRequired) Right
    (planFinishDateField fields)
  pure
    (PlanFinishCmd planFile actualFile
      (PlanFinishIntent planId eventId actualDate (planFinishAmountField fields)))
parsePlanFinish _ = Left CliUsage

parsePlanFinishOptions
  :: PlanFinishFields
  -> [String]
  -> Either CliError PlanFinishFields
parsePlanFinishOptions fields [] = Right fields
parsePlanFinishOptions fields ("--id":planId:rest) =
  parsePlanFinishOptions fields
    { planFinishIdField = Just (T.pack planId) }
    rest
parsePlanFinishOptions fields ("--event-id":eventIdText:rest) = do
  eventId <- mapDomainError CliInvalidActualTransactionId
    (admitActualEventIdentityText (T.pack eventIdText))
  parsePlanFinishOptions fields
    { planFinishEventIdField = Just eventId }
    rest
parsePlanFinishOptions fields ("--actual-date":dateText:rest) = do
  date <- parseDate dateText
  parsePlanFinishOptions fields
    { planFinishDateField = Just date }
    rest
parsePlanFinishOptions fields ("--actual-amount":quantityText:rest) = do
  quantity <- parseQuantityValue quantityText
  positiveAmount <- mapDomainError CliPlanFinishAmountMustBePositive
    (mkPositivePlanFinishAmount quantity)
  parsePlanFinishOptions fields
    { planFinishAmountField = Just positiveAmount }
    rest
parsePlanFinishOptions _ _ = Left CliPlanFinishOptionInvalid

parsePostings :: [String] -> Either CliError [IntentPosting]
parsePostings [] = Right []
parsePostings (accountText:quantityText:commodityText:rest) = do
  account <- parseAccountValue accountText
  quantity <- parseQuantityValue quantityText
  commodity <- if commodityText == "-"
    then Right Nothing
    else Just <$> parseCommodity commodityText
  remaining <- parsePostings rest
  pure (IntentPosting account quantity commodity : remaining)
parsePostings _ = Left CliPostingTripletsRequired

parseDate :: String -> Either CliError Day
parseDate value = case parseTimeM True defaultTimeLocale "%Y-%m-%d" value of
  Just day -> Right day
  Nothing -> Left CliInvalidDate

parseAccountValue :: String -> Either CliError Account
parseAccountValue value =
  mapDomainError CliInvalidAccount (mkAccount (T.pack value))

parseQuantityValue :: String -> Either CliError Quantity
parseQuantityValue value =
  mapDomainError CliInvalidQuantity (parseQuantity (T.pack value))

parseCommodity :: String -> Either CliError Commodity
parseCommodity value =
  mapDomainError CliInvalidCommodity (mkCommodity (T.pack value))

parseIssueStatus :: String -> Either CliError IssueStatus
parseIssueStatus "open" = Right Open
parseIssueStatus "resolved" = Right Resolved
parseIssueStatus _ = Left CliInvalidIssueStatus

parseAccountType :: String -> Either CliError AccountType
parseAccountType value = case T.toCaseFold (T.pack value) of
  "asset" -> Right Asset
  "liability" -> Right Liability
  "equity" -> Right Equity
  "income" -> Right Income
  "expense" -> Right Expense
  "budget" -> Right Budget
  _ -> Left CliInvalidAccountType

mapDomainError :: CliError -> Either domainError value -> Either CliError value
mapDomainError cliError result = case result of
  Left _ -> Left cliError
  Right value -> Right value

renderCliError :: CliError -> String
renderCliError errorValue = case errorValue of
  CliUsage -> "command does not match the Editor CLI grammar"
  CliInvalidDate -> "invalid date; expected YYYY-MM-DD"
  CliInvalidAccount -> "invalid Account"
  CliInvalidQuantity -> "invalid Quantity"
  CliInvalidCommodity -> "invalid Commodity"
  CliInvalidActualTransactionId -> "invalid Actual transaction identity"
  CliInvalidIssueId -> "invalid Issue identity"
  CliInvalidIssueStatus -> "invalid Issue status; expected open or resolved"
  CliInvalidAccountType -> "invalid Account type"
  CliPostingTripletsRequired -> "postings must be account/quantity/commodity triplets"
  CliPostingRequired -> "at least one posting is required"
  CliInvalidAccountArguments -> "invalid Account command arguments"
  CliInvalidBudgetArguments -> "invalid Budget command arguments"
  CliInvalidIssueArguments -> "invalid Issue command arguments"
  CliIssueAmountPairRequired -> "Issue amount requires both quantity and commodity, or '-' for both"
  CliPlanAddDateRequired -> "--date is required for plan add"
  CliPlanAddDescriptionRequired -> "--description is required for plan add"
  CliPlanAddPostingRequired -> "at least one --posting is required for plan add"
  CliPlanAddOptionInvalid -> "invalid or incomplete plan add option"
  CliPlanFinishIdRequired -> "--id is required for plan finish"
  CliPlanFinishEventIdRequired -> "--event-id is required for plan finish"
  CliPlanFinishDateRequired -> "--actual-date is required for plan finish"
  CliPlanFinishAmountMustBePositive -> "--actual-amount must be a positive magnitude"
  CliPlanFinishOptionInvalid -> "invalid or incomplete plan finish option"

usageText :: String
usageText = unlines
  [ "Usage:"
  , "  h-kernel-editor-cli append [--commit] <journal.txt> <evt-uuid-v4> <YYYY-MM-DD> <desc> [<acct> <qty> <comm> ...]"
  , "  h-kernel-editor-cli reverse [--commit] <journal.txt> <new-event-id> <target-event-id> <YYYY-MM-DD> <desc...>"
  , "  h-kernel-editor-cli account [--commit] <journal.txt> <account> <type> [<commodity>]"
  , "  h-kernel-editor-cli budget [--commit] <budget_alloc.tsv> <YYYY-MM-DD> <memo> <from> <to> <qty> <comm>"
  , "  h-kernel-editor-cli issue [--commit] <issues.tsv> <id> <status> <YYYY-MM-DD> <category> <title> <qty|-> <comm|-> <details...>"
  , "  h-kernel-editor-cli plan add [--commit] <plan.journal> <actual.journal> --date YYYY-MM-DD --description DESC --posting ACCT QTY COMM ... [--id ID] [--series SERIES]"
  , "  h-kernel-editor-cli plan finish [--commit] <plan.journal> <actual.journal> --id ID --event-id EVT-UUID-V4 --actual-date YYYY-MM-DD [--actual-amount POSITIVE_QTY]"
  ]

