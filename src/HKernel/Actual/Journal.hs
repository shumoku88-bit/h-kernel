{-# LANGUAGE OverloadedStrings #-}

-- | Explicit Plan-completion projection from an Actual Journal source.
--
-- The canonical Journal parser remains the owner of accounting syntax,
-- declarations, postings, exact amounts, and transaction validation. This
-- module projects the explicit coordinates needed by Plan completion:
-- @event-id@ identifies an externally durable Actual transaction, while
-- @plan-id@ names the Plan completed by the transaction carrying it.
--
-- Transactions without either key remain ordinary Actual facts. A transaction
-- carrying @plan-id@ without @event-id@ receives a rebuildable runtime identity
-- derived from the Plan ID. No generated identity is written back to Journal,
-- and completion never depends on date, description, amount, or posting shape.
module HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalValue
  , actualJournalIdentifiedTransactions
  , actualJournalCompletionDeclarations
  , ActualJournalError(..)
  , parseActualJournal
  ) where

import Data.Char (isSpace)
import Data.List (foldl', sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Journal
  ( Journal
  , JournalError
  , journalTransactions
  , parseJournal
  )
import HKernel.Ledger (Transaction)
import HKernel.Plan
  ( PlanId
  , PlanIdError
  , mkPlanId
  , planIdText
  )
import HKernel.Plan.Completion
  ( ActualTransactionId
  , ActualTransactionIdError
  , IdentifiedActualTransaction
  , PlanCompletionDeclaration
  , declarePlanCompletion
  , identifyActualTransaction
  , identifiedActualId
  , mkActualTransactionId
  )

-- | One validated Journal plus the explicit completion coordinates projected
-- from transaction metadata.
data ActualJournal = ActualJournal
  { actualJournalValue                  :: Journal
  , actualJournalIdentifiedTransactions :: [IdentifiedActualTransaction]
  , actualJournalCompletionDeclarations :: [PlanCompletionDeclaration]
  } deriving (Eq, Show)

-- | Failure to admit accounting syntax or explicit completion metadata.
data ActualJournalError
  = ActualJournalSyntaxError JournalError
  | InvalidActualEventId Int ActualTransactionIdError
  | InvalidActualPlanId Int PlanIdError
  | DuplicateActualMetadataKey Int Text
  | DuplicateActualEventIdDefinition ActualTransactionId (NonEmpty Int)
  | ActualTransactionMetadataAlignmentMismatch Int Int
  deriving (Eq, Show)

-- | Parse the accounting Journal, then project explicit completion coordinates.
--
-- Unrelated metadata is not assigned runtime meaning by this narrow projection.
-- A later complete target-source schema must still preserve or diagnose every
-- metadata field before migration cutover.
parseActualJournal
  :: Text
  -> Either (NonEmpty ActualJournalError) ActualJournal
parseActualJournal input = case parseJournal input of
  Left journalErrors -> Left (fmap ActualJournalSyntaxError journalErrors)
  Right journal
    | transactionCount /= metadataCount -> Left
        (ActualTransactionMetadataAlignmentMismatch
          transactionCount metadataCount NonEmpty.:| [])
    | otherwise -> case NonEmpty.nonEmpty allErrors of
        Just errors -> Left errors
        Nothing -> Right ActualJournal
          { actualJournalValue = journal
          , actualJournalIdentifiedTransactions =
              map locatedIdentifiedValue locatedIdentified
          , actualJournalCompletionDeclarations = declarations
          }
    where
      transactions = journalTransactions journal
      metadataBlocks = transactionMetadataBlocks input
      transactionCount = length transactions
      metadataCount = length metadataBlocks
      admissions = zipWith admitTransactionMetadata transactions metadataBlocks
      locatedIdentified = mapMaybe admissionIdentified admissions
      declarations = mapMaybe admissionDeclaration admissions
      allErrors =
        concatMap admissionErrors admissions
          ++ duplicateActualIdErrors locatedIdentified

type LocatedLine = (Int, Text)

data LocatedMetadata = LocatedMetadata
  { locatedMetadataLine  :: Int
  , locatedMetadataKey   :: Text
  , locatedMetadataValue :: Text
  }

data LocatedIdentifiedActual = LocatedIdentifiedActual
  { locatedIdentifiedLine  :: Int
  , locatedIdentifiedValue :: IdentifiedActualTransaction
  }

data TransactionMetadataAdmission = TransactionMetadataAdmission
  { admissionErrors      :: [ActualJournalError]
  , admissionIdentified  :: Maybe LocatedIdentifiedActual
  , admissionDeclaration :: Maybe PlanCompletionDeclaration
  }

-- | Recover transaction blocks using the same top-level shape as the Journal
-- syntax, then retain only completion-relevant metadata from each transaction.
transactionMetadataBlocks :: Text -> [[LocatedMetadata]]
transactionMetadataBlocks input =
  [ mapMaybe relevantMetadata (drop 1 block)
  | block@((_, header) : _) <- sourceBlocks input
  , not (isNonTransactionDirective header)
  ]

sourceBlocks :: Text -> [[LocatedLine]]
sourceBlocks = map reverse . reverse . foldl' addLine [] . zip [1..] . T.lines
  where
    addLine blocks located@(_, line)
      | startsBlock line = [located] : blocks
      | otherwise = case blocks of
          [] -> []
          block : rest -> (located : block) : rest

startsBlock :: Text -> Bool
startsBlock line =
  not (T.null (T.strip line))
    && not (isIndented line)
    && not (isComment line)

relevantMetadata :: LocatedLine -> Maybe LocatedMetadata
relevantMetadata (lineNumber, line)
  | not (isIndented line && isComment line) = Nothing
  | otherwise = case T.breakOn ":" cleanLine of
      (_, remainder) | T.null remainder -> Nothing
      (_, remainder)
        | key `elem` relevantMetadataKeys -> Just LocatedMetadata
            { locatedMetadataLine = lineNumber
            , locatedMetadataKey = key
            , locatedMetadataValue = T.strip (T.drop 1 remainder)
            }
        | otherwise -> Nothing
  where
    cleanLine = T.strip
      (T.dropWhile (\character -> character == ';' || isSpace character)
        (T.strip line))
    key = T.toCaseFold (T.strip (fst (T.breakOn ":" cleanLine)))

relevantMetadataKeys :: [Text]
relevantMetadataKeys = ["event-id", "plan-id"]

isNonTransactionDirective :: Text -> Bool
isNonTransactionDirective line =
  any (`isDirective` line) ["account", "include", "commodity"]

isDirective :: Text -> Text -> Bool
isDirective keyword line = case T.stripPrefix keyword (T.stripStart line) of
  Nothing -> False
  Just remainder ->
    T.null remainder
      || maybe False (isSpace . fst) (T.uncons remainder)

isComment :: Text -> Bool
isComment = T.isPrefixOf ";" . T.stripStart

isIndented :: Text -> Bool
isIndented line = case T.uncons line of
  Just (character, _) -> isSpace character
  Nothing -> False

admitTransactionMetadata
  :: Transaction
  -> [LocatedMetadata]
  -> TransactionMetadataAdmission
admitTransactionMetadata transaction metadata = TransactionMetadataAdmission
  { admissionErrors =
      eventErrors ++ planErrors ++ derivedEventErrors
  , admissionIdentified = locatedIdentified
  , admissionDeclaration = completionDeclaration
  }
  where
    eventEntries = metadataEntries "event-id" metadata
    planEntries = metadataEntries "plan-id" metadata
    (eventErrors, maybeEvent) = admitMetadataValue
      "event-id" mkActualTransactionId InvalidActualEventId eventEntries
    (planErrors, maybePlan) = admitMetadataValue
      "plan-id" mkPlanId InvalidActualPlanId planEntries

    (derivedEventErrors, maybeDerivedEvent) =
      case (maybeEvent, maybePlan) of
        (Nothing, Just (lineNumber, planId)) ->
          case mkActualTransactionId
            ("plan-completion-" <> planIdText planId) of
            Left err ->
              ([InvalidActualEventId lineNumber err], Nothing)
            Right actualId ->
              ([], Just (lineNumber, actualId))
        _ -> ([], Nothing)

    effectiveEvent = case maybeEvent of
      Just value -> Just value
      Nothing -> maybeDerivedEvent

    locatedIdentified = fmap toIdentified effectiveEvent
    toIdentified (lineNumber, actualId) = LocatedIdentifiedActual
      { locatedIdentifiedLine = lineNumber
      , locatedIdentifiedValue = identifyActualTransaction actualId transaction
      }

    completionDeclaration =
      declarePlanCompletion
        <$> fmap snd maybePlan
        <*> fmap snd effectiveEvent

metadataEntries :: Text -> [LocatedMetadata] -> [LocatedMetadata]
metadataEntries key = filter ((== key) . locatedMetadataKey)

admitMetadataValue
  :: Text
  -> (Text -> Either parseError value)
  -> (Int -> parseError -> ActualJournalError)
  -> [LocatedMetadata]
  -> ([ActualJournalError], Maybe (Int, value))
admitMetadataValue key parseValue invalidError entries = case entries of
  [] -> ([], Nothing)
  firstEntry : duplicateEntries ->
    ( duplicateErrors ++ parseErrors
    , either (const Nothing) (Just . withLine) parsed
    )
    where
      lineNumber = locatedMetadataLine firstEntry
      parsed = parseValue (locatedMetadataValue firstEntry)
      withLine value = (lineNumber, value)
      parseErrors = either (\err -> [invalidError lineNumber err])
        (const []) parsed
      duplicateErrors =
        [ DuplicateActualMetadataKey (locatedMetadataLine entry) key
        | entry <- duplicateEntries
        ]

duplicateActualIdErrors
  :: [LocatedIdentifiedActual]
  -> [ActualJournalError]
duplicateActualIdErrors identified =
  [ DuplicateActualEventIdDefinition actualId lines'
  | (actualId, lineNumbers) <- Map.toAscList linesByActualId
  , Just lines' <- [NonEmpty.nonEmpty (sort lineNumbers)]
  , NonEmpty.length lines' > 1
  ]
  where
    linesByActualId = Map.fromListWith (++)
      [ ( identifiedActualId (locatedIdentifiedValue value)
        , [locatedIdentifiedLine value]
        )
      | value <- identified
      ]
