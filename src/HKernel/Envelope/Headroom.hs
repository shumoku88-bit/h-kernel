module HKernel.Envelope.Headroom
  ( EnvelopeHeadroom
  , EnvelopeHeadroomError(..)
  , calculateEnvelopeHeadroom
  , envelopeHeadroomPeriod
  , envelopeHeadroomObservedThrough
  , envelopeHeadroomFor
  , envelopeHeadroomEntries
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time.Calendar (Day)
import HKernel.Envelope.Commitment
  ( EnvelopeCommitment
  , envelopeCommitmentEntries
  , envelopeCommitmentFor
  , envelopeCommitmentObservedThrough
  , envelopeCommitmentPeriod
  )
import HKernel.Envelope.Identity (EnvelopeId)
import HKernel.Envelope.Remaining
  ( EnvelopeRemaining
  , envelopeRemainingEntries
  , envelopeRemainingFor
  , envelopeRemainingObservedThrough
  , envelopeRemainingPeriod
  )
import HKernel.Money
  ( Balance
  , emptyBalance
  , isZeroBalance
  , subtractBalance
  )
import HKernel.Period (Period)

-- | Spendable Envelope capacity after both posted Actual consumption and still
-- open Plan Expense commitments.
data EnvelopeHeadroom = EnvelopeHeadroom
  { envelopeHeadroomPeriod          :: Period
  , envelopeHeadroomObservedThrough :: Day
  , headroomBalances                :: Map.Map EnvelopeId Balance
  } deriving (Eq, Show)

data EnvelopeHeadroomError
  = EnvelopeHeadroomPeriodMismatch Period Period
  | EnvelopeHeadroomObservationMismatch Day Day
  deriving (Eq, Show)

calculateEnvelopeHeadroom
  :: EnvelopeRemaining
  -> EnvelopeCommitment
  -> Either EnvelopeHeadroomError EnvelopeHeadroom
calculateEnvelopeHeadroom remaining commitment
  | remainingPeriod /= commitmentPeriod =
      Left (EnvelopeHeadroomPeriodMismatch remainingPeriod commitmentPeriod)
  | remainingDay /= commitmentDay =
      Left (EnvelopeHeadroomObservationMismatch remainingDay commitmentDay)
  | otherwise = Right EnvelopeHeadroom
      { envelopeHeadroomPeriod = remainingPeriod
      , envelopeHeadroomObservedThrough = remainingDay
      , headroomBalances = Map.fromList
          [ (envelope, headroomFor envelope)
          | envelope <- Set.toAscList coordinates
          , not (isZeroBalance (headroomFor envelope))
          ]
      }
  where
    remainingPeriod = envelopeRemainingPeriod remaining
    commitmentPeriod = envelopeCommitmentPeriod commitment
    remainingDay = envelopeRemainingObservedThrough remaining
    commitmentDay = envelopeCommitmentObservedThrough commitment
    coordinates = Set.fromList
      ( map fst (envelopeRemainingEntries remaining)
          ++ map fst (envelopeCommitmentEntries commitment)
      )
    headroomFor envelope =
      envelopeRemainingFor envelope remaining
        `subtractBalance` envelopeCommitmentFor envelope commitment

envelopeHeadroomFor :: EnvelopeId -> EnvelopeHeadroom -> Balance
envelopeHeadroomFor envelope =
  Map.findWithDefault emptyBalance envelope . headroomBalances

envelopeHeadroomEntries :: EnvelopeHeadroom -> [(EnvelopeId, Balance)]
envelopeHeadroomEntries = Map.toAscList . headroomBalances
