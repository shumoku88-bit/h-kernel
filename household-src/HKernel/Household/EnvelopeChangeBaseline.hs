-- | Selection of the earlier observation used by same-Period Envelope Change.
--
-- Change arithmetic remains owned by 'HKernel.Household.EnvelopeObservation'.
-- This module owns only the temporal question "from which observation?" and
-- deliberately does not inspect journals or infer observation history.
module HKernel.Household.EnvelopeChangeBaseline
  ( EnvelopeChangeBaseline(..)
  , ResolvedEnvelopeChangeBaseline
  , EnvelopeChangeBaselineError(..)
  , resolveEnvelopeChangeBaseline
  , resolvedEnvelopeChangeBaseline
  , resolvedEnvelopeChangeBaselineDay
  ) where

import Data.Time.Calendar (Day, addDays)
import HKernel.Period
  ( Period
  , periodContains
  , periodStart
  )

-- | A semantic request for the earlier side of one same-Period Change.
--
-- 'PreviousObservation' is intentionally not derived from accounting evidence.
-- The caller must supply the previous observation day as separate context.
data EnvelopeChangeBaseline
  = PreviousObservation
  | PreviousDay
  | CycleStart
  | ExplicitDay Day
  deriving (Eq, Show)

-- | One baseline request after its temporal coordinate has been validated.
data ResolvedEnvelopeChangeBaseline = ResolvedEnvelopeChangeBaseline
  { resolvedEnvelopeChangeBaseline    :: EnvelopeChangeBaseline
  , resolvedEnvelopeChangeBaselineDay :: Day
  } deriving (Eq, Show)

-- | Baseline requests fail closed when they do not denote an earlier or equal
-- coordinate inside the same Period as the later observation.
data EnvelopeChangeBaselineError
  = EnvelopeChangeThroughOutsidePeriod Day Period
  | EnvelopeChangePreviousObservationUnavailable
  | EnvelopeChangePreviousObservationNotBefore Day Day
  | EnvelopeChangeBaselineDayOutsidePeriod EnvelopeChangeBaseline Day Period
  | EnvelopeChangeBaselineDayAfterObservation EnvelopeChangeBaseline Day Day
  deriving (Eq, Show)

-- | Resolve one semantic baseline request without reading canonical evidence.
--
-- The optional previous observation day belongs to the caller's observation
-- context (for example one TUI session or explicit observation history), never
-- to Actual/Plan/Envelope evidence. Explicit dates may equal the later day so a
-- caller can intentionally ask for a zero-length comparison. A named previous
-- observation must be strictly earlier because "previous" is itself semantic.
resolveEnvelopeChangeBaseline
  :: Period
  -> Day
  -> Maybe Day
  -> EnvelopeChangeBaseline
  -> Either EnvelopeChangeBaselineError ResolvedEnvelopeChangeBaseline
resolveEnvelopeChangeBaseline period through previousObservation baseline
  | not (periodContains period through) =
      Left (EnvelopeChangeThroughOutsidePeriod through period)
  | otherwise = case baseline of
      PreviousObservation -> case previousObservation of
        Nothing -> Left EnvelopeChangePreviousObservationUnavailable
        Just day -> do
          validateInside PreviousObservation day
          if day < through
            then resolved PreviousObservation day
            else Left (EnvelopeChangePreviousObservationNotBefore day through)
      PreviousDay -> do
        let day = addDays (-1) through
        validateInside PreviousDay day
        resolved PreviousDay day
      CycleStart ->
        resolved CycleStart (periodStart period)
      ExplicitDay day -> do
        validateInside baseline day
        if day <= through
          then resolved baseline day
          else Left (EnvelopeChangeBaselineDayAfterObservation baseline day through)
  where
    validateInside requested day
      | periodContains period day = Right ()
      | otherwise = Left
          (EnvelopeChangeBaselineDayOutsidePeriod requested day period)

    resolved requested day = Right ResolvedEnvelopeChangeBaseline
      { resolvedEnvelopeChangeBaseline = requested
      , resolvedEnvelopeChangeBaselineDay = day
      }
