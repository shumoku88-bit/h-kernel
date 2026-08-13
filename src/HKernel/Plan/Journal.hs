{-# LANGUAGE OverloadedStrings #-}

-- | Durable Plan identity, lifecycle, role-flow classification, and narrow
-- report projection from a validated Journal source.
--
-- The canonical Journal parser owns declarations, postings, exact amounts,
-- balancing, transaction validation, and lexical transaction metadata. This
-- module adds the Plan-specific boundaries: every Plan transaction carries
-- exactly one unique @plan-id@; narrow lifecycle metadata may retire it without
-- rewriting the original transaction; then its complete Posting shape may be
-- classified from signed Account roles.
--
-- The whole validated 'Transaction' is retained throughout. Canonical source
-- evidence remains attached to the admitted 'PlanJournal' by durable PlanId so
-- Plan-owned metadata can be interpreted without rescanning raw text. Neither
-- admission nor classification flattens a multi-posting Plan into one source,
-- one destination, or one amount. The current report projection accepts only
-- the binary subset and retains the original whole transaction beside the
-- narrower 'CommittedOutgoingPlan'.
module HKernel.Plan.Journal
  ( PlanJournal
  , planJournalValue
  , planJournalTransactions
  , planJournalTransactionSourceFor
  , IdentifiedPlanTransaction
  , identifiedPlanId
  , identifiedPlanTransaction
  , PlanJournalError(..)
  , parsePlanJournal
  , admitPlanJournalFromResolvedJournal
  , admitPlanJournalFromResolvedSources
  , PlanLifecycleError(..)
  , planLifecycleErrorLine
  , admitPlanRetirements
  , planRetiredAt
  , retiredPlanIdsAt
  , ClassifiedPlanTransaction(..)
  , PlanClassificationError(..)
  , classifyPlanJournal
  , classifiedIncomingPlanTransactions
  , classifiedOutgoingPlanTransactions
  , ProjectedCommittedOutgoingPlan
  , projectedPlanSource
  , projectedCommittedOutgoingPlan
  , PlanReportProjectionError(..)
  , projectCommittedOutgoingPlans
  ) where

import Data.Either (partitionEithers)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.Account
  ( AccountRegistry
  , AccountType(..)
  , accountTypeFor
  )
import HKernel.Journal
  ( Journal
  , JournalDocument
  , JournalError
  , JournalMetadata
  , JournalTransactionSource
  , journalAccountRegistry
  , journalDocumentTransactionSources
  , journalMetadataKey
  , journalMetadataLine
  , journalMetadataValue
  , journalTransactionSourceHeaderLine
  , journalTransactionSourceMetadata
  , journalTransactionSourceTransaction
  , journalTransactions
  , parseJournalDocument
  , validateJournalDocument
  )
import HKernel.Ledger
  ( Posting
  , Transaction
  , postingAccount
  , postingAmount
  , transactionDate
  , transactionDescription
  , transactionPostings
  )
import HKernel.Money (amountQuantity, zeroQuantity)
import HKernel.Plan
  ( CommittedOutgoingPlan
  , PlanId
  , PlanIdError
  , PlanRetirement
  , PlanRetirementError
  , admitOutgoingPaymentDirection
  , admitPaymentDirection
  , declarePlanCancellation
  , declarePlanSupersession
  , mkCommittedOutgoingPlan
  , mkPaymentDirection
  , mkPlanId
  , mkPositiveAmount
  , planRetiredOn
  , planRetirementSuccessor
  , retiredPlanId
  )

-- | One validated Plan Journal and its durable transaction identities. Root
-- source evidence is indexed privately by the same admitted PlanId.
data PlanJournal = PlanJournal
  { planJournalValue              :: Journal
  , planJournalTransactions       :: [IdentifiedPlanTransaction]
  , planJournalTransactionSources :: Map PlanId JournalTransactionSource
  } deriving (Show)

-- Physical source coordinates are provenance rather than semantic equality.
-- Metadata key/value evidence is semantic here because downstream Plan domains
-- may interpret it, while direct and resolved roots can legitimately place the
-- same evidence at different line numbers.
instance Eq PlanJournal where
  left == right =
    planJournalValue left == planJournalValue right
      && planJournalTransactions left == planJournalTransactions right
      && fmap sourceMetadataMeaning (planJournalTransactionSources left)
          == fmap sourceMetadataMeaning (planJournalTransactionSources right)

sourceMetadataMeaning :: JournalTransactionSource -> [(Text, Text)]
sourceMetadataMeaning source =
  [ (journalMetadataKey entry, journalMetadataValue entry)
  | entry <- journalTransactionSourceMetadata source
  ]

-- | Read canonical root-source evidence for one admitted Plan identity.
--
-- Consumers receive parser-produced structure, not a new raw-source grammar.
planJournalTransactionSourceFor
  :: PlanId
  -> PlanJournal
  -> Maybe JournalTransactionSource
planJournalTransactionSourceFor planId =
  Map.lookup planId . planJournalTransactionSources

-- | A whole validated transaction paired with its durable Plan identity.
data IdentifiedPlanTransaction = IdentifiedPlanTransaction
  { identifiedPlanId          :: PlanId
  , identifiedPlanTransaction :: Transaction
  } deriving (Eq, Show)

-- | Failure to admit accounting syntax or required Plan identity metadata.
data PlanJournalError
  = PlanJournalSyntaxError JournalError
  | MissingPlanId Int
  | InvalidPlanJournalPlanId Int PlanIdError
  | DuplicatePlanJournalMetadataKey Int Text
  | DuplicatePlanJournalPlanId PlanId (NonEmpty Int)
  | PlanJournalTransactionMetadataAlignmentMismatch Int Int
  | PlanJournalTransactionSourceAlignmentMismatch Int
  deriving (Eq, Show)

-- | Parse the accounting Journal, require durable Plan identity, and retain
-- parser-owned metadata for later Plan-specific admission.
parsePlanJournal
  :: Text
  -> Either (NonEmpty PlanJournalError) PlanJournal
parsePlanJournal input = case parseJournalDocument input of
  Left journalErrors -> Left (fmap PlanJournalSyntaxError journalErrors)
  Right document -> case validateJournalDocument document of
    Left journalErrors -> Left (fmap PlanJournalSyntaxError journalErrors)
    Right journal -> admitPlanJournalFromDocument journal document

-- | Admit root-owned Plan metadata against an already resolved Journal.
admitPlanJournalFromResolvedJournal
  :: Journal
  -> Text
  -> Either (NonEmpty PlanJournalError) PlanJournal
admitPlanJournalFromResolvedJournal journal input =
  case parseJournalDocument input of
    Left journalErrors -> Left (fmap PlanJournalSyntaxError journalErrors)
    Right document -> admitPlanJournalFromDocument journal document

-- | Admit Plan meaning from parser-owned root transaction evidence retained by
-- the same loading observation as the resolved Journal.
admitPlanJournalFromResolvedSources
  :: Journal
  -> [JournalTransactionSource]
  -> Either (NonEmpty PlanJournalError) PlanJournal
admitPlanJournalFromResolvedSources = admitPlanJournalFromSources

admitPlanJournalFromDocument
  :: Journal
  -> JournalDocument
  -> Either (NonEmpty PlanJournalError) PlanJournal
admitPlanJournalFromDocument journal document =
  admitPlanJournalFromSources
    journal
    (journalDocumentTransactionSources document)

admitPlanJournalFromSources
  :: Journal
  -> [JournalTransactionSource]
  -> Either (NonEmpty PlanJournalError) PlanJournal
admitPlanJournalFromSources journal metadataBlocks
  | transactionCount /= metadataCount = Left
      (PlanJournalTransactionMetadataAlignmentMismatch
        transactionCount metadataCount NonEmpty.:| [])
  | Just sourceErrors <- NonEmpty.nonEmpty sourceAlignmentErrors =
      Left sourceErrors
  | otherwise = case NonEmpty.nonEmpty allErrors of
      Just errors -> Left errors
      Nothing -> Right PlanJournal
        { planJournalValue = journal
        , planJournalTransactions = map locatedPlanValue locatedPlans
        , planJournalTransactionSources = Map.fromList
            [ (identifiedPlanId (locatedPlanValue located), locatedPlanSource located)
            | located <- locatedPlans
            ]
        }
  where
    transactions = journalTransactions journal
    transactionCount = length transactions
    metadataCount = length metadataBlocks
    sourceAlignmentErrors =
      [ PlanJournalTransactionSourceAlignmentMismatch index
      | (index, transaction, source) <- zip3 [1..] transactions metadataBlocks
      , transaction /= journalTransactionSourceTransaction source
      ]
    admissions = zipWith admitPlanMetadata transactions metadataBlocks
    locatedPlans = mapMaybe admissionPlan admissions
    allErrors =
      concatMap admissionErrors admissions
        ++ duplicatePlanIdErrors locatedPlans

data LocatedPlanTransaction = LocatedPlanTransaction
  { locatedPlanLine   :: Int
  , locatedPlanValue  :: IdentifiedPlanTransaction
  , locatedPlanSource :: JournalTransactionSource
  }

data PlanMetadataAdmission = PlanMetadataAdmission
  { admissionErrors :: [PlanJournalError]
  , admissionPlan   :: Maybe LocatedPlanTransaction
  }

admitPlanMetadata
  :: Transaction
  -> JournalTransactionSource
  -> PlanMetadataAdmission
admitPlanMetadata transaction source = case metadataEntries of
  [] -> PlanMetadataAdmission
    { admissionErrors = [MissingPlanId (journalTransactionSourceHeaderLine source)]
    , admissionPlan = Nothing
    }
  firstEntry : duplicateEntries -> PlanMetadataAdmission
    { admissionErrors = duplicateErrors ++ parseErrors
    , admissionPlan = either (const Nothing) (Just . located) parsed
    }
    where
      lineNumber = journalMetadataLine firstEntry
      parsed = mkPlanId (journalMetadataValue firstEntry)
      duplicateErrors =
        [ DuplicatePlanJournalMetadataKey
            (journalMetadataLine entry)
            (journalMetadataKey entry)
        | entry <- duplicateEntries
        ]
      parseErrors = either
        (\err -> [InvalidPlanJournalPlanId lineNumber err])
        (const [])
        parsed
      located planId = LocatedPlanTransaction
        { locatedPlanLine = lineNumber
        , locatedPlanValue = IdentifiedPlanTransaction
            { identifiedPlanId = planId
            , identifiedPlanTransaction = transaction
            }
        , locatedPlanSource = source
        }
  where
    metadataEntries = filter ((== "plan-id") . journalMetadataKey)
      (journalTransactionSourceMetadata source)

duplicatePlanIdErrors
  :: [LocatedPlanTransaction]
  -> [PlanJournalError]
duplicatePlanIdErrors identified =
  [ DuplicatePlanJournalPlanId planId lines'
  | (planId, lineNumbers) <- Map.toAscList linesByPlanId
  , Just lines' <- [NonEmpty.nonEmpty (sort lineNumbers)]
  , NonEmpty.length lines' > 1
  ]
  where
    linesByPlanId = Map.fromListWith (++)
      [ ( identifiedPlanId (locatedPlanValue value)
        , [locatedPlanLine value]
        )
      | value <- identified
      ]

-- Plan lifecycle

-- | Failure to admit Plan-owned cancellation/supersession metadata.
data PlanLifecycleError
  = MissingPlanLifecycleSource PlanId
  | DuplicatePlanLifecycleMetadataKey Int Text
  | InvalidPlanLifecycleDate Int Text
  | InvalidSupersessionPlanId Int PlanIdError
  | InvalidPlanRetirement Int PlanRetirementError
  | CancellationConflictsWithSupersession Int PlanId
  | SupersededOnMissingSuccessor Int PlanId
  | SupersededByMissingDate Int PlanId
  | UnknownPlanSuccessor PlanId PlanId
  | SupersessionCycle PlanId
  deriving (Eq, Show)

planLifecycleErrorLine :: PlanLifecycleError -> Int
planLifecycleErrorLine err = case err of
  MissingPlanLifecycleSource _ -> 0
  DuplicatePlanLifecycleMetadataKey lineNumber _ -> lineNumber
  InvalidPlanLifecycleDate lineNumber _ -> lineNumber
  InvalidSupersessionPlanId lineNumber _ -> lineNumber
  InvalidPlanRetirement lineNumber _ -> lineNumber
  CancellationConflictsWithSupersession lineNumber _ -> lineNumber
  SupersededOnMissingSuccessor lineNumber _ -> lineNumber
  SupersededByMissingDate lineNumber _ -> lineNumber
  UnknownPlanSuccessor _ _ -> 0
  SupersessionCycle _ -> 0

-- | Admit retirement evidence while preserving the original Plan transaction.
--
-- Cancellation is represented by @cancelled-on@. Supersession requires both
-- @superseded-on@ and @superseded-by@. References are checked against the whole
-- admitted Plan collection; self-reference, unknown successors, and cycles fail
-- closed.
admitPlanRetirements
  :: PlanJournal
  -> Either (NonEmpty PlanLifecycleError) [PlanRetirement]
admitPlanRetirements planJournal =
  case NonEmpty.nonEmpty allErrors of
    Just errors -> Left errors
    Nothing -> Right retirements
  where
    identifiedPlans = planJournalTransactions planJournal
    knownPlanIds = Set.fromList (map identifiedPlanId identifiedPlans)
    (localFailures, localValues) = partitionEithers
      (map (retirementForPlan planJournal) identifiedPlans)
    localErrors = concatMap NonEmpty.toList localFailures
    retirements = [retirement | Just retirement <- localValues]
    unknownTargetErrors =
      [ UnknownPlanSuccessor (retiredPlanId retirement) successor
      | retirement <- retirements
      , Just successor <- [planRetirementSuccessor retirement]
      , successor `Set.notMember` knownPlanIds
      ]
    successorByPlan = Map.fromList
      [ (retiredPlanId retirement, successor)
      | retirement <- retirements
      , Just successor <- [planRetirementSuccessor retirement]
      , successor `Set.member` knownPlanIds
      ]
    cycleErrors =
      [ SupersessionCycle start
      | start <- Map.keys successorByPlan
      , supersessionCycleFrom successorByPlan start
      ]
    allErrors = localErrors ++ unknownTargetErrors ++ cycleErrors

planRetiredAt :: Day -> PlanRetirement -> Bool
planRetiredAt observation retirement = planRetiredOn retirement <= observation

retiredPlanIdsAt :: Day -> [PlanRetirement] -> Set.Set PlanId
retiredPlanIdsAt observation = Set.fromList
  . map retiredPlanId
  . filter (planRetiredAt observation)

retirementForPlan
  :: PlanJournal
  -> IdentifiedPlanTransaction
  -> Either (NonEmpty PlanLifecycleError) (Maybe PlanRetirement)
retirementForPlan planJournal identified = do
  source <- maybe
    (Left (MissingPlanLifecycleSource planId NonEmpty.:| []))
    Right
    (planJournalTransactionSourceFor planId planJournal)
  let metadata = journalTransactionSourceMetadata source
      (cancelErrors, maybeCancelledOn) = singleLifecycleMetadata "cancelled-on" metadata
      (supersededOnErrors, maybeSupersededOn) =
        singleLifecycleMetadata "superseded-on" metadata
      (supersededByErrors, maybeSupersededBy) =
        singleLifecycleMetadata "superseded-by" metadata
      duplicateErrors =
        cancelErrors ++ supersededOnErrors ++ supersededByErrors
  case NonEmpty.nonEmpty duplicateErrors of
    Just errors -> Left errors
    Nothing ->
      buildRetirement planId maybeCancelledOn maybeSupersededOn maybeSupersededBy
  where
    planId = identifiedPlanId identified

buildRetirement
  :: PlanId
  -> Maybe JournalMetadata
  -> Maybe JournalMetadata
  -> Maybe JournalMetadata
  -> Either (NonEmpty PlanLifecycleError) (Maybe PlanRetirement)
buildRetirement planId maybeCancelled maybeSupersededOn maybeSupersededBy =
  case (maybeCancelled, maybeSupersededOn, maybeSupersededBy) of
    (Nothing, Nothing, Nothing) -> Right Nothing
    (Just cancelledEntry, Nothing, Nothing) -> do
      cancelledOn <- parseLifecycleDay "cancelled-on" cancelledEntry
      Right (Just (declarePlanCancellation planId cancelledOn))
    (Nothing, Just supersededOnEntry, Just supersededByEntry) -> do
      supersededOn <- parseLifecycleDay "superseded-on" supersededOnEntry
      successor <- mapLeft
        (\err -> InvalidSupersessionPlanId
          (journalMetadataLine supersededByEntry) err NonEmpty.:| [])
        (mkPlanId (journalMetadataValue supersededByEntry))
      retirement <- mapLeft
        (\err -> InvalidPlanRetirement
          (journalMetadataLine supersededByEntry) err NonEmpty.:| [])
        (declarePlanSupersession planId supersededOn successor)
      Right (Just retirement)
    (Just entry, _, _) -> Left
      (CancellationConflictsWithSupersession
        (journalMetadataLine entry) planId NonEmpty.:| [])
    (Nothing, Just entry, Nothing) -> Left
      (SupersededOnMissingSuccessor
        (journalMetadataLine entry) planId NonEmpty.:| [])
    (Nothing, Nothing, Just entry) -> Left
      (SupersededByMissingDate
        (journalMetadataLine entry) planId NonEmpty.:| [])

singleLifecycleMetadata
  :: Text
  -> [JournalMetadata]
  -> ([PlanLifecycleError], Maybe JournalMetadata)
singleLifecycleMetadata key metadata =
  case filter ((== key) . journalMetadataKey) metadata of
    [] -> ([], Nothing)
    [entry] -> ([], Just entry)
    firstEntry : duplicates ->
      ( [ DuplicatePlanLifecycleMetadataKey (journalMetadataLine entry) key
        | entry <- duplicates
        ]
      , Just firstEntry
      )

parseLifecycleDay
  :: Text
  -> JournalMetadata
  -> Either (NonEmpty PlanLifecycleError) Day
parseLifecycleDay key entry =
  maybe
    (Left (InvalidPlanLifecycleDate
      (journalMetadataLine entry) key NonEmpty.:| []))
    Right
    (parseTimeM True defaultTimeLocale "%Y-%m-%d"
      (T.unpack (journalMetadataValue entry)))

supersessionCycleFrom :: Map PlanId PlanId -> PlanId -> Bool
supersessionCycleFrom successorByPlan start = go (Set.singleton start) start
  where
    go seen current = case Map.lookup current successorByPlan of
      Nothing -> False
      Just successor
        | successor `Set.member` seen -> True
        | otherwise -> go (Set.insert successor seen) successor

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value

-- | A whole Plan transaction classified without changing its Posting shape.
data ClassifiedPlanTransaction
  = IncomingPlanTransaction IdentifiedPlanTransaction
  | OutgoingPlanTransaction IdentifiedPlanTransaction
  deriving (Eq, Show)

-- | A transaction whose complete signed Account-role shape is not supported.
newtype PlanClassificationError = UnsupportedPlanRoleFlow PlanId
  deriving (Eq, Show)

-- | Classify all transactions from declarative predicates over Posting roles.
--
-- Supported shapes are:
--
-- @
-- Income(-) -> Asset(+)                    incoming
-- Asset(-)  -> Expense(+)/Liability(+)     outgoing
-- @
--
-- Multiple Postings on either side are accepted when every Posting belongs to
-- the same supported shape. Unsupported transactions are accumulated and no
-- partial classified result is published.
classifyPlanJournal
  :: PlanJournal
  -> Either (NonEmpty PlanClassificationError) [ClassifiedPlanTransaction]
classifyPlanJournal source = case partitionEithers classifications of
  ([], classified) -> Right classified
  (firstError : remainingErrors, _) ->
    Left (firstError NonEmpty.:| remainingErrors)
  where
    registry = journalAccountRegistry (planJournalValue source)
    classifications = map (classifyPlanTransaction registry)
      (planJournalTransactions source)

classifyPlanTransaction
  :: AccountRegistry
  -> IdentifiedPlanTransaction
  -> Either PlanClassificationError ClassifiedPlanTransaction
classifyPlanTransaction registry identified
  | incomingShape coordinates = Right (IncomingPlanTransaction identified)
  | outgoingShape coordinates = Right (OutgoingPlanTransaction identified)
  | otherwise = Left (UnsupportedPlanRoleFlow (identifiedPlanId identified))
  where
    coordinates = map (postingCoordinate registry)
      (NonEmpty.toList
        (transactionPostings (identifiedPlanTransaction identified)))

type PostingCoordinate = (Maybe AccountType, Ordering)

postingCoordinate :: AccountRegistry -> Posting -> PostingCoordinate
postingCoordinate registry posting =
  ( accountTypeFor (postingAccount posting) registry
  , compare (amountQuantity (postingAmount posting)) zeroQuantity
  )

incomingShape :: [PostingCoordinate] -> Bool
incomingShape coordinates =
  hasCoordinate (Just Income, LT) coordinates
    && hasCoordinate (Just Asset, GT) coordinates
    && all (`elem` [(Just Income, LT), (Just Asset, GT)]) coordinates

outgoingShape :: [PostingCoordinate] -> Bool
outgoingShape coordinates =
  hasCoordinate (Just Asset, LT) coordinates
    && any (`hasCoordinate` coordinates)
      [(Just Expense, GT), (Just Liability, GT)]
    && all (`elem`
      [ (Just Asset, LT)
      , (Just Expense, GT)
      , (Just Liability, GT)
      ]) coordinates

hasCoordinate :: PostingCoordinate -> [PostingCoordinate] -> Bool
hasCoordinate = elem

classifiedIncomingPlanTransactions
  :: [ClassifiedPlanTransaction]
  -> [IdentifiedPlanTransaction]
classifiedIncomingPlanTransactions classified =
  [ plan
  | IncomingPlanTransaction plan <- classified
  ]

classifiedOutgoingPlanTransactions
  :: [ClassifiedPlanTransaction]
  -> [IdentifiedPlanTransaction]
classifiedOutgoingPlanTransactions classified =
  [ plan
  | OutgoingPlanTransaction plan <- classified
  ]

-- | One current report value paired with the complete Journal evidence from
-- which it was projected.
data ProjectedCommittedOutgoingPlan = ProjectedCommittedOutgoingPlan
  { projectedPlanSource            :: IdentifiedPlanTransaction
  , projectedCommittedOutgoingPlan :: CommittedOutgoingPlan
  } deriving (Eq, Show)

-- | The current report type can express only one source and one destination.
--
-- This is a projection limitation, not a rejection of the admitted Plan source.
newtype PlanReportProjectionError
  = PlanReportProjectionRequiresBinaryOutgoing PlanId
  deriving (Eq, Show)

-- | Project the binary outgoing subset into the current report-facing Plan type.
--
-- Incoming classifications are outside this outgoing projection. Every binary
-- result retains its complete source transaction. Multi-posting outgoing Plans
-- fail explicitly rather than being flattened or partially published.
projectCommittedOutgoingPlans
  :: PlanJournal
  -> [ClassifiedPlanTransaction]
  -> Either
      (NonEmpty PlanReportProjectionError)
      [ProjectedCommittedOutgoingPlan]
projectCommittedOutgoingPlans source classified =
  case partitionEithers projections of
    ([], projected) -> Right projected
    (firstError : remainingErrors, _) ->
      Left (firstError NonEmpty.:| remainingErrors)
  where
    registry = journalAccountRegistry (planJournalValue source)
    projections =
      [ projectCommittedOutgoingPlan registry identified
      | OutgoingPlanTransaction identified <- classified
      ]

projectCommittedOutgoingPlan
  :: AccountRegistry
  -> IdentifiedPlanTransaction
  -> Either PlanReportProjectionError ProjectedCommittedOutgoingPlan
projectCommittedOutgoingPlan registry identified =
  case binaryCommittedOutgoingPlan registry identified of
    Just committed -> Right ProjectedCommittedOutgoingPlan
      { projectedPlanSource = identified
      , projectedCommittedOutgoingPlan = committed
      }
    Nothing -> Left
      (PlanReportProjectionRequiresBinaryOutgoing (identifiedPlanId identified))

binaryCommittedOutgoingPlan
  :: AccountRegistry
  -> IdentifiedPlanTransaction
  -> Maybe CommittedOutgoingPlan
binaryCommittedOutgoingPlan registry identified = do
  (sourcePosting, destinationPosting) <-
    binaryOutgoingPostings registry transaction
  direction <- toMaybe
    (mkPaymentDirection
      (postingAccount sourcePosting)
      (postingAccount destinationPosting))
  declared <- toMaybe (admitPaymentDirection registry direction)
  outgoing <- toMaybe (admitOutgoingPaymentDirection declared)
  positive <- toMaybe (mkPositiveAmount (postingAmount destinationPosting))
  toMaybe
    (mkCommittedOutgoingPlan
      (identifiedPlanId identified)
      (transactionDate transaction)
      (transactionDescription transaction)
      positive
      outgoing)
  where
    transaction = identifiedPlanTransaction identified

binaryOutgoingPostings
  :: AccountRegistry
  -> Transaction
  -> Maybe (Posting, Posting)
binaryOutgoingPostings registry transaction =
  case NonEmpty.toList (transactionPostings transaction) of
    [firstPosting, secondPosting]
      | isSource firstPosting && isDestination secondPosting ->
          Just (firstPosting, secondPosting)
      | isSource secondPosting && isDestination firstPosting ->
          Just (secondPosting, firstPosting)
    _ -> Nothing
  where
    isSource posting =
      postingCoordinate registry posting == (Just Asset, LT)
    isDestination posting =
      postingCoordinate registry posting
        `elem` [(Just Expense, GT), (Just Liability, GT)]

toMaybe :: Either error value -> Maybe value
toMaybe = either (const Nothing) Just