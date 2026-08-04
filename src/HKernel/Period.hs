-- | A validated half-open observation window.
--
-- A 'Period' is not a recurring rule, a persisted cycle identity, or a claim
-- about how household history must be partitioned. It is only the resolved
-- temporal coordinate @[start, endExclusive)@ consumed by pure calculations.
module HKernel.Period
  ( Period
  , PeriodError(..)
  , mkPeriod
  , periodStart
  , periodEndExclusive
  , periodContains
  ) where

import Data.Time.Calendar (Day)

-- | One non-empty half-open interval @[start, endExclusive)@.
--
-- The constructor is hidden so calculations never receive an empty or backwards
-- observation window.
data Period = Period
  { periodStart        :: Day
  , periodEndExclusive :: Day
  } deriving (Eq, Ord, Show)

data PeriodError = PeriodDoesNotAdvance
  { invalidPeriodStart        :: Day
  , invalidPeriodEndExclusive :: Day
  } deriving (Eq, Show)

mkPeriod :: Day -> Day -> Either PeriodError Period
mkPeriod start endExclusive
  | start < endExclusive = Right (Period start endExclusive)
  | otherwise = Left (PeriodDoesNotAdvance start endExclusive)

periodContains :: Period -> Day -> Bool
periodContains period day =
  day >= periodStart period
    && day < periodEndExclusive period
