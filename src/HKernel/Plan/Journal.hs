{-# LANGUAGE OverloadedStrings #-}

-- | Durable Plan identity, role-flow classification, and narrow report
-- projection from a validated Journal source.
--
-- The canonical Journal parser owns declarations, postings, exact amounts,
-- balancing, and transaction validation. This module adds the Plan-specific
-- boundaries: every Plan transaction carries exactly one unique @plan-id@,
-- then its complete Posting shape may be classified from signed Account roles.
--
-- The whole validated 'Transaction' is retained throughout. Neither admission
-- nor classification flattens a multi-posting Plan into one source, one
-- destination, or one amount. The current report projection accepts only the
-- binary subset and retains the original whole transaction beside the narrower
-- 'CommittedOutgoingPlan'.
module HKernel.Plan.Journal
  ( PlanJournal
  , planJournalValue
  , planJournalTransactions
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

import Data.Char (isSpace)
import Data.Either (partitionEithers)
import Data.List (foldl', sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
  ( AccountRegistry
  , AccountType(..)
  , accountTypeFor
  )
import HKernel.Journal
  ( Journal
  , JournalError
  , journalAccountRegistry
  , journalTransactions
  , parseJournal
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

-- | One validated Plan Journal and its durable transaction identities.
data PlanJournal = PlanJournal
  { planJournalValue        :: Journal
  , planJournalTransactions :: [IdentifiedPlanTransaction]
  } deriving (Eq, Show)

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
-- Output order follows transaction source order. Unrelated metadata remains
-- outside this narrow projection and receives no invented runtime meaning.
parsePlanJournal
  :: Text
  -> Either (NonEmpty PlanJournalError) PlanJournal
parsePlanJournal input = case parseJournal input of
  Left journalErrors -> Left (fmap PlanJournalSyntaxError journalErrors)
  Right journal -> admitPlanJournalFromResolvedJournal journal input

admitPlanJournalFromResolvedJournal
  :: Journal
  -> Text
  -> Either (NonEmpty PlanJournalError) PlanJournal
admitPlanJournalFromResolvedJournal journal input
  | transactionCount /= metadataCount = Left
      (PlanJournalTransactionMetadataAlignmentMismatch
        transactionCount metadataCount NonEmpty.:| [])
  | otherwise = case NonEmpty.nonEmpty allErrors of
      Just errors -> Left errors
      Nothing -> Right PlanJournal
        { planJournalValue = journal
        , planJournalTransactions = map locatedPlanValue locatedPlans
        }
  where
    transactions = journalTransactions journal
    metadataBlocks = transactionMetadataBlocks input
    transactionCount = length transactions
    metadataCount = length metadataBlocks
    admissions = zipWith admitPlanMetadata transactions metadataBlocks
    locatedPlans = mapMaybe admissionPlan admissions
    allErrors =
      concatMap admissionErrors admissions
        ++ duplicatePlanIdErrors locatedPlans

type LocatedLine = (Int, Text)

data LocatedMetadata = LocatedMetadata
  { locatedMetadataLine  :: Int
  , locatedMetadataKey   :: Text
  , locatedMetadataValue :: Text
  }

data TransactionMetadataBlock = TransactionMetadataBlock
  { transactionHeaderLine :: Int
  , transactionMetadata   :: [LocatedMetadata]
  }

data LocatedPlanTransaction = LocatedPlanTransaction
  { locatedPlanLine  :: Int
  , locatedPlanValue :: IdentifiedPlanTransaction
  }

data PlanMetadataAdmission = PlanMetadataAdmission
  { admissionErrors :: [PlanJournalError]
  , admissionPlan   :: Maybe LocatedPlanTransaction
  }

transactionMetadataBlocks :: Text -> [TransactionMetadataBlock]
transactionMetadataBlocks input =
  [ TransactionMetadataBlock
      { transactionHeaderLine = lineNumber
      , transactionMetadata = mapMaybe relevantMetadata (drop 1 block)
      }
  | block@((lineNumber, header) : _) <- sourceBlocks input
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
  | normalizedKey /= "plan-id" = Nothing
  | otherwise = Just LocatedMetadata
      { locatedMetadataLine = lineNumber
      , locatedMetadataKey = normalizedKey
      , locatedMetadataValue = T.strip (T.drop 1 remainder)
      }
  where
    cleanLine = T.strip
      (T.dropWhile (\character -> character == ';' || isSpace character)
        (T.strip line))
    (key, remainder) = T.breakOn ":" cleanLine
    normalizedKey = T.toCaseFold (T.strip key)

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

admitPlanMetadata
  :: Transaction
  -> TransactionMetadataBlock
  -> PlanMetadataAdmission
admitPlanMetadata transaction block = case metadataEntries of
  [] -> PlanMetadataAdmission
    { admissionErrors = [MissingPlanId (transactionHeaderLine block)]
    , admissionPlan = Nothing
    }
  firstEntry : duplicateEntries -> PlanMetadataAdmission
    { admissionErrors = duplicateErrors ++ parseErrors
    , admissionPlan = either (const Nothing) (Just . located) parsed
    }
    where
      lineNumber = locatedMetadataLine firstEntry
      parsed = mkPlanId (locatedMetadataValue firstEntry)
      duplicateErrors =
        [ DuplicatePlanJournalMetadataKey
            (locatedMetadataLine entry)
            (locatedMetadataKey entry)
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
        }
  where
    metadataEntries = transactionMetadata block

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
