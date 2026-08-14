module HKernel.Envelope.FulfillmentRouting
  ( FulfillmentRoute(..)
  , FulfillmentRoutingDecision(..)
  , FulfillmentRoutingHistory
  , FulfillmentRoutingHistoryError(..)
  , FulfillmentRoutingReferenceError(..)
  , mkFulfillmentRoutingHistory
  , admitFulfillmentRoutingPlanReferences
  , fulfillmentRoutingHistoryDecisions
  , fulfillmentRoutingDecisionAt
  , fulfillmentRouteAt
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time.Calendar (Day)
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Plan (PlanId)

-- | Whether one stable Plan currently represents fulfillment of an Envelope.
--
-- Fulfillment intent belongs to the household decision represented by PlanId,
-- not to an accounting Account. The same savings, investment, or bank Account
-- may therefore appear in unrelated Plans without inheriting Envelope meaning.
--
-- A negative decision is explicit so later intent can stop treating a Plan as
-- an Envelope target without rewriting earlier observations.
data FulfillmentRoute
  = FulfillsEnvelope EnvelopeId
  | NotFulfillmentTarget
  deriving (Eq, Ord, Show)

data FulfillmentRoutingDecision = FulfillmentRoutingDecision
  { fulfillmentRoutingEffectiveFrom :: Day
  , fulfillmentRoutingPlanId        :: PlanId
  , fulfillmentRoutingRoute         :: FulfillmentRoute
  , fulfillmentRoutingNote          :: Text
  } deriving (Eq, Show)

newtype FulfillmentRoutingHistory = FulfillmentRoutingHistory
  { fulfillmentRoutingHistoryDecisions :: [FulfillmentRoutingDecision]
  } deriving (Eq, Show)

data FulfillmentRoutingHistoryError
  = DuplicateFulfillmentRoutingDecision PlanId Day
  deriving (Eq, Show)

-- | A source-admitted routing decision may still dangle across the Plan source
-- boundary. This error names the historical decision coordinate without
-- retaining any private source row.
data FulfillmentRoutingReferenceError
  = UnknownFulfillmentRoutingPlan PlanId Day
  deriving (Eq, Show)

mkFulfillmentRoutingHistory
  :: [FulfillmentRoutingDecision]
  -> Either (NonEmpty FulfillmentRoutingHistoryError) FulfillmentRoutingHistory
mkFulfillmentRoutingHistory decisions =
  case NonEmpty.nonEmpty duplicateErrors of
    Just errors -> Left errors
    Nothing -> Right (FulfillmentRoutingHistory decisions)
  where
    grouped = Map.fromListWith (+)
      [ ((fulfillmentRoutingPlanId decision, fulfillmentRoutingEffectiveFrom decision), 1 :: Int)
      | decision <- decisions
      ]
    duplicateErrors =
      [ DuplicateFulfillmentRoutingDecision planId effectiveFrom
      | ((planId, effectiveFrom), count) <- Map.toAscList grouped
      , count > 1
      ]

-- | Admit the Plan references of an already source-admitted routing history.
--
-- Plan existence is independent from current Plan lifecycle. A completed,
-- cancelled, or superseded historical Plan therefore remains a valid routing
-- coordinate as long as its stable PlanId belongs to the admitted Plan identity
-- universe supplied by the caller.
--
-- This boundary deliberately does not validate the Envelope target against
-- current TOML or infer an Envelope registry from entitlement activity. The
-- historical Envelope identity owner is a separate unresolved migration
-- question; using current policy here would silently rewrite old intent.
--
-- Errors accumulate in source order so every dangling Plan decision remains
-- visible to the caller.
admitFulfillmentRoutingPlanReferences
  :: [PlanId]
  -> FulfillmentRoutingHistory
  -> Either (NonEmpty FulfillmentRoutingReferenceError) FulfillmentRoutingHistory
admitFulfillmentRoutingPlanReferences knownPlans history =
  case NonEmpty.nonEmpty errors of
    Nothing -> Right history
    Just found -> Left found
  where
    known = Set.fromList knownPlans
    errors =
      [ UnknownFulfillmentRoutingPlan
          (fulfillmentRoutingPlanId decision)
          (fulfillmentRoutingEffectiveFrom decision)
      | decision <- fulfillmentRoutingHistoryDecisions history
      , fulfillmentRoutingPlanId decision `Set.notMember` known
      ]

fulfillmentRoutingDecisionAt
  :: Day
  -> PlanId
  -> FulfillmentRoutingHistory
  -> Maybe FulfillmentRoutingDecision
fulfillmentRoutingDecisionAt observedOn planId =
  foldl' laterDecision Nothing
    . filter visible
    . fulfillmentRoutingHistoryDecisions
  where
    visible decision =
      fulfillmentRoutingPlanId decision == planId
        && fulfillmentRoutingEffectiveFrom decision <= observedOn
    laterDecision Nothing decision = Just decision
    laterDecision (Just current) decision
      | fulfillmentRoutingEffectiveFrom decision
          > fulfillmentRoutingEffectiveFrom current = Just decision
      | otherwise = Just current

fulfillmentRouteAt
  :: Day
  -> PlanId
  -> FulfillmentRoutingHistory
  -> Maybe FulfillmentRoute
fulfillmentRouteAt observedOn planId =
  fmap fulfillmentRoutingRoute . fulfillmentRoutingDecisionAt observedOn planId
