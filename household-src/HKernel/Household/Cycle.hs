{-# LANGUAGE OverloadedStrings #-}

-- | Household income-anchor cycle observation from admitted Actual, Plan, and
-- cycle policy evidence.
--
-- A Plan becomes a cycle candidate only when it contains a negative posting on
-- the configured Income Account. Unrelated Plan shapes remain outside this
-- observer; once relevant, the complete incoming shape is validated rather than
-- inferred from a report-facing Plan classification.
module HKernel.Household.Cycle
  ( HouseholdCycleObservation
  , householdCycleCurrentPeriod
  , householdCyclePreviousPeriod
  , HouseholdCycleError(..)
  , observeHouseholdCycle
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import Data.Time.Calendar (Day)

import HKernel.Account
  ( Account
  , AccountRegistry
  , AccountType(..)
  , accountTypeFor
  )
import HKernel.Actual.Journal (ActualJournal, actualJournalValue)
import HKernel.Engine (LedgerEntry(..), journalEntries)
import HKernel.Household.Policy
  ( HouseholdCyclePolicy
  , householdCycleIncomeAccount
  )
import HKernel.Journal (journalAccountRegistry)
import HKernel.Ledger
  ( Posting
  , postingAccount
  , postingAmount
  , transactionDate
  , transactionPostings
  )
import HKernel.Money (amountQuantity, zeroQuantity)
import HKernel.Period (Period, PeriodError, mkPeriod)
import HKernel.Plan (PlanId)
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , PlanJournal
  , PlanLifecycleError
  , admitPlanRetirements
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalTransactions
  , planJournalValue
  , retiredPlanIdsAt
  )

data HouseholdCycleObservation = HouseholdCycleObservation
  { householdCycleCurrentPeriod  :: Period
  , householdCyclePreviousPeriod :: Period
  } deriving (Eq, Show)

data HouseholdCycleError
  = HouseholdCyclePlanLifecycleError PlanLifecycleError
  | HouseholdCyclePlanShapeError PlanId
  | HouseholdCycleAnchorsUnavailable
  | HouseholdCyclePeriodError PeriodError
  deriving (Eq, Show)

data IncomingCycleAnchor = IncomingCycleAnchor
  { incomingAnchorId   :: PlanId
  , incomingAnchorDate :: Day
  } deriving (Eq, Show)

observeHouseholdCycle
  :: Day
  -> ActualJournal
  -> PlanJournal
  -> HouseholdCyclePolicy
  -> Either (NonEmpty HouseholdCycleError) HouseholdCycleObservation
observeHouseholdCycle observation actualJournal planJournal policy = do
  retirements <- mapLeft (fmap HouseholdCyclePlanLifecycleError)
    (admitPlanRetirements planJournal)
  anchors <- projectRelevantPlanAnchors
    (journalAccountRegistry (planJournalValue planJournal))
    incomeAccount
    planJournal
  let retired = retiredPlanIdsAt observation retirements
      activeAnchors =
        [ anchor
        | anchor <- anchors
        , incomingAnchorId anchor `Set.notMember` retired
        ]
      actualAnchors = Set.toAscList (Set.fromList
        [ entryDate entry
        | entry <- journalEntries (actualJournalValue actualJournal)
        , entryDate entry <= observation
        , entryAccount entry == incomeAccount
        , amountQuantity (entryAmount entry) < zeroQuantity
        ])
      plannedAnchors = Set.toAscList (Set.fromList
        [ incomingAnchorDate anchor
        | anchor <- activeAnchors
        , incomingAnchorDate anchor > observation
        ])
  case (reverse actualAnchors, plannedAnchors) of
    (currentStart : previousStart : _, currentEnd : _) -> do
      current <- period currentStart currentEnd
      previous <- period previousStart currentStart
      Right HouseholdCycleObservation
        { householdCycleCurrentPeriod = current
        , householdCyclePreviousPeriod = previous
        }
    _ -> Left (HouseholdCycleAnchorsUnavailable NonEmpty.:| [])
  where
    incomeAccount = householdCycleIncomeAccount policy
    period start end = mapLeft
      (NonEmpty.singleton . HouseholdCyclePeriodError)
      (mkPeriod start end)

projectRelevantPlanAnchors
  :: AccountRegistry
  -> Account
  -> PlanJournal
  -> Either (NonEmpty HouseholdCycleError) [IncomingCycleAnchor]
projectRelevantPlanAnchors registry incomeAccount planJournal =
  case partitionEithers (map projectCandidate relevantPlans) of
    ([], anchors) -> Right anchors
    (firstError : remainingErrors, _) ->
      Left (firstError NonEmpty.:| remainingErrors)
  where
    relevantPlans = filter isRelevant (planJournalTransactions planJournal)

    isRelevant identified = any isConfiguredIncomeSource
      (NonEmpty.toList
        (transactionPostings (identifiedPlanTransaction identified)))

    isConfiguredIncomeSource posting =
      postingAccount posting == incomeAccount
        && accountTypeFor (postingAccount posting) registry == Just Income
        && amountQuantity (postingAmount posting) < zeroQuantity

    projectCandidate identified
      | validIncomingShape postings = Right IncomingCycleAnchor
          { incomingAnchorId = identifiedPlanId identified
          , incomingAnchorDate = transactionDate transaction
          }
      | otherwise = Left
          (HouseholdCyclePlanShapeError (identifiedPlanId identified))
      where
        transaction = identifiedPlanTransaction identified
        postings = NonEmpty.toList (transactionPostings transaction)

    validIncomingShape postings =
      incomeSources == Set.singleton incomeAccount
        && any isPositiveAsset postings
        && all isSupportedPosting postings
      where
        incomeSources = Set.fromList
          [ postingAccount posting
          | posting <- postings
          , accountTypeFor (postingAccount posting) registry == Just Income
          , amountQuantity (postingAmount posting) < zeroQuantity
          ]

    isPositiveAsset posting =
      accountTypeFor (postingAccount posting) registry == Just Asset
        && amountQuantity (postingAmount posting) > zeroQuantity

    isSupportedPosting posting =
      isConfiguredIncomeSource posting || isPositiveAsset posting

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value
