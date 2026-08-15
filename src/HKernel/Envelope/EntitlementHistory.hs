module HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistory
  , envelopeEntitlementHistoryTransfers
  , envelopeEntitlementHistoryOrigins
  , envelopeEntitlementHistoryOriginFor
  , EnvelopeEntitlementHistoryError(..)
  , mkEnvelopeEntitlementHistory
  , mkEnvelopeEntitlementHistoryWithOrigins
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

-- | Native Entitlement history together with the opening boundary of the
-- Envelope stock world for each Commodity.
--
-- A source adapter may know that the Envelope system existed before the first
-- transfer into a Spendable Envelope, for example because admitted opening or
-- unallocated movement evidence already existed. Keeping that boundary here
-- prevents report Periods or current policy from becoming retrospective stock
-- authority.
data EnvelopeEntitlementHistory = EnvelopeEntitlementHistory
  { envelopeEntitlementHistoryTransfers :: [EnvelopeEntitlementTransfer]
  , envelopeEntitlementHistoryOrigins   :: Map Commodity Day
  } deriving (Eq, Show)

data EnvelopeEntitlementHistoryError
  = EnvelopeEntitlementOriginMissing Commodity Day
  | EnvelopeEntitlementOriginAfterTransfer Commodity Day Day
  | EnvelopeEntitlementBecameNegative EnvelopeId Commodity Day Quantity
  deriving (Eq, Show)

-- | Lookup the native Envelope stock origin for one Commodity.
envelopeEntitlementHistoryOriginFor
  :: Commodity
  -> EnvelopeEntitlementHistory
  -> Maybe Day
envelopeEntitlementHistoryOriginFor commodity =
  Map.lookup commodity . envelopeEntitlementHistoryOrigins

-- | Construct a self-contained history when transfers are the only opening
-- evidence available. Each Commodity begins on its first transfer day.
--
-- Household production uses 'mkEnvelopeEntitlementHistoryWithOrigins' instead,
-- because the admitted Entitlement source can establish an earlier stock origin
-- with opening/unallocated movements that do not themselves create a native
-- Envelope transfer.
mkEnvelopeEntitlementHistory
  :: [EnvelopeEntitlementTransfer]
  -> Either (NonEmpty EnvelopeEntitlementHistoryError) EnvelopeEntitlementHistory
mkEnvelopeEntitlementHistory transfers =
  mkEnvelopeEntitlementHistoryWithOrigins inferredOrigins transfers
  where
    inferredOrigins = Map.fromListWith min
      [ ( amountCommodity (entitlementTransferAmount transfer)
        , entitlementTransferDate transfer
        )
      | transfer <- transfers
      ]

-- | Construct Entitlement history with an independently admitted stock opening
-- boundary. An origin-only Commodity is valid: routed Actual use after that day
-- may produce negative Remaining before the first grant. Every transfer must,
-- however, have an origin no later than its own effective day.
mkEnvelopeEntitlementHistoryWithOrigins
  :: Map Commodity Day
  -> [EnvelopeEntitlementTransfer]
  -> Either (NonEmpty EnvelopeEntitlementHistoryError) EnvelopeEntitlementHistory
mkEnvelopeEntitlementHistoryWithOrigins origins transfers =
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
          | origin <= transferDay -> []
          | otherwise ->
              [EnvelopeEntitlementOriginAfterTransfer commodity origin transferDay]
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
