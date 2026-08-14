module HKernel.Backing
  ( BackedEnvelopeClaim(..)
  , BackingPoolPosition
  , BackingPoolError(..)
  , deriveBackingPoolPosition
  , backingPoolPositionId
  , backingPoolEnvelopeClaims
  , backingPoolFundingBalance
  , backingPoolFundingCommitment
  , backingPoolGrossEnvelopeRequired
  , backingPoolAvailableEnvelopeRequired
  , backingPoolAvailableFunding
  , backingPoolGrossSurplus
  , backingPoolAvailableSurplus
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import HKernel.Backing.Identity (BackingPoolId)
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Money
  ( Balance
  , balanceEntries
  , balanceFromAmounts
  , mkAmount
  , subtractBalance
  , zeroQuantity
  )

-- | One already-resolved Envelope claim assigned to a BackingPool at the same
-- observation.
--
-- Remaining is the gross recorded claim after Actual consumption. Headroom is
-- the available claim after still-open Plan Expense commitment. The assignment
-- of this Envelope to this pool is intentionally resolved before it reaches this
-- arithmetic owner; current TOML is not an input here.
data BackedEnvelopeClaim = BackedEnvelopeClaim
  { backedEnvelopeId        :: EnvelopeId
  , backedEnvelopeRemaining :: Balance
  , backedEnvelopeHeadroom  :: Balance
  } deriving (Eq, Show)

-- | Pool-local funding and claim coordinates. The constructor is hidden so one
-- Envelope cannot silently be counted twice inside the same pool.
data BackingPoolPosition = BackingPoolPosition
  { backingPoolPositionId                :: BackingPoolId
  , backingPoolEnvelopeClaims            :: [BackedEnvelopeClaim]
  , backingPoolFundingBalance             :: Balance
  , backingPoolFundingCommitment          :: Balance
  , backingPoolGrossEnvelopeRequired      :: Balance
  , backingPoolAvailableEnvelopeRequired  :: Balance
  } deriving (Eq, Show)

data BackingPoolError
  = DuplicateBackedEnvelopeClaim BackingPoolId EnvelopeId
  deriving (Eq, Show)

-- | Build one pool-local position from already admitted facts.
--
-- Negative Remaining/Headroom is valid overspending evidence but never cancels
-- another Envelope's positive claim. Funding may itself be negative evidence.
-- A matching Plan can reduce both available funding and available Envelope claim
-- without being double-counted in the surplus formula.
deriveBackingPoolPosition
  :: BackingPoolId
  -> Balance
  -> Balance
  -> [BackedEnvelopeClaim]
  -> Either (NonEmpty BackingPoolError) BackingPoolPosition
deriveBackingPoolPosition pool funding fundingCommitment claims =
  case NonEmpty.nonEmpty duplicateErrors of
    Just errors -> Left errors
    Nothing -> Right BackingPoolPosition
      { backingPoolPositionId = pool
      , backingPoolEnvelopeClaims = claims
      , backingPoolFundingBalance = funding
      , backingPoolFundingCommitment = fundingCommitment
      , backingPoolGrossEnvelopeRequired =
          foldMap (positiveBalance . backedEnvelopeRemaining) claims
      , backingPoolAvailableEnvelopeRequired =
          foldMap (positiveBalance . backedEnvelopeHeadroom) claims
      }
  where
    counts = Map.fromListWith (+)
      [ (backedEnvelopeId claim, 1 :: Int)
      | claim <- claims
      ]
    duplicateErrors =
      [ DuplicateBackedEnvelopeClaim pool envelope
      | (envelope, count) <- Map.toAscList counts
      , count > 1
      ]

backingPoolAvailableFunding :: BackingPoolPosition -> Balance
backingPoolAvailableFunding pool =
  backingPoolFundingBalance pool
    `subtractBalance` backingPoolFundingCommitment pool

backingPoolGrossSurplus :: BackingPoolPosition -> Balance
backingPoolGrossSurplus pool =
  backingPoolFundingBalance pool
    `subtractBalance` backingPoolGrossEnvelopeRequired pool

backingPoolAvailableSurplus :: BackingPoolPosition -> Balance
backingPoolAvailableSurplus pool =
  backingPoolAvailableFunding pool
    `subtractBalance` backingPoolAvailableEnvelopeRequired pool

-- | Keep only positive commodity coordinates of one claim. This operation lives
-- in Backing rather than Money because "negative claim must not fund another
-- Envelope" is a Backing law, not a general monetary arithmetic law.
positiveBalance :: Balance -> Balance
positiveBalance balance = balanceFromAmounts
  [ mkAmount commodity quantity
  | (commodity, quantity) <- balanceEntries balance
  , quantity > zeroQuantity
  ]
