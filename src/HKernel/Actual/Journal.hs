{-# LANGUAGE OverloadedStrings #-}

-- | Explicit Actual metadata projection from an Actual Journal source.
--
-- The canonical Journal parser remains the owner of accounting syntax,
-- declarations, postings, exact amounts, and transaction validation. This
-- module projects the explicit coordinates needed by Plan completion and
-- transaction reversal:
--
-- * @event-id@ identifies an externally durable Actual transaction;
-- * @plan-id@ names the Plan completed by the transaction carrying it;
-- * @reverses@ names the Actual transaction negated by a reversal transaction.
--
-- Transactions without these keys remain ordinary Actual facts. A transaction
-- carrying @plan-id@ without @event-id@ receives a rebuildable runtime identity
-- derived from the Plan ID. No generated identity is written back to Journal,
-- and completion never depends on date, description, amount, or posting shape.
-- A reversal declaration, in contrast, requires its own explicit @event-id@ so
-- that every provenance edge has a durable source identity at both ends.
module HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalValue
  , actualJournalIdentifiedTransactions
  , actualJournalCompletionDeclarations
  , actualJournalReversalDeclarations
  , actualJournalRecords
  , ActualTransactionRecord(..)
  , ActualReversalDeclaration
  , reversalTransactionId
  , reversedTransactionId
  , ActualJournalError(..)
  , parseActualJournal
  ) where

import Data.Char (isSpace)
import Data.List (foldl', sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
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

-- | One validated Journal plus the explicit Actual metadata projections.
data ActualJournal = ActualJournal
  { actualJournalValue                  :: Journal
  , actualJournalIdentifiedTransactions :: [IdentifiedActualTransaction]
  , actualJournalCompletionDeclarations :: [PlanCompletionDeclaration]
  , actualJournalReversalDeclarations   :: [ActualReversalDeclaration]
  , actualJournalRecords                :: [ActualTransactionRecord]
  } deriving (Eq, Show)

-- | One source-aligned transaction record with optional durable identity and reversal target.
data ActualTransactionRecord = ActualTransactionRecord
  { actualRecordTransaction :: Transaction
  , actualRecordIdentity    :: Maybe ActualTransactionId
  , actualRecordReverses    :: Maybe ActualTransactionId
  } deriving (Eq, Show)

-- | One explicit provenance edge from a reversal transaction to its target.
--
-- The reversing transaction has its own durable identity. The target may use
-- either an explicit event identity or the rebuildable identity derived from a
-- Plan completion declaration. One target may be reversed directly at most
-- once; reversing that reversal is represented by a new edge to the reversal's
-- own identity.
data ActualReversalDeclaration = ActualReversalDeclaration
  { reversalTransactionId :: ActualTransactionId
  , reversedTransactionId :: ActualTransactionId
  } deriving (Eq, Show)

-- | Failure to admit accounting syntax or explicit Actual metadata.
data ActualJournalError
  = ActualJournalSyntaxError JournalError
  | InvalidActualEventId Int ActualTransactionIdError
  | InvalidActualPlanId Int PlanIdError
  | InvalidActualReversesId Int ActualTransactionIdError
  | DuplicateActualMetadataKey Int Text
  | DuplicateActualEventIdDefinition ActualTransactionId (NonEmpty Int)
  | ActualReversalMissingEventId Int ActualTransactionId
  | ActualReversalSelfReference Int ActualTransactionId
  | UnknownActualReversalTarget ActualTransactionId ActualTransactionId
  | DuplicateActualReversalTarget ActualTransactionId (NonEmpty ActualTransactionId)
  | ActualTransactionMetadataAlignmentMismatch Int Int
  deriving (Eq, Show)

-- | Parse the accounting Journal, then project explicit Actual metadata.
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
          , actualJournalIdentifiedTransactions = identifiedTransactions
          , actualJournalCompletionDeclarations = declarations
          , actualJournalReversalDeclarations = reversals
          , actualJournalRecords = records
          }
    where
      transactions = journalTransactions journal
      metadataBlocks = transactionMetadataBlocks input
      transactionCount = length transactions
      metadataCount = length metadataBlocks
      admissions = zipWith admitTransactionMetadata transactions metadataBlocks
      locatedIdentified = mapMaybe admissionIdentified admissions
      identifiedTransactions =
        map locatedIdentifiedValue locatedIdentified
      declarations = mapMaybe admissionDeclaration admissions
      reversals = mapMaybe admissionReversal admissions
      records = map admissionRecord admissions
      allErrors =
        concatMap admissionErrors admissions
          ++ duplicateActualIdErrors locatedIdentified
          ++ reversalIntegrityErrors identifiedTransactions reversals

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
  , admissionReversal    :: Maybe ActualReversalDeclaration
  , admissionRecord      :: ActualTransactionRecord
  }

-- | Recover transaction blocks using the same top-level shape as the Journal
-- syntax, then retain only metadata owned by the Actual projection.
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
relevantMetadataKeys = ["event-id", "plan-id", "reverses"]

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
      eventErrors
        ++ planErrors
        ++ reversesErrors
        ++ derivedEventErrors
        ++ reversalErrors
  , admissionIdentified = locatedIdentified
  , admissionDeclaration = completionDeclaration
  , admissionReversal = reversalDeclaration
  , admissionRecord = record
  }
  where
    eventEntries = metadataEntries "event-id" metadata
    planEntries = metadataEntries "plan-id" metadata
    reversesEntries = metadataEntries "reverses" metadata
    (eventErrors, maybeEvent) = admitMetadataValue
      "event-id" mkActualTransactionId InvalidActualEventId eventEntries
    (planErrors, maybePlan) = admitMetadataValue
      "plan-id" mkPlanId InvalidActualPlanId planEntries
    (reversesErrors, maybeReverses) = admitMetadataValue
      "reverses"
      mkActualTransactionId
      InvalidActualReversesId
      reversesEntries

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

    (reversalErrors, reversalDeclaration) =
      case maybeReverses of
        Nothing -> ([], Nothing)
        Just (lineNumber, targetId)
          | null eventEntries ->
              ([ActualReversalMissingEventId lineNumber targetId], Nothing)
          | otherwise -> case maybeEvent of
              Nothing -> ([], Nothing)
              Just (_, reversalId)
                | reversalId == targetId ->
                    ([ActualReversalSelfReference lineNumber reversalId], Nothing)
                | otherwise ->
                    ([], Just ActualReversalDeclaration
                      { reversalTransactionId = reversalId
                      , reversedTransactionId = targetId
                      })

    record = ActualTransactionRecord
      { actualRecordTransaction = transaction
      , actualRecordIdentity = fmap snd effectiveEvent
      , actualRecordReverses = fmap reversedTransactionId reversalDeclaration
      }

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

reversalIntegrityErrors
  :: [IdentifiedActualTransaction]
  -> [ActualReversalDeclaration]
  -> [ActualJournalError]
reversalIntegrityErrors identified reversals =
  unknownTargetErrors ++ duplicateTargetErrors
  where
    identifiedIds = Set.fromList (map identifiedActualId identified)

    unknownTargetErrors =
      [ UnknownActualReversalTarget reversalId targetId
      | declaration <- reversals
      , let reversalId = reversalTransactionId declaration
      , let targetId = reversedTransactionId declaration
      , targetId `Set.notMember` identifiedIds
      ]

    reversalIdsByTarget = Map.fromListWith (++)
      [ (reversedTransactionId declaration,
          [reversalTransactionId declaration])
      | declaration <- reversals
      ]

    duplicateTargetErrors =
      [ DuplicateActualReversalTarget targetId reversalIds
      | (targetId, ids) <- Map.toAscList reversalIdsByTarget
      , Just reversalIds <- [NonEmpty.nonEmpty (sort ids)]
      , NonEmpty.length reversalIds > 1
      ]
