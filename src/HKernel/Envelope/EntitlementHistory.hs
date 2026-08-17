module HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistory
  , envelopeEntitlementHistoryTransfers
  , envelopeEntitlementHistoryOrigins
  , envelopeEntitlementHistoryOriginFor
  , envelopeEntitlementHistoryOriginDateFor
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
import HKernel.Envelope.StockOrigin (StockOrigin(..))
import HKernel.Money
  ( Commodity
  , Quantity
  , addQuantity
  , amountCommodity
  , amountQuantity
  , negateQuantity
  , zeroQuantity
  )

-- | Native Entitlement history together with explicit StockOrigin evidence
-- for each Commodity.
data EnvelopeEntitlementHistory = EnvelopeEntitlementHistory
  { envelopeEntitlementHistoryTransfers :: [EnvelopeEntitlementTransfer]
  , envelopeEntitlementHistoryOrigins   :: Map Commodity StockOrigin
  } deriving (Eq, Show)

data EnvelopeEntitlementHistoryError
  = EnvelopeEntitlementOriginMissing Commodity Day
  | EnvelopeEntitlementOriginAfterTransfer Commodity Day Day
  | EnvelopeEntitlementBecameNegative EnvelopeId Commodity Day Quantity
  deriving (Eq, Show)

-- | Lookup the explicit StockOrigin for one Commodity.
envelopeEntitlementHistoryOriginFor
  :: Commodity
  -> EnvelopeEntitlementHistory
  -> Maybe StockOrigin
envelopeEntitlementHistoryOriginFor commodity =
  Map.lookup commodity . envelopeEntitlementHistoryOrigins

-- | Lookup the origin date for one Commodity.
envelopeEntitlementHistoryOriginDateFor
  :: Commodity
  -> EnvelopeEntitlementHistory
  -> Maybe Day
envelopeEntitlementHistoryOriginDateFor commodity =
  fmap stockOriginDate . envelopeEntitlementHistoryOriginFor commodity

-- | Construct Entitlement history with explicit StockOrigin evidence.
-- Every transfer must have an explicit StockOrigin no later than its own effective day.
mkEnvelopeEntitlementHistory
  :: Map Commodity StockOrigin
  -> [EnvelopeEntitlementTransfer]
  -> Either (NonEmpty EnvelopeEntitlementHistoryError) EnvelopeEntitlementHistory
mkEnvelopeEntitlementHistory origins transfers =
  case NonEmpty.nonEmpty errors of
    Just found -> Left found
    Nothing -> Right EnvelopeEntitlementHistory
      { envelopeEntitlementHistoryTransfers = transfers
      , envelopeEntitlementHistoryOrigins = origins
      }
  where
    errors = originErrors ++ concatMap check (Map.toAscList histories)

    originErrors = concatMap validateOrigin transfers
    validateOrigin transfer =
      case Map.lookup commodity origins of
        Nothing -> [EnvelopeEntitlementOriginMissing commodity transferDay]
        Just origin
          | stockOriginDate origin <= transferDay -> []
          | otherwise ->
              [EnvelopeEntitlementOriginAfterTransfer commodity (stockOriginDate origin) transferDay]
      where
        commodity = amountCommodity (entitlementTransferAmount transfer)
        transferDay = entitlementTransferDate transfer

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
