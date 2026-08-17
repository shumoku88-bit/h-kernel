{-# LANGUAGE OverloadedStrings #-}

-- | Coordinated candidate preparation for an Issue that is realized by one
-- newly recorded Actual transaction.
--
-- The operation does not infer a relation from dates, amounts, descriptions,
-- or Account shape. It creates the Actual and its durable identity together,
-- records one explicit 'IssueRealizedAs' relation to that exact identity, and
-- resolves the Issue as a separate lifecycle fact. All three complete candidate
-- sources are admitted before publication is allowed to begin.
module HKernel.Editor.IssueRealize
  ( IssueRealizeIntent(..)
  , IssueRealizeError(..)
  , IssueRealizePreview(..)
  , IssueRelationHouseholdAdmissionError(..)
  , admitIssueRelationSource
  , prepareIssueRealize
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)

import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalIdentifiedTransactions
  , actualJournalTransactionEntries
  , actualJournalValue
  , actualTransactionEntrySource
  )
import qualified HKernel.Editor.ActualAppend as ActualAppend
import HKernel.Editor.IssueAppend
  ( IssueCloseDisposition(..)
  , IssueCloseError
  , IssueCloseIntent(..)
  , closeCandidateCompleteSource
  , closeCandidateRow
  , prepareIssueCloseOn
  )
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Household.Issue.Relation.TSV
  ( IssueRelationTSVError
  , issueRelationHeader
  , parseIssueRelations
  , renderIssueRelations
  )
import HKernel.Household.Issue.TSV
  ( HouseholdIssueTSVError
  , parseHouseholdIssues
  )
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueId
  , IssueRelation(..)
  , IssueRelationEvent
  , IssueRelationEventError
  , IssueRelationEventId
  , IssueRelationEventIdError
  , IssueRelationReferenceError
  , IssueStatus(..)
  , admitIssueRelationReferences
  , householdIssueId
  , householdIssueRecordedOn
  , householdIssueStatus
  , issueIdText
  , issueRelationEventId
  , issueRelationEventIdText
  , mkIssueRelationEvent
  , mkIssueRelationEventId
  )
import HKernel.Journal
  ( journalMetadataKey
  , journalMetadataValue
  , journalTransactionSourceMetadata
  )
import HKernel.Plan.Journal
  ( PlanJournal
  , identifiedPlanId
  , planJournalTransactions
  )
import HKernel.Plan.Completion
  ( ActualTransactionId
  , ActualTransactionIdError
  , actualTransactionIdText
  , identifiedActualId
  , mkActualTransactionId
  )

-- | One household decision to turn an open Issue into explicit Actual evidence.
--
-- The Actual date belongs to 'realizeActualIntent'. @recordedOn@ is when the
-- relation assertion was recorded, and @closedOn@ is Issue lifecycle evidence;
-- the coordinates are kept separate so a backdated Actual never rewrites when
-- the household learned or recorded the relation.
data IssueRealizeIntent = IssueRealizeIntent
  { realizeIssueId      :: IssueId
  , realizeRecordedOn   :: Day
  , realizeClosedOn     :: Day
  , realizeActualIntent :: ActualAppend.ActualEditIntent
  , realizeDecisionMemo :: Text
  } deriving (Eq, Show)

data IssueRealizeError
  = RealizeIssueSourceError (NonEmpty HouseholdIssueTSVError)
  | RealizeRelationSourceError (NonEmpty IssueRelationTSVError)
  | RealizeIssueNotFound IssueId
  | RealizeIssueNotOpen IssueStatus
  | RealizeRelationBeforeIssueRecorded Day Day
  | RealizeCloseBeforeRelation Day Day
  | RealizeActualMetadataOwnsEventId
  | RealizeActualIdentityError ActualTransactionIdError
  | RealizeActualCandidateError ActualAppend.ActualEditError
  | RealizeRelationEventIdError IssueRelationEventIdError
  | RealizeRelationEventError IssueRelationEventError
  | RealizeRelationReferenceError IssueRelationReferenceError
  | RealizeRelationCandidateSourceError (NonEmpty IssueRelationTSVError)
  | RealizeIssueCloseError IssueCloseError
  deriving (Eq, Show)

data IssueRealizePreview = IssueRealizePreview
  { realizedActualId                :: ActualTransactionId
  , realizedRelationEventId         :: IssueRelationEventId
  , realizedActualBlock             :: Text
  , realizedRelationBlock           :: Text
  , realizedIssueBlock              :: Text
  , realizedActualCandidateSource   :: Text
  , realizedRelationCandidateSource :: Text
  , realizedIssuesCandidateSource   :: Text
  } deriving (Eq, Show)

-- | Source-level relation admission against one already admitted Household.
--
-- Only explicit source-durable Actual @event-id@ coordinates are admitted as
-- relation targets. Plan-derived runtime identities are deliberately excluded.
data IssueRelationHouseholdAdmissionError
  = IssueRelationAdmissionSourceError (NonEmpty IssueRelationTSVError)
  | IssueRelationAdmissionReferenceError IssueRelationReferenceError
  deriving (Eq, Show)

admitIssueRelationSource
  :: ActualJournal
  -> PlanJournal
  -> [HouseholdIssue]
  -> Text
  -> Either (NonEmpty IssueRelationHouseholdAdmissionError) [IssueRelationEvent]
admitIssueRelationSource actualJournal planJournal issues source = do
  relations <- first (pure . IssueRelationAdmissionSourceError)
    (parseIssueRelations source)
  first (fmap IssueRelationAdmissionReferenceError)
    (admitIssueRelationReferences
      (map householdIssueId issues)
      (map identifiedPlanId (planJournalTransactions planJournal))
      (sourceDurableActualIds actualJournal)
      relations)

-- | Prepare the three complete sources for one explicit Issue realization.
--
-- The supplied Actual and Plan journals must come from the same admitted
-- Household observation as the supplied root source texts. Existing relation
-- references are rechecked together with the new relation, and the new Actual
-- identity participates only because this operation writes an explicit
-- @event-id@ into the candidate Actual block.
prepareIssueRealize
  :: ActualJournal
  -> PlanJournal
  -> Text
  -> Text
  -> Text
  -> IssueRealizeIntent
  -> Either (NonEmpty IssueRealizeError) IssueRealizePreview
prepareIssueRealize actualJournal planJournal actualSource relationSource issuesSource intent = do
  issues <- first (pure . RealizeIssueSourceError)
    (parseHouseholdIssues issuesSource)
  relations <- first (pure . RealizeRelationSourceError)
    (parseIssueRelations relationSource)
  target <- maybe
    (Left (pure (RealizeIssueNotFound (realizeIssueId intent))))
    Right
    (findIssue (realizeIssueId intent) issues)
  case householdIssueStatus target of
    Open -> Right ()
    status -> Left (pure (RealizeIssueNotOpen status))
  if realizeRecordedOn intent < householdIssueRecordedOn target
    then Left (pure (RealizeRelationBeforeIssueRecorded
      (householdIssueRecordedOn target) (realizeRecordedOn intent)))
    else Right ()
  if realizeClosedOn intent < realizeRecordedOn intent
    then Left (pure (RealizeCloseBeforeRelation
      (realizeRecordedOn intent) (realizeClosedOn intent)))
    else Right ()
  if any ((== "event-id") . T.toCaseFold . fst)
      (ActualAppend.intentMetadata (realizeActualIntent intent))
    then Left (pure RealizeActualMetadataOwnsEventId)
    else Right ()

  actualId <- first (pure . RealizeActualIdentityError)
    (generateActualId
      (realizeIssueId intent)
      (map identifiedActualId (actualJournalIdentifiedTransactions actualJournal)))
  let actualIntent = (realizeActualIntent intent)
        { ActualAppend.intentMetadata =
            ("event-id", actualTransactionIdText actualId)
              : ActualAppend.intentMetadata (realizeActualIntent intent)
        }
  actualPreview <- first (fmap RealizeActualCandidateError)
    (ActualAppend.prepareActualAppendFromResolvedJournal
      (actualJournalValue actualJournal)
      actualSource
      actualIntent)

  relationEventId <- first (pure . RealizeRelationEventIdError)
    (generateRelationEventId actualId relations)
  relation <- first (pure . RealizeRelationEventError)
    (mkIssueRelationEvent
      relationEventId
      (realizeRecordedOn intent)
      (realizeIssueId intent)
      (IssueRealizedAs actualId)
      (realizeDecisionMemo intent))
  let relationBlock = renderedRelationRow relation
      relationCandidate = appendRelation relationSource relationBlock
      candidateRelations = relations ++ [relation]
      knownIssues = map householdIssueId issues
      knownPlans = map identifiedPlanId (planJournalTransactions planJournal)
      knownDurableActuals = sourceDurableActualIds actualJournal ++ [actualId]
  _ <- first (fmap RealizeRelationReferenceError)
    (admitIssueRelationReferences
      knownIssues knownPlans knownDurableActuals candidateRelations)
  parsedCandidateRelations <- first (pure . RealizeRelationCandidateSourceError)
    (parseIssueRelations relationCandidate)
  _ <- first (fmap RealizeRelationReferenceError)
    (admitIssueRelationReferences
      knownIssues knownPlans knownDurableActuals parsedCandidateRelations)

  closePreview <- first (fmap RealizeIssueCloseError)
    (prepareIssueCloseOn
      issuesSource
      (realizeClosedOn intent)
      IssueCloseIntent
        { closeIssueId = realizeIssueId intent
        , closeDisposition = ResolveIssue
        , closeDecisionMemo = realizeDecisionMemo intent
        })

  pure IssueRealizePreview
    { realizedActualId = actualId
    , realizedRelationEventId = relationEventId
    , realizedActualBlock = ActualAppend.candidateBlock actualPreview
    , realizedRelationBlock = relationBlock
    , realizedIssueBlock = closeCandidateRow closePreview
    , realizedActualCandidateSource = ActualAppend.candidateCompleteSource actualPreview
    , realizedRelationCandidateSource = relationCandidate
    , realizedIssuesCandidateSource = closeCandidateCompleteSource closePreview
    }

findIssue :: IssueId -> [HouseholdIssue] -> Maybe HouseholdIssue
findIssue target = go
  where
    go [] = Nothing
    go (issue : rest)
      | householdIssueId issue == target = Just issue
      | otherwise = go rest

generateActualId
  :: IssueId
  -> [ActualTransactionId]
  -> Either ActualTransactionIdError ActualTransactionId
generateActualId issueId existing = go (1 :: Int)
  where
    occupied = Set.fromList (map actualTransactionIdText existing)
    base = issueIdText issueId <> "-actual"
    go index = do
      let candidateText
            | index == 1 = base
            | otherwise = base <> "-" <> T.pack (show index)
      candidate <- mkActualTransactionId candidateText
      if candidateText `Set.member` occupied
        then go (index + 1)
        else Right candidate

generateRelationEventId
  :: ActualTransactionId
  -> [IssueRelationEvent]
  -> Either IssueRelationEventIdError IssueRelationEventId
generateRelationEventId actualId existing = go (1 :: Int)
  where
    occupied = Set.fromList
      (map (issueRelationEventIdText . issueRelationEventId) existing)
    base = actualTransactionIdText actualId <> "-realized"
    go index = do
      let candidateText
            | index == 1 = base
            | otherwise = base <> "-" <> T.pack (show index)
      candidate <- mkIssueRelationEventId candidateText
      if candidateText `Set.member` occupied
        then go (index + 1)
        else Right candidate

sourceDurableActualIds :: ActualJournal -> [ActualTransactionId]
sourceDurableActualIds =
  mapMaybe durableId . actualJournalTransactionEntries
  where
    durableId entry = case
        [ journalMetadataValue metadata
        | metadata <- journalTransactionSourceMetadata
            (actualTransactionEntrySource entry)
        , T.toCaseFold (journalMetadataKey metadata) == "event-id"
        ] of
      [value] -> either (const Nothing) Just (mkActualTransactionId value)
      _ -> Nothing

renderedRelationRow :: IssueRelationEvent -> Text
renderedRelationRow relation =
  case T.lines (renderIssueRelations [relation]) of
    _header : row : _ -> row
    _ -> error "renderIssueRelations did not render one relation row"

appendRelation :: Text -> Text -> Text
appendRelation existing row =
  appendSourceBlock existing (SourceBlock block)
  where
    hasHeader = case meaningfulLines existing of
      (_, firstLine) : _ -> firstLine == issueRelationHeader
      [] -> False
    block
      | hasHeader = row
      | otherwise = issueRelationHeader <> "\n" <> row <> "\n"

meaningfulLines :: Text -> [(Int, Text)]
meaningfulLines =
  filter (not . ignored . snd) . zip [1..] . T.lines
  where
    ignored line =
      let stripped = T.strip line
      in T.null stripped || "#" `T.isPrefixOf` stripped
