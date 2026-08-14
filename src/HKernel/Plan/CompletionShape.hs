module HKernel.Plan.CompletionShape
  ( PlanCompletionShapeError(..)
  , validatePlanCompletionShape
  ) where

import qualified Data.List.NonEmpty as NonEmpty
import HKernel.Ledger
  ( Transaction
  , postingAccount
  , postingAmount
  , transactionPostings
  )
import HKernel.Money
  ( amountCommodity
  , amountQuantity
  , zeroQuantity
  )
import HKernel.Plan (PlanId)

-- | Structural incompatibilities that prevent an Actual completion from being
-- interpreted posting-by-posting against its Plan.
--
-- Exact quantities may differ: a Plan is intention while Actual records what
-- happened. Account coordinates, posting directions, and commodities must still
-- agree so a caller can safely use the Actual amount at the corresponding Plan
-- coordinate.
data PlanCompletionShapeError
  = PlanCompletionAccountShapeMismatch PlanId
  | PlanCompletionDirectionMismatch PlanId
  | PlanCompletionCommodityMismatch PlanId
  deriving (Eq, Show)

validatePlanCompletionShape
  :: PlanId
  -> Transaction
  -> Transaction
  -> Either PlanCompletionShapeError ()
validatePlanCompletionShape planId planTransaction actualTransaction = do
  if planAccounts == actualAccounts
    then Right ()
    else Left (PlanCompletionAccountShapeMismatch planId)
  if planDirections == actualDirections
    then Right ()
    else Left (PlanCompletionDirectionMismatch planId)
  if planCommodities == actualCommodities
    then Right ()
    else Left (PlanCompletionCommodityMismatch planId)
  where
    planPostings = NonEmpty.toList (transactionPostings planTransaction)
    actualPostings = NonEmpty.toList (transactionPostings actualTransaction)
    planAccounts = map postingAccount planPostings
    actualAccounts = map postingAccount actualPostings
    planDirections = map (direction . postingAmount) planPostings
    actualDirections = map (direction . postingAmount) actualPostings
    planCommodities = map (amountCommodity . postingAmount) planPostings
    actualCommodities = map (amountCommodity . postingAmount) actualPostings

    direction amount = compare (amountQuantity amount) zeroQuantity
