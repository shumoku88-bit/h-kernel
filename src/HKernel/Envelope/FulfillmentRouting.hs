module HKernel.Envelope.FulfillmentRouting
  ( FulfillmentRoute(..)
  , FulfillmentRoutingDecision(..)
  , FulfillmentRoutingHistory
  , FulfillmentRoutingHistoryError(..)
  , mkFulfillmentRoutingHistory
  , fulfillmentRoutingHistoryDecisions
  , fulfillmentRoutingDecisionAt
  , fulfillmentRouteAt
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
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
