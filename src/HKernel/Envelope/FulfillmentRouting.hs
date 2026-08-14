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

import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time.Calendar (Day)
import HKernel.Account (Account)
import HKernel.Envelope.Identity (EnvelopeId)

-- | Whether one non-Expense target account currently fulfills an Envelope.
--
-- A negative decision is explicit so a later policy change can stop treating a
-- former savings/investment/debt target as Envelope fulfillment without
-- rewriting earlier observations.
data FulfillmentRoute
  = FulfillsEnvelope EnvelopeId
  | NotFulfillmentTarget
  deriving (Eq, Ord, Show)

data FulfillmentRoutingDecision = FulfillmentRoutingDecision
  { fulfillmentRoutingEffectiveFrom :: Day
  , fulfillmentRoutingAccount       :: Account
  , fulfillmentRoutingRoute         :: FulfillmentRoute
  , fulfillmentRoutingNote          :: Text
  } deriving (Eq, Show)

newtype FulfillmentRoutingHistory = FulfillmentRoutingHistory
  { fulfillmentRoutingHistoryDecisions :: [FulfillmentRoutingDecision]
  } deriving (Eq, Show)

data FulfillmentRoutingHistoryError
  = DuplicateFulfillmentRoutingDecision Account Day
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
      [ ((fulfillmentRoutingAccount decision, fulfillmentRoutingEffectiveFrom decision), 1 :: Int)
      | decision <- decisions
      ]
    duplicateErrors =
      [ DuplicateFulfillmentRoutingDecision account effectiveFrom
      | ((account, effectiveFrom), count) <- Map.toAscList grouped
      , count > 1
      ]

fulfillmentRoutingDecisionAt
  :: Day
  -> Account
  -> FulfillmentRoutingHistory
  -> Maybe FulfillmentRoutingDecision
fulfillmentRoutingDecisionAt observedOn account =
  foldl' laterDecision Nothing
    . filter visible
    . fulfillmentRoutingHistoryDecisions
  where
    visible decision =
      fulfillmentRoutingAccount decision == account
        && fulfillmentRoutingEffectiveFrom decision <= observedOn
    laterDecision Nothing decision = Just decision
    laterDecision (Just current) decision
      | fulfillmentRoutingEffectiveFrom decision
          > fulfillmentRoutingEffectiveFrom current = Just decision
      | otherwise = Just current

fulfillmentRouteAt
  :: Day
  -> Account
  -> FulfillmentRoutingHistory
  -> Maybe FulfillmentRoute
fulfillmentRouteAt observedOn account =
  fmap fulfillmentRoutingRoute . fulfillmentRoutingDecisionAt observedOn account
