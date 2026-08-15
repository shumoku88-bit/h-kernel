module HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , EnvelopeEntitlementTransfer
  , EnvelopeEntitlementTransferError(..)
  , mkEnvelopeEntitlementTransfer
  , entitlementTransferDate
  , entitlementTransferFrom
  , entitlementTransferTo
  , entitlementTransferAmount
  , entitlementTransferNote
  ) where

import Data.Text (Text)
import Data.Time.Calendar (Day)
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Money (Amount, amountQuantity, zeroQuantity)

data EnvelopeEndpoint
  = Unallocated
  | Spendable EnvelopeId
  deriving (Eq, Ord, Show)

data EnvelopeEntitlementTransfer = EnvelopeEntitlementTransfer
  { entitlementTransferDate   :: Day
  , entitlementTransferFrom   :: EnvelopeEndpoint
  , entitlementTransferTo     :: EnvelopeEndpoint
  , entitlementTransferAmount :: Amount
  , entitlementTransferNote   :: Text
  } deriving (Eq, Show)

data EnvelopeEntitlementTransferError
  = EntitlementTransferSameEndpoint EnvelopeEndpoint
  | EntitlementTransferAmountNotPositive Amount
  deriving (Eq, Show)

mkEnvelopeEntitlementTransfer
  :: Day
  -> EnvelopeEndpoint
  -> EnvelopeEndpoint
  -> Amount
  -> Text
  -> Either EnvelopeEntitlementTransferError EnvelopeEntitlementTransfer
mkEnvelopeEntitlementTransfer day fromEndpoint toEndpoint amount note
  | fromEndpoint == toEndpoint =
      Left (EntitlementTransferSameEndpoint fromEndpoint)
  | amountQuantity amount <= zeroQuantity =
      Left (EntitlementTransferAmountNotPositive amount)
  | otherwise = Right EnvelopeEntitlementTransfer
      { entitlementTransferDate = day
      , entitlementTransferFrom = fromEndpoint
      , entitlementTransferTo = toEndpoint
      , entitlementTransferAmount = amount
      , entitlementTransferNote = note
      }
