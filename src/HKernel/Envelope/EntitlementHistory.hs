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

newtype EnvelopeEntitlementHistory = EnvelopeEntitlementHistory
  { envelopeEntitlementHistoryTransfers :: [EnvelopeEntitlementTransfer]
  } deriving (Eq, Show)

data EnvelopeEntitlementHistoryError
  = EnvelopeEntitlementBecameNegative EnvelopeId Commodity Day Quantity
  deriving (Eq, Show)

mkEnvelopeEntitlementHistory
  :: [EnvelopeEntitlementTransfer]
  -> Either (NonEmpty EnvelopeEntitlementHistoryError) EnvelopeEntitlementHistory
mkEnvelopeEntitlementHistory transfers =
  case NonEmpty.nonEmpty errors of
    Just found -> Left found
    Nothing -> Right (EnvelopeEntitlementHistory transfers)
  where
    errors = concatMap check (Map.toAscList histories)
    histories = Map.fromListWith (Map.unionWith addQuantity)
      [ ( ( envelope
          , amountCommodity amount
          )
        , Map.singleton (entitlementTransferDate transfer) delta
        )
      | transfer <- transfers
      , let amount = entitlementTransferAmount transfer
      , (envelope, delta) <- deltas transfer
      ]

    deltas transfer = sourceDelta ++ destinationDelta
      where
        quantity = amountQuantity (entitlementTransferAmount transfer)
        sourceDelta = case entitlementTransferFrom transfer of
          Unallocated -> []
          Spendable envelope -> [(envelope, negateQuantity quantity)]
        destinationDelta = case entitlementTransferTo transfer of
          Unallocated -> []
          Spendable envelope -> [(envelope, quantity)]

    check ((envelope, commodity), dated) =
      case firstBelowZero dated of
        Nothing -> []
        Just (effectiveDay, quantity) ->
          [EnvelopeEntitlementBecameNegative
            envelope commodity effectiveDay quantity]

firstBelowZero :: Map Day Quantity -> Maybe (Day, Quantity)
firstBelowZero =
  find ((< zeroQuantity) . snd)
    . snd
    . mapAccumL step zeroQuantity
    . Map.toAscList
  where
    step running (effectiveDay, delta) =
      let next = addQuantity running delta
      in (next, (effectiveDay, next))
