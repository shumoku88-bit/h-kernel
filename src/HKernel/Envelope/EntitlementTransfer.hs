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

data EnvelopeEndpoint
  = Unallocated
  | Spendable EnvelopeId
  deriving (Eq, Ord, Show)

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
