{-# LANGUAGE OverloadedStrings #-}

-- | Retained API shell for the retired Plan -> Budget execution writer.
--
-- Envelope-native observation derives Expense Consumption directly from Actual
-- plus historical Expense routing, and non-Expense Fulfillment directly from
-- completed Plan/Actual evidence plus historical Fulfillment routing. Neither
-- observation is written back to @budget.journal@.
--
-- The call shape remains temporarily because the TUI still routes completed
-- Plan publication through this boundary. It has no writer authority: it never
-- inspects current routing, never constructs a Budget movement, and never
-- produces candidate source bytes.
module HKernel.Editor.PlanBudgetSync
  ( PlanBudgetSyncError(..)
  , PlanBudgetSyncPreview(..)
  , PlanBudgetSyncResult(..)
  , preparePlanBudgetSync
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)

import HKernel.Account (Account, AccountRegistry)
import HKernel.Actual.Journal (ActualJournal)
import HKernel.Editor.BudgetMovementAppend
  ( BudgetJournalMovementAppendError )
import HKernel.Household.AccountProfile (HouseholdAccountPolicy)
import HKernel.Household.BudgetMovement (HouseholdBudgetMovementJournal)
import HKernel.Household.Policy (HouseholdPolicy)
import HKernel.Plan (PlanId)
import HKernel.Plan.Journal (PlanJournal)

-- | Historical error surface retained until the TUI compatibility boundary is
-- removed. No constructor is produced by 'preparePlanBudgetSync' anymore.
data PlanBudgetSyncError
  = PlanBudgetSyncPlanMissing PlanId
  | PlanBudgetSyncPlanDuplicate PlanId
  | PlanBudgetSyncCompletionMissing PlanId
  | PlanBudgetSyncCompletionDuplicate PlanId
  | PlanBudgetSyncActualMissing PlanId
  | PlanBudgetSyncShapeMismatch PlanId
  | PlanBudgetSyncDirectionMismatch PlanId
  | PlanBudgetSyncMultipleDestinations PlanId
  | PlanBudgetSyncDestinationNotFixed Account
  | PlanBudgetSyncEnvelopeAllocationMissing PlanId
  | PlanBudgetSyncEnvelopeAllocationDuplicate PlanId (NonEmpty Account)
  | PlanBudgetSyncEnvelopeNotExecution Account
  | PlanBudgetSyncSpentAccountMissing
  | PlanBudgetSyncSpentAccountDuplicate (NonEmpty Account)
  | PlanBudgetSyncActualAmountNotPositive PlanId
  | PlanBudgetSyncCommodityMismatch PlanId
  | PlanBudgetSyncDuplicateMetadataKey Text
  | PlanBudgetSyncDuplicateBudgetLinkage PlanId
  | PlanBudgetSyncExistingLinkageMismatch PlanId
  | PlanBudgetSyncBudgetCandidateError (NonEmpty BudgetJournalMovementAppendError)
  deriving (Eq, Show)

-- | Historical candidate shape retained only for caller compatibility.
-- 'preparePlanBudgetSync' never constructs this value.
data PlanBudgetSyncPreview = PlanBudgetSyncPreview
  { planBudgetSyncPlanId                  :: PlanId
  , planBudgetSyncCandidateBlock          :: Text
  , planBudgetSyncCandidateCompleteSource :: Text
  } deriving (Eq, Show)

data PlanBudgetSyncResult
  = PlanBudgetSyncNotLinked PlanId
  | PlanBudgetSyncApplied PlanId
  | PlanBudgetSyncAppend PlanBudgetSyncPreview
  deriving (Eq, Show)

-- | The legacy execution writer is retired.
--
-- Completion is already authoritative Actual/Plan relation evidence. Envelope
-- Consumption/Fulfillment observe that evidence through their historical
-- routing owners, so appending a second execution fact to @budget.journal@ would
-- duplicate meaning. Returning 'PlanBudgetSyncNotLinked' keeps the current TUI
-- publication seam source-compatible while guaranteeing no Budget source write.
preparePlanBudgetSync
  :: AccountRegistry
  -> HouseholdPolicy
  -> Maybe HouseholdAccountPolicy
  -> PlanJournal
  -> ActualJournal
  -> HouseholdBudgetMovementJournal
  -> Text
  -> PlanId
  -> Either (NonEmpty PlanBudgetSyncError) PlanBudgetSyncResult
preparePlanBudgetSync _ _ _ _ _ _ _ planId =
  Right (PlanBudgetSyncNotLinked planId)
