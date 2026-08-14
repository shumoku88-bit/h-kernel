-- | Validated history of atomic Envelope entitlement transfers.
--
-- Source order remains provenance. Admission evaluates effective dates and
-- rejects any history in which a spendable Envelope's cumulative entitlement
-- becomes negative at a period, commodity, and date coordinate. Unallocated is
-- deliberately not modeled as a stored balance here; Backing owns the question
-- of whether Asset funding supports granted Envelope claims.
module HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistory
  , envelopeEntitlementHistoryTransfers
  , EnvelopeEntitlementHistoryError(..)
  , mkEnvelopeEntitlementHistory
  ) where

import Data.List (find, mapAccumL)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day)
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , EnvelopeEntitlementTransfer
  , entitlementTransferAmount
  , entitlementTransferDate
  , entitlementTransferFrom
  , entitlementTransferPeriod
  , entitlementTransferTo
  )
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Money
  ( Commodity
  , Quantity
  , addQuantity
  , amountCommodity
  , amountQuantity
  , negateQuantity
  , zeroQuantity
  )
import HKernel.Period (Period)

newtype EnvelopeEntitlementHistory = EnvelopeEntitlementHistory
  { envelopeEntitlementHistoryTransfers :: [EnvelopeEntitlementTransfer]
  } deriving (Eq, Show)

data EnvelopeEntitlementHistoryError
  = EnvelopeEntitlementBecameNegative
      Period
      EnvelopeId
      Commodity
      Day
      Quantity
  deriving (Eq, Show)

-- | Admit one coherent entitlement history.
--
-- Transfers are evaluated by effective date rather than source order. Every
-- spendable endpoint contributes one signed delta, and all deltas on the same
-- date are combined before cumulative entitlement is checked.
mkEnvelopeEntitlementHistory
  :: [EnvelopeEntitlementTransfer]
  -> Either (NonEmpty EnvelopeEntitlementHistoryError) EnvelopeEntitlementHistory
mkEnvelopeEntitlementHistory transfers =
  case NonEmpty.nonEmpty historyErrors of
    Just errors -> Left errors
    Nothing     -> Right (EnvelopeEntitlementHistory transfers)
  where
    historyErrors = concatMap validateCoordinate (Map.toAscList histories)
    histories = Map.fromListWith (Map.unionWith addQuantity)
      [ ( coordinate
        , Map.singleton day delta
        )
      | transfer <- transfers
      , let amount = entitlementTransferAmount transfer
      , let day = entitlementTransferDate transfer
      , (envelope, delta) <- endpointDeltas transfer
      , let coordinate =
              ( entitlementTransferPeriod transfer
              , envelope
              , amountCommodity amount
              )
      ]

    endpointDeltas transfer =
      fromDelta (entitlementTransferFrom transfer)
        ++ toDelta (entitlementTransferTo transfer)
      where
        quantity = amountQuantity (entitlementTransferAmount transfer)
        fromDelta endpoint = case endpoint of
          Unallocated -> []
          Spendable envelope -> [(envelope, negateQuantity quantity)]
        toDelta endpoint = case endpoint of
          Unallocated -> []
          Spendable envelope -> [(envelope, quantity)]

    validateCoordinate ((period, envelope, commodity), datedChanges) =
      case firstNegative datedChanges of
        Nothing -> []
        Just (day, quantity) ->
          [ EnvelopeEntitlementBecameNegative
              period
              envelope
              commodity
              day
              quantity
          ]

firstNegative :: Map Day Quantity -> Maybe (Day, Quantity)
firstNegative =
  find ((< zeroQuantity) . snd)
    . snd
    . mapAccumL accumulate zeroQuantity
    . Map.toAscList
  where
    accumulate running (day, delta) =
      let next = addQuantity running delta
      in (next, (day, next))
