-- | One atomic household decision that transfers Envelope entitlement.
--
-- This is not an accounting transaction and does not move Asset money. It only
-- records how much spendable entitlement is granted, returned, or moved between
-- Envelopes at one explicit historical period coordinate.
module HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , EnvelopeEntitlementTransfer
  , EnvelopeEntitlementTransferError(..)
  , mkEnvelopeEntitlementTransfer
  , entitlementTransferDate
  , entitlementTransferPeriod
  , entitlementTransferFrom
  , entitlementTransferTo
  , entitlementTransferAmount
  , entitlementTransferNote
  ) where

import Data.Text (Text)
import Data.Time.Calendar (Day)
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Money (Amount, amountQuantity, zeroQuantity)
import HKernel.Period (Period, periodContains)

-- | Either derived capacity that has not been granted to a spendable Envelope,
-- or one stable spendable Envelope identity.
data EnvelopeEndpoint
  = Unallocated
  | Spendable EnvelopeId
  deriving (Eq, Ord, Show)

-- | One provenance-bearing entitlement transfer.
--
-- The hidden constructor proves that the date belongs to the explicit period,
-- the endpoints differ, and the exact amount is strictly positive. Signed
-- compatibility sources can therefore normalize direction at their adapter
-- boundary instead of leaking signed transfer semantics into the native model.
data EnvelopeEntitlementTransfer = EnvelopeEntitlementTransfer
  { entitlementTransferDate   :: Day
  , entitlementTransferPeriod :: Period
  , entitlementTransferFrom   :: EnvelopeEndpoint
  , entitlementTransferTo     :: EnvelopeEndpoint
  , entitlementTransferAmount :: Amount
  , entitlementTransferNote   :: Text
  } deriving (Eq, Show)

data EnvelopeEntitlementTransferError
  = EntitlementTransferOutsidePeriod Day Period
  | EntitlementTransferSameEndpoint EnvelopeEndpoint
  | EntitlementTransferAmountNotPositive Amount
  deriving (Eq, Show)

mkEnvelopeEntitlementTransfer
  :: Day
  -> Period
  -> EnvelopeEndpoint
  -> EnvelopeEndpoint
  -> Amount
  -> Text
  -> Either EnvelopeEntitlementTransferError EnvelopeEntitlementTransfer
mkEnvelopeEntitlementTransfer day period fromEndpoint toEndpoint amount note
  | not (periodContains period day) =
      Left (EntitlementTransferOutsidePeriod day period)
  | fromEndpoint == toEndpoint =
      Left (EntitlementTransferSameEndpoint fromEndpoint)
  | amountQuantity amount <= zeroQuantity =
      Left (EntitlementTransferAmountNotPositive amount)
  | otherwise = Right EnvelopeEntitlementTransfer
      { entitlementTransferDate = day
      , entitlementTransferPeriod = period
      , entitlementTransferFrom = fromEndpoint
      , entitlementTransferTo = toEndpoint
      , entitlementTransferAmount = amount
      , entitlementTransferNote = note
      }
