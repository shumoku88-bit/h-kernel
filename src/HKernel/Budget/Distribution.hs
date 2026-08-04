-- | Exact routing policy from one Expense account into one or more envelopes.
--
-- This module owns relative allocation structure only. It does not divide a
-- monetary quantity, choose a commodity quantum, or decide who receives a
-- remainder. Those are later apportionment concerns.
module HKernel.Budget.Distribution
  ( DistributionWeight
  , unitDistributionWeight
  , distributionWeightValue
  , EnvelopeShare
  , envelopeShareEnvelope
  , envelopeShareWeight
  , ExpenseDistribution
  , wholeExpenseDistribution
  , expenseDistributionShares
  ) where

import Data.List.NonEmpty (NonEmpty(..))
import HKernel.Budget (EnvelopeId)
import Numeric.Natural (Natural)

-- | Positive relative weight inside one expense distribution.
--
-- The first policy language can only construct the unit weight. A later
-- weighted-policy slice may add a validated public constructor without changing
-- consumers of 'ExpenseDistribution'.
newtype DistributionWeight = DistributionWeight
  { distributionWeightValue :: Natural
  } deriving (Eq, Ord, Show)

unitDistributionWeight :: DistributionWeight
unitDistributionWeight = DistributionWeight 1

-- | One envelope coordinate and its relative share of an Expense posting.
data EnvelopeShare = EnvelopeShare
  { envelopeShareEnvelope :: EnvelopeId
  , envelopeShareWeight   :: DistributionWeight
  } deriving (Eq, Show)

-- | A non-empty routing policy for one Expense account.
--
-- The constructor is hidden. Current policy decoding creates only a singleton
-- distribution with weight one, while the representation already permits a
-- later exact weighted distribution.
newtype ExpenseDistribution = ExpenseDistribution
  { expenseDistributionShares :: NonEmpty EnvelopeShare
  } deriving (Eq, Show)

wholeExpenseDistribution :: EnvelopeId -> ExpenseDistribution
wholeExpenseDistribution envelope = ExpenseDistribution
  (EnvelopeShare envelope unitDistributionWeight :| [])
