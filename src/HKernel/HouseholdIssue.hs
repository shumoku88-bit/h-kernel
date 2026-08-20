{-# LANGUAGE OverloadedStrings #-}

-- | User-authored household matters that remain outside accounting calculations.
--
-- A Household Issue may mention a possible payment, amount, or due date, but it
-- is not a Journal fact, Plan commitment, BudgetChange, or diagnostic. It changes
-- no balance or budget result by itself.
module HKernel.HouseholdIssue
  ( IssueId
  , IssueIdError(..)
  , mkIssueId
  , issueIdText
  , IssueStatus(..)
  , IssueDue(..)
  , IssueClosed(..)
  , HouseholdIssue
  , HouseholdIssueError(..)
  , mkHouseholdIssue
  , mkHouseholdIssueWithClosed
  , householdIssueId
  , householdIssueRecordedOn
  , householdIssueStatus
  , householdIssueDue
  , householdIssueClosed
  , householdIssueAmount
  , householdIssueText
  , householdIssueDetails
  , IssueRelationEventId
  , IssueRelationEventIdError(..)
  , mkIssueRelationEventId
  , issueRelationEventIdText
  , IssueRelation(..)
  , IssueRelationEvent
  , IssueRelationEventError(..)
  , mkIssueRelationEvent
  , issueRelationEventId
  , issueRelationRecordedOn
  , issueRelationIssueId
  , issueRelationMeaning
  , issueRelationDetails
  , IssueRelationReferenceError(..)
  , admitIssueRelationReferences
  ) where

import Data.Char (isControl, isSpace)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import HKernel.Money (Amount)
import HKernel.Plan (PlanId)
import HKernel.Plan.Completion (ActualTransactionId)

-- | Stable machine identity used to update or resolve one issue safely.
newtype IssueId = IssueId { issueIdText :: Text }
  deriving (Eq, Ord, Show)

data IssueIdError
  = EmptyIssueId
  | IssueIdHasSurroundingWhitespace Text
  | IssueIdContainsControlCharacter Text
  | IssueIdContainsWhitespace Text
  deriving (Eq, Show)

mkIssueId :: Text -> Either IssueIdError IssueId
mkIssueId value
  | T.null value = Left EmptyIssueId
  | T.strip value /= value = Left (IssueIdHasSurroundingWhitespace value)
  | T.any isControl value = Left (IssueIdContainsControlCharacter value)
  | T.any isSpace value = Left (IssueIdContainsWhitespace value)
  | otherwise = Right (IssueId value)

-- | Whether the household matter still needs attention.
--
-- 'Dropped' is distinct from 'Resolved': it records that the matter is no
-- longer being pursued without claiming that the underlying matter was solved.
data IssueStatus
  = Open
  | Resolved
  | Dropped
  deriving (Eq, Ord, Show)

-- | Time meaning for one Issue, independent from its category and lifecycle.
--
-- 'NoDueDate' explicitly records that the matter has no deadline.
-- 'DueUndetermined' records that a due date is not yet known. These are not the
-- same meaning: a Want may have no deadline until a later opportunity creates
-- one, while another matter may be waiting for its deadline to be determined.
data IssueDue
  = DueOn Day
  | NoDueDate
  | DueUndetermined
  deriving (Eq, Ord, Show)

-- | Closure-time evidence, independent from the due coordinate.
--
-- 'NotClosed' is the positive lifecycle meaning for an open Issue.
-- 'ClosedUndetermined' preserves historical closed Issues whose older source
-- shape carried status but no closure date. New close operations on the current
-- source record 'ClosedOn' explicitly instead of rewriting missing history.
data IssueClosed
  = ClosedOn Day
  | NotClosed
  | ClosedUndetermined
  deriving (Eq, Ord, Show)

-- | One small household notebook entry.
--
-- Text is the matter itself. Details retain its short household context. Amount
-- is optional because some matters are not monetary; when present it remains an
-- exact single-commodity Amount.
data HouseholdIssue = HouseholdIssue
  { householdIssueId         :: IssueId
  , householdIssueRecordedOn :: Day
  , householdIssueStatus     :: IssueStatus
  , householdIssueDue        :: IssueDue
  , householdIssueClosed     :: IssueClosed
  , householdIssueAmount     :: Maybe Amount
  , householdIssueText       :: Text
  , householdIssueDetails    :: Text
  } deriving (Eq, Show)

data HouseholdIssueError
  = EmptyHouseholdIssueText
  | HouseholdIssueTextHasSurroundingWhitespace Text
  | HouseholdIssueTextContainsControlCharacter Text
  | HouseholdIssueDetailsHasSurroundingWhitespace Text
  | HouseholdIssueDetailsContainsControlCharacter Text
  | OpenHouseholdIssueHasClosureEvidence IssueClosed
  | ClosedHouseholdIssueHasNoClosureEvidence IssueStatus
  | HouseholdIssueClosedBeforeRecorded Day Day
  deriving (Eq, Show)

-- | Compatibility constructor for callers that predate the explicit closure
-- coordinate. Open Issues are known not closed; already closed Issues retain
-- missing historical closure evidence as 'ClosedUndetermined'.
mkHouseholdIssue
  :: IssueId
  -> Day
  -> IssueStatus
  -> IssueDue
  -> Maybe Amount
  -> Text
  -> Text
  -> Either HouseholdIssueError HouseholdIssue
mkHouseholdIssue issueId recordedOn status due amount text details =
  mkHouseholdIssueWithClosed
    issueId recordedOn status due compatibilityClosed amount text details
  where
    compatibilityClosed = case status of
      Open -> NotClosed
      Resolved -> ClosedUndetermined
      Dropped -> ClosedUndetermined

-- | Construct one Issue with explicit recorded, due, and closure time meaning.
-- Status and closure evidence must agree, and a known closure date cannot
-- precede the recorded date.
mkHouseholdIssueWithClosed
  :: IssueId
  -> Day
  -> IssueStatus
  -> IssueDue
  -> IssueClosed
  -> Maybe Amount
  -> Text
  -> Text
  -> Either HouseholdIssueError HouseholdIssue
mkHouseholdIssueWithClosed issueId recordedOn status due closed amount text details
  | T.null text = Left EmptyHouseholdIssueText
  | T.strip text /= text =
      Left (HouseholdIssueTextHasSurroundingWhitespace text)
  | T.any isControl text =
      Left (HouseholdIssueTextContainsControlCharacter text)
  | T.strip details /= details =
      Left (HouseholdIssueDetailsHasSurroundingWhitespace details)
  | T.any isControl details =
      Left (HouseholdIssueDetailsContainsControlCharacter details)
  | status == Open && closed /= NotClosed =
      Left (OpenHouseholdIssueHasClosureEvidence closed)
  | status /= Open && closed == NotClosed =
      Left (ClosedHouseholdIssueHasNoClosureEvidence status)
  | ClosedOn closedOn <- closed
  , closedOn < recordedOn =
      Left (HouseholdIssueClosedBeforeRecorded recordedOn closedOn)
  | otherwise = Right HouseholdIssue
      { householdIssueId = issueId
      , householdIssueRecordedOn = recordedOn
      , householdIssueStatus = status
      , householdIssueDue = due
      , householdIssueClosed = closed
      , householdIssueAmount = amount
      , householdIssueText = text
      , householdIssueDetails = details
      }

-- | Durable identity for one historical Issue relation occurrence.
--
-- A relation event is its own evidence rather than mutable state on either the
-- Issue or the target. This lets later projections reconstruct a sequence such
-- as planned-as -> planning-withdrawn -> planned-as without deleting the earlier
-- household decision.
newtype IssueRelationEventId = IssueRelationEventId
  { issueRelationEventIdText :: Text
  } deriving (Eq, Ord, Show)

data IssueRelationEventIdError
  = EmptyIssueRelationEventId
  | IssueRelationEventIdHasSurroundingWhitespace Text
  | IssueRelationEventIdContainsControlCharacter Text
  | IssueRelationEventIdContainsWhitespace Text
  deriving (Eq, Show)

mkIssueRelationEventId
  :: Text
  -> Either IssueRelationEventIdError IssueRelationEventId
mkIssueRelationEventId value
  | T.null value = Left EmptyIssueRelationEventId
  | T.strip value /= value =
      Left (IssueRelationEventIdHasSurroundingWhitespace value)
  | T.any isControl value =
      Left (IssueRelationEventIdContainsControlCharacter value)
  | T.any isSpace value =
      Left (IssueRelationEventIdContainsWhitespace value)
  | otherwise = Right (IssueRelationEventId value)

-- | Narrow, typed meanings currently observed between one Issue and durable
-- Plan, Actual, or later Issue identities.
--
-- This deliberately does not model a universal graph. Target kinds remain
-- different constructors because planning, realization, funding, and a later
-- decision episode are different household facts. 'IssueContinuedAs' points
-- from the earlier Issue to a distinct later Issue without rewriting either
-- Issue's lifecycle evidence.
data IssueRelation
  = IssueConcernsPlan PlanId
  | IssuePlannedAs PlanId
  | IssuePlanningWithdrawn PlanId
  | IssueRealizedAs ActualTransactionId
  | IssueFundedBy ActualTransactionId
  | IssueContinuedAs IssueId
  deriving (Eq, Show)

-- | One append-only historical relation fact.
--
-- Recording a relation never changes Issue lifecycle by itself. In particular,
-- an Issue can remain Open after being planned and can be Resolved independently
-- from whether a relation target later changes lifecycle.
data IssueRelationEvent = IssueRelationEvent
  { issueRelationEventId    :: IssueRelationEventId
  , issueRelationRecordedOn :: Day
  , issueRelationIssueId    :: IssueId
  , issueRelationMeaning    :: IssueRelation
  , issueRelationDetails    :: Text
  } deriving (Eq, Show)

data IssueRelationEventError
  = IssueRelationDetailsHasSurroundingWhitespace
  | IssueRelationDetailsContainsControlCharacter
  | IssueRelationTargetsSameIssue IssueId
  deriving (Eq, Show)

mkIssueRelationEvent
  :: IssueRelationEventId
  -> Day
  -> IssueId
  -> IssueRelation
  -> Text
  -> Either IssueRelationEventError IssueRelationEvent
mkIssueRelationEvent eventId recordedOn issueId relation details
  | T.strip details /= details =
      Left IssueRelationDetailsHasSurroundingWhitespace
  | T.any isControl details =
      Left IssueRelationDetailsContainsControlCharacter
  | IssueContinuedAs targetIssueId <- relation
  , targetIssueId == issueId =
      Left (IssueRelationTargetsSameIssue issueId)
  | otherwise = Right IssueRelationEvent
      { issueRelationEventId = eventId
      , issueRelationRecordedOn = recordedOn
      , issueRelationIssueId = issueId
      , issueRelationMeaning = relation
      , issueRelationDetails = details
      }

-- | Cross-source identity failures for an already source-admitted relation.
--
-- These errors are deliberately relation-event-local: the event identity says
-- which historical assertion is dangling without retaining or echoing private
-- source rows.
data IssueRelationReferenceError
  = UnknownIssueRelationIssue IssueRelationEventId IssueId
  | UnknownIssueRelationIssueTarget IssueRelationEventId IssueId
  | UnknownIssueRelationPlanTarget IssueRelationEventId PlanId
  | UnknownIssueRelationActualTarget IssueRelationEventId ActualTransactionId
  deriving (Eq, Show)

-- | Admit relation references against already admitted identity universes.
--
-- This operation owns existence only. It does not inspect Plan lifecycle or
-- Issue status, so a historical or retired Plan remains a valid relation target
-- and @planning-withdrawn@ does not require retirement metadata. Likewise it
-- does not infer Actual identity from transaction resemblance, and an Issue
-- continuation does not require either Issue to have a particular status.
--
-- The Actual identity collection must contain only source-durable identities
-- chosen by the caller. In particular, rebuildable runtime identities created
-- only to support Plan completion are not relation-target evidence unless a
-- future source contract explicitly promotes them to durable source identity.
--
-- Errors accumulate in relation source order. A relation whose Issue and target
-- are both missing contributes both errors rather than silently selecting one.
admitIssueRelationReferences
  :: [IssueId]
  -> [PlanId]
  -> [ActualTransactionId]
  -> [IssueRelationEvent]
  -> Either (NonEmpty IssueRelationReferenceError) [IssueRelationEvent]
admitIssueRelationReferences knownIssues knownPlans durableActuals relations =
  case NonEmpty.nonEmpty (concatMap referenceErrors relations) of
    Nothing -> Right relations
    Just errors -> Left errors
  where
    issueSet = Set.fromList knownIssues
    planSet = Set.fromList knownPlans
    actualSet = Set.fromList durableActuals

    referenceErrors relation = issueErrors relation ++ targetErrors relation

    issueErrors relation =
      [ UnknownIssueRelationIssue
          (issueRelationEventId relation)
          (issueRelationIssueId relation)
      | issueRelationIssueId relation `Set.notMember` issueSet
      ]

    targetErrors relation = case issueRelationMeaning relation of
      IssueConcernsPlan planId -> planErrors relation planId
      IssuePlannedAs planId -> planErrors relation planId
      IssuePlanningWithdrawn planId -> planErrors relation planId
      IssueRealizedAs actualId -> actualErrors relation actualId
      IssueFundedBy actualId -> actualErrors relation actualId
      IssueContinuedAs targetIssueId -> issueTargetErrors relation targetIssueId

    issueTargetErrors relation targetIssueId =
      [ UnknownIssueRelationIssueTarget
          (issueRelationEventId relation)
          targetIssueId
      | targetIssueId `Set.notMember` issueSet
      ]

    planErrors relation planId =
      [ UnknownIssueRelationPlanTarget (issueRelationEventId relation) planId
      | planId `Set.notMember` planSet
      ]

    actualErrors relation actualId =
      [ UnknownIssueRelationActualTarget (issueRelationEventId relation) actualId
      | actualId `Set.notMember` actualSet
      ]
