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
  , actualJournalTransactionEntries
  , ActualTransactionEntry
  , actualTransactionEntryTransaction
  , actualTransactionEntryIdentity
  , actualTransactionEntrySource
  , actualJournalIdentifiedTransactions
  , actualJournalCompletionDeclarations
  , actualJournalReversalDeclarations
  , ActualReversalDeclaration
  , reversalTransactionId
  , reversedTransactionId
  , ActualJournalError(..)
  , parseActualJournal
  , admitActualJournalFromResolvedJournal
  , admitActualJournalFromResolvedSources
  ) where

import Data.List (sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import HKernel.Account (Account)
import HKernel.Journal
  ( Journal
  , JournalDocument
  , JournalError
  , JournalMetadata
  , JournalTransactionSource
  , journalDocumentTransactionSources
  , journalMetadataKey
  , journalMetadataLine
  , journalMetadataValue
  , journalTransactionSourceMetadata
  , journalTransactionSourceTransaction
  , journalTransactions
  , parseJournalDocument
  , validateJournalDocument
  )
import HKernel.Ledger
  ( Transaction
  , postingAccount
  , postingAmount
  , transactionPostings
  )
import HKernel.Money
  ( Commodity
  , Quantity
  , addQuantity
  , amountCommodity
  , amountQuantity
  , negateQuantity
  , zeroQuantity
  )
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
  , identifiedActualTransaction
  , mkActualTransactionId
  )

-- | One Actual transaction in root-source order together with the identity that
-- Actual metadata admission assigned to that exact source position, when any,
-- and the parser-owned source evidence from the same observation.
--
-- Keeping these associations here avoids reconstructing identity or source
-- coordinates later from date, description, amount, or Transaction equality.
-- Ordinary identity-free Actual facts remain present with 'Nothing'.
data ActualTransactionEntry = ActualTransactionEntry
  { actualTransactionEntryTransaction :: Transaction
  , actualTransactionEntryIdentity    :: Maybe ActualTransactionId
  , actualTransactionEntrySource      :: JournalTransactionSource
  } deriving (Show)

-- Physical source coordinates are provenance rather than Actual semantic
-- equality. The retained source evidence exists so a writer can safely target
-- the selected admitted block without making line numbers part of identity.
instance Eq ActualTransactionEntry where
  left == right =
    actualTransactionEntryTransaction left
      == actualTransactionEntryTransaction right
      && actualTransactionEntryIdentity left
        == actualTransactionEntryIdentity right

-- | One validated Journal plus the explicit Actual metadata projections.
data ActualJournal = ActualJournal
  { actualJournalValue                  :: Journal
  , actualJournalTransactionEntries     :: [ActualTransactionEntry]
  , actualJournalIdentifiedTransactions :: [IdentifiedActualTransaction]
  , actualJournalCompletionDeclarations :: [PlanCompletionDeclaration]
  , actualJournalReversalDeclarations   :: [ActualReversalDeclaration]
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
  | ActualReversalPostingMismatch ActualTransactionId ActualTransactionId
  | ActualReversalCycle (NonEmpty ActualTransactionId)
  | ActualTransactionMetadataAlignmentMismatch Int Int
  | ActualTransactionSourceAlignmentMismatch Int
  deriving (Eq, Show)

-- | Parse the accounting Journal, then project explicit Actual metadata.
--
-- Unrelated metadata is not assigned runtime meaning by this narrow projection.
-- A later complete target-source schema must still preserve or diagnose every
-- metadata field before migration cutover.
parseActualJournal
  :: Text
  -> Either (NonEmpty ActualJournalError) ActualJournal
parseActualJournal input = case parseJournalDocument input of
  Left journalErrors -> Left (fmap ActualJournalSyntaxError journalErrors)
  Right document -> case validateJournalDocument document of
    Left journalErrors -> Left (fmap ActualJournalSyntaxError journalErrors)
    Right journal -> admitActualJournalFromDocument journal document

-- | Project root-source Actual metadata onto an already validated Journal.
--
-- The supplied Journal is expected to be the result of admitting the same root
-- source after its include graph has been resolved. Accounting declarations,
-- postings, exact amounts, and transaction validation therefore remain owned by
-- 'HKernel.Journal'; this compatibility entry point reparses the supplied root
-- text and then delegates to parser-owned source evidence.
admitActualJournalFromResolvedJournal
  :: Journal
  -> Text
  -> Either (NonEmpty ActualJournalError) ActualJournal
admitActualJournalFromResolvedJournal journal input =
  case parseJournalDocument input of
    Left journalErrors -> Left (fmap ActualJournalSyntaxError journalErrors)
    Right document -> admitActualJournalFromDocument journal document

-- | Project Actual meaning from parser-owned root transaction evidence that was
-- retained by the same loading observation as the resolved Journal.
--
-- This boundary is pure: the Loader owns filesystem observation while Actual
-- owns event identity, Plan completion, reversal provenance, and alignment.
admitActualJournalFromResolvedSources
  :: Journal
  -> [JournalTransactionSource]
  -> Either (NonEmpty ActualJournalError) ActualJournal
admitActualJournalFromResolvedSources = admitActualJournalFromSources

admitActualJournalFromDocument
  :: Journal
  -> JournalDocument
  -> Either (NonEmpty ActualJournalError) ActualJournal
admitActualJournalFromDocument journal document =
  admitActualJournalFromSources
    journal
    (journalDocumentTransactionSources document)

admitActualJournalFromSources
  :: Journal
  -> [JournalTransactionSource]
  -> Either (NonEmpty ActualJournalError) ActualJournal
admitActualJournalFromSources journal metadataBlocks
  | transactionCount /= metadataCount = Left
      (ActualTransactionMetadataAlignmentMismatch
        transactionCount metadataCount NonEmpty.:| [])
  | Just sourceErrors <- NonEmpty.nonEmpty sourceAlignmentErrors =
      Left sourceErrors
  | otherwise = case NonEmpty.nonEmpty allErrors of
      Just errors -> Left errors
      Nothing -> Right ActualJournal
        { actualJournalValue = journal
        , actualJournalTransactionEntries = transactionEntries
        , actualJournalIdentifiedTransactions = identifiedTransactions
        , actualJournalCompletionDeclarations = declarations
        , actualJournalReversalDeclarations = reversals
        }
  where
    transactions = journalTransactions journal
    transactionCount = length transactions
    metadataCount = length metadataBlocks
    sourceAlignmentErrors =
      [ ActualTransactionSourceAlignmentMismatch index
      | (index, transaction, source) <- zip3 [1..] transactions metadataBlocks
      , transaction /= journalTransactionSourceTransaction source
      ]
    admissions = zipWith admitTransactionMetadata transactions metadataBlocks
    transactionEntries = zipWith3 toTransactionEntry transactions metadataBlocks admissions
    toTransactionEntry transaction source admission = ActualTransactionEntry
      { actualTransactionEntryTransaction = transaction
      , actualTransactionEntryIdentity =
          identifiedActualId . locatedIdentifiedValue
            <$> admissionIdentified admission
      , actualTransactionEntrySource = source
      }
    locatedIdentified = mapMaybe admissionIdentified admissions
    identifiedTransactions =
      map locatedIdentifiedValue locatedIdentified
    declarations = mapMaybe admissionDeclaration admissions
    reversals = mapMaybe admissionReversal admissions
    allErrors =
      concatMap admissionErrors admissions
        ++ duplicateActualIdErrors locatedIdentified
        ++ reversalIntegrityErrors identifiedTransactions reversals

data LocatedIdentifiedActual = LocatedIdentifiedActual
  { locatedIdentifiedLine  :: Int
  , locatedIdentifiedValue :: IdentifiedActualTransaction
  }

data TransactionMetadataAdmission = TransactionMetadataAdmission
  { admissionErrors      :: [ActualJournalError]
  , admissionIdentified  :: Maybe LocatedIdentifiedActual
  , admissionDeclaration :: Maybe PlanCompletionDeclaration
  , admissionReversal    :: Maybe ActualReversalDeclaration
  }

admitTransactionMetadata
  :: Transaction
  -> JournalTransactionSource
  -> TransactionMetadataAdmission
admitTransactionMetadata transaction source = TransactionMetadataAdmission
  { admissionErrors =
      eventErrors
        ++ planErrors
        ++ reversesErrors
        ++ derivedEventErrors
        ++ reversalErrors
  , admissionIdentified = locatedIdentified
  , admissionDeclaration = completionDeclaration
  , admissionReversal = reversalDeclaration
  }
  where
    metadata = journalTransactionSourceMetadata source
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

metadataEntries :: Text -> [JournalMetadata] -> [JournalMetadata]
metadataEntries key = filter ((== key) . journalMetadataKey)

admitMetadataValue
  :: Text
  -> (Text -> Either parseError value)
  -> (Int -> parseError -> ActualJournalError)
  -> [JournalMetadata]
  -> ([ActualJournalError], Maybe (Int, value))
admitMetadataValue key parseValue invalidError entries = case entries of
  [] -> ([], Nothing)
  firstEntry : duplicateEntries ->
    ( duplicateErrors ++ parseErrors
    , either (const Nothing) (Just . withLine) parsed
    )
    where
      lineNumber = journalMetadataLine firstEntry
      parsed = parseValue (journalMetadataValue firstEntry)
      withLine value = (lineNumber, value)
      parseErrors = either (\err -> [invalidError lineNumber err])
        (const []) parsed
      duplicateErrors =
        [ DuplicateActualMetadataKey (journalMetadataLine entry) key
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
  unknownTargetErrors
    ++ duplicateTargetErrors
    ++ postingMismatchErrors
    ++ cycleErrors
  where
    identifiedById = Map.fromList
      [ (identifiedActualId actual, identifiedActualTransaction actual)
      | actual <- identified
      ]
    identifiedIds = Map.keysSet identifiedById

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

    postingMismatchErrors =
      [ ActualReversalPostingMismatch reversalId targetId
      | declaration <- reversals
      , let reversalId = reversalTransactionId declaration
      , let targetId = reversedTransactionId declaration
      , Just reversalTransaction <- [Map.lookup reversalId identifiedById]
      , Just targetTransaction <- [Map.lookup targetId identifiedById]
      , transactionPostingEffect reversalTransaction
          /= Map.map negateQuantity (transactionPostingEffect targetTransaction)
      ]

    targetByReversal = Map.fromList
      [ (reversalTransactionId declaration, reversedTransactionId declaration)
      | declaration <- reversals
      ]

    cycleSets = Set.fromList
      [ Set.fromList cycleMembers
      | reversalId <- Map.keys targetByReversal
      , Just cycleMembers <- [reversalCycleFrom targetByReversal reversalId]
      ]

    cycleErrors =
      [ ActualReversalCycle cycleIds
      | cycleSet <- Set.toAscList cycleSets
      , Just cycleIds <- [NonEmpty.nonEmpty (Set.toAscList cycleSet)]
      ]

transactionPostingEffect
  :: Transaction
  -> Map.Map (Account, Commodity) Quantity
transactionPostingEffect =
  Map.filter (/= zeroQuantity)
    . Map.fromListWith addQuantity
    . map postingCoordinate
    . NonEmpty.toList
    . transactionPostings
  where
    postingCoordinate posting =
      ( (postingAccount posting, amountCommodity amount)
      , amountQuantity amount
      )
      where
        amount = postingAmount posting

reversalCycleFrom
  :: Map.Map ActualTransactionId ActualTransactionId
  -> ActualTransactionId
  -> Maybe [ActualTransactionId]
reversalCycleFrom targetByReversal = go Set.empty []
  where
    go seen path current
      | current `Set.member` seen =
          Just (dropWhile (/= current) path)
      | otherwise = case Map.lookup current targetByReversal of
          Nothing -> Nothing
          Just target ->
            go (Set.insert current seen) (path ++ [current]) target
