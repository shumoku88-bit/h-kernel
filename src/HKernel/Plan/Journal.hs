{-# LANGUAGE OverloadedStrings #-}

-- | Durable Plan identity, role-flow classification, and narrow report
-- projection from a validated Journal source.
--
-- The canonical Journal parser owns declarations, postings, exact amounts,
-- balancing, transaction validation, and lexical transaction metadata. This
-- module adds the Plan-specific boundaries: every Plan transaction carries
-- exactly one unique @plan-id@, then its complete Posting shape may be
-- classified from signed Account roles.
--
-- The whole validated 'Transaction' is retained throughout. Canonical source
-- evidence remains attached to the admitted 'PlanJournal' by durable PlanId so
-- downstream domain owners can interpret metadata without rescanning raw text.
-- Neither admission nor classification flattens a multi-posting Plan into one
-- source, one destination, or one amount. The current report projection accepts
-- only the binary subset and retains the original whole transaction beside the
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
import Data.Text (Text)
import HKernel.Account
  ( AccountRegistry
  , AccountType(..)
  , accountTypeFor
  )
import HKernel.Journal
  ( Journal
  , JournalDocument
  , JournalError
  , JournalTransactionSource
  , journalAccountRegistry
  , journalDocumentTransactionSources
  , journalMetadataKey
  , journalMetadataLine
  , journalMetadataValue
  , journalTransactionSourceHeaderLine
  , journalTransactionSourceMetadata
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
  , admitOutgoingPaymentDirection
  , admitPaymentDirection
  , mkCommittedOutgoingPlan
  , mkPaymentDirection
  , mkPlanId
  , mkPositiveAmount
  )

-- | One validated Plan Journal and its durable transaction identities. Root
-- source evidence is indexed privately by the same admitted PlanId.
data PlanJournal = PlanJournal
  { planJournalValue              :: Journal
  , planJournalTransactions       :: [IdentifiedPlanTransaction]
  , planJournalTransactionSources :: Map PlanId JournalTransactionSource
  } deriving (Show)

-- Source locations are provenance for later domain-specific admission, not part
-- of PlanJournal's semantic equality. A resolved root may place the same Plan
-- transaction at different physical line numbers while retaining identical
-- accounting and Plan meaning.
instance Eq PlanJournal where
  left == right =
    planJournalValue left == planJournalValue right
      && planJournalTransactions left == planJournalTransactions right

-- | Read canonical root-source evidence for one admitted Plan identity.
--
-- Consumers receive parser-produced structure, not a new raw-source grammar.
-- Metadata meaning remains with the requesting domain owner.
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
  deriving (Eq, Show)

-- | Parse accounting syntax, then require one unique @plan-id@ per transaction.
--
-- Output order follows transaction source order. Unrelated metadata receives no
-- invented Plan meaning, while its canonical source evidence remains available
-- from the admitted PlanJournal for later domain-specific interpretation.
parsePlanJournal
  :: Text
  -> Either (NonEmpty PlanJournalError) PlanJournal
parsePlanJournal input = case parseJournalDocument input of
  Left journalErrors -> Left (fmap PlanJournalSyntaxError journalErrors)
  Right document -> case validateJournalDocument document of
    Left journalErrors -> Left (fmap PlanJournalSyntaxError journalErrors)
    Right journal -> admitPlanJournalFromDocument journal document

-- | Admit root-owned Plan metadata against an already resolved Journal.
--
-- The root document is parsed with the canonical Journal structural parser so
-- includes may still contribute declarations without silently contributing
-- hidden Plan transactions. Metadata meaning remains owned by downstream Plan
-- consumers rather than by the lexical parser.
admitPlanJournalFromResolvedJournal
  :: Journal
  -> Text
  -> Either (NonEmpty PlanJournalError) PlanJournal
admitPlanJournalFromResolvedJournal journal input =
  case parseJournalDocument input of
    Left journalErrors -> Left (fmap PlanJournalSyntaxError journalErrors)
    Right document -> admitPlanJournalFromDocument journal document

admitPlanJournalFromDocument
  :: Journal
  -> JournalDocument
  -> Either (NonEmpty PlanJournalError) PlanJournal
admitPlanJournalFromDocument journal document
  | transactionCount /= metadataCount = Left
      (PlanJournalTransactionMetadataAlignmentMismatch
        transactionCount metadataCount NonEmpty.:| [])
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
    metadataBlocks = journalDocumentTransactionSources document
    transactionCount = length transactions
    metadataCount = length metadataBlocks
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
