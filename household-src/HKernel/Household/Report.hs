{-# LANGUAGE OverloadedStrings #-}

-- | Pure Household report composition from already admitted typed values.
--
-- Source admission, writer authority, and delivery effects remain outside this
-- module. It composes stable Household, Plan, Budget, Actual, and Report owners
-- without reparsing physical compatibility sources.
module HKernel.Household.Report
  ( HouseholdSourceError(..)
  , HouseholdCycleComparison(..)
  , HouseholdCycleComparisonUnavailable(..)
  , HouseholdReportSurface(..)
  , PlannedTransactionHorizon(..)
  , ClassifiedPlannedTransaction(..)
  , classifyPlannedTransactions
  , EnvelopeBackingLine(..)
  , envelopeLedgerRemaining
  , envelopePostPlanHeadroom
  , EnvelopeBacking(..)
  , envelopeSignedTotal
  , envelopeBackingRequired
  , envelopeBackingSurplus
  , envelopeReconciliationDelta
  , DailyTarget(..)
  , dailyTargetCapacity
  , dailyTargetRate
  , AdmittedPlans
  , admitPlanJournal
  , admittedOutgoingPlanValues
  , buildHouseholdReportSurfaceFromAdmitted
  ) where

import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, addDays, diffDays)
import HKernel.Account
import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalCompletionDeclarations
  , actualJournalIdentifiedTransactions
  , actualJournalValue
  )
import HKernel.Engine
  ( LedgerEntry(..)
  , journalEntries
  )
import HKernel.Household.Backing
  ( HouseholdBackingPlan(..)
  , EnvelopeBackingLine(..)
  , envelopeLedgerRemaining
  , envelopePostPlanHeadroom
  , EnvelopeBacking(..)
  , envelopeSignedTotal
  , envelopeBackingRequired
  , envelopeBackingSurplus
  , envelopeReconciliationDelta
  , deriveHouseholdBacking
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement)
import HKernel.Household.DailyTarget
import HKernel.Household.Policy
  ( AccountValidatedHouseholdPolicy
  , HouseholdPolicy
  , householdCycleIncomeAccount
  , householdPolicyCycle
  )
import HKernel.HouseholdIssue
import HKernel.Journal (Journal, journalAccountRegistry)
import HKernel.Ledger
  ( postingAccount
  , postingAmount
  , transactionDate
  , transactionPostings
  )
import HKernel.Money
import HKernel.Period
import HKernel.Plan
import HKernel.Plan.Completion
  ( PlanCompletionDeclaration
  , declaredCompletionPlanId
  , resolveOpenCommittedOutgoingPlans
  )
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , PlanJournal
  , classifiedIncomingPlanTransactions
  , classifyPlanJournal
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalValue
  , projectCommittedOutgoingPlans
  , projectedCommittedOutgoingPlan
  )
import HKernel.Report.CycleAccounts
import HKernel.Household.BudgetObservation
  ( deriveHouseholdBudgetObservation
  , householdBudgetObservationPolicy
  , householdBudgetConsumption
  , householdBudgetEntitlement
  , householdBudgetRemaining
  )

-- | A source-local admission failure. Private source text is deliberately not
-- retained, so CLI diagnostics cannot accidentally echo a complete row.
data HouseholdSourceError = HouseholdSourceError
  { householdSourceName    :: Text
  , householdSourceLine    :: Int
  , householdSourceMessage :: Text
  } deriving (Eq, Show)

-- | A future income movement used only as evidence for cycle resolution.
--
-- It is deliberately not represented by 'CommittedOutgoingPlan'.
data IncomingCycleAnchor = IncomingCycleAnchor
  { incomingAnchorId     :: PlanId
  , incomingAnchorDate   :: Day
  , incomingAnchorSource :: Account
  } deriving (Eq, Show)

data AdmittedPlans = AdmittedPlans
  { admittedIncomingAnchors :: [IncomingCycleAnchor]
  , admittedOutgoingPlans   :: [CommittedOutgoingPlan]
  } deriving (Eq, Show)

-- | Display relation of an open outgoing Plan to the resolved current cycle.
-- This is intentionally presentation-facing classification; Budget, Backing,
-- and Daily Target remain bounded by the current cycle independently.
data PlannedTransactionHorizon
  = BeforeCurrentCycle
  | InCurrentCycle
  | AfterCurrentCycle
  deriving (Eq, Show)

data ClassifiedPlannedTransaction = ClassifiedPlannedTransaction
  { classifiedPlanHorizon :: PlannedTransactionHorizon
  , classifiedPlanValue   :: CommittedOutgoingPlan
  } deriving (Eq, Show)

-- | Availability of the daily current-vs-previous cycle comparison.
--
-- The Household surface uses the old BQN daily-use meaning: compare the current
-- cycle with the previous cycle at the same elapsed day count. If the previous
-- cycle cannot supply that aligned observation, only this comparison is marked
-- unavailable; the rest of the admitted Household surface remains usable.
data HouseholdCycleComparison
  = HouseholdCycleComparisonAvailable CycleComparison
  | HouseholdCycleComparisonUnavailable HouseholdCycleComparisonUnavailable
  deriving (Eq, Show)

data HouseholdCycleComparisonUnavailable
  = HouseholdCycleBaselineUnavailable CurrentCycleAccountsError
  | HouseholdCycleComparisonRejected CycleComparisonError
  deriving (Eq, Show)

data HouseholdReportSurface = HouseholdReportSurface
  { householdCurrentCycleAccounts :: CurrentCycleAccounts
  , householdCycleComparison      :: HouseholdCycleComparison
  , householdPlannedTransactions  :: [CommittedOutgoingPlan]
  , householdIssues               :: [HouseholdIssue]
  , householdEnvelopeBacking      :: EnvelopeBacking
  , householdDailyTarget          :: DailyTarget
  } deriving (Eq, Show)

-- | Calculate the Household report surface from already admitted typed values.
-- Admission adapters may differ, but cycle, Plan completion, Budget observation,
-- backing, and Daily Target calculation have one semantic owner here.
buildHouseholdReportSurfaceFromAdmitted
  :: Day
  -> ActualJournal
  -> HouseholdPolicy
  -> AccountValidatedHouseholdPolicy
  -> AdmittedPlans
  -> [HouseholdBudgetMovement]
  -> [HouseholdIssue]
  -> DailyTargetScope
  -> Either (NonEmpty HouseholdSourceError) HouseholdReportSurface
buildHouseholdReportSurfaceFromAdmitted observation actualJournal policy validatedPolicy admittedPlans budget issues dailyScope = do
  let journal = actualJournalValue actualJournal
      cycleAccount = householdCycleIncomeAccount (householdPolicyCycle policy)
  (current, previous) <- resolveCycles observation journal cycleAccount
    (admittedIncomingAnchors admittedPlans)
  currentCycle <- mapLeft
    (NonEmpty.singleton . sourceError "cycle" 0 . tshow)
    (currentCycleAccounts observation current journal)
  let outgoingPlans = admittedOutgoingPlans admittedPlans
  outgoingDeclarations <- completionDeclarationsForOutgoingPlans admittedPlans
    (actualJournalCompletionDeclarations actualJournal)
  openPlanValues <- mapLeft
    (fmap (sourceError "actual.journal" 0 . tshow))
    (resolveOpenCommittedOutgoingPlans
      outgoingPlans
      (actualJournalIdentifiedTransactions actualJournal)
      outgoingDeclarations)
  budgetObservation <- mapLeft
    (fmap (sourceError "budget.journal" 0 . tshow))
    (deriveHouseholdBudgetObservation observation current journal
      validatedPolicy budget)
  let admittedPolicy = householdBudgetObservationPolicy budgetObservation
      consumption = householdBudgetConsumption budgetObservation
      entitlement = householdBudgetEntitlement budgetObservation
      remaining = householdBudgetRemaining budgetObservation
      openPlanIds = Set.fromList (map committedPlanId openPlanValues)
      openPlans = openOutgoingPlans openPlanIds outgoingPlans
      currentOpenPlans = filter
        (periodContains current . committedPlanDate)
        openPlans
      backingPlans =
        [ HouseholdBackingPlan
            { householdBackingPlanDestination = committedPlanDestination plan
            , householdBackingPlanAmount = committedPlanAmount plan
            }
        | plan <- currentOpenPlans
        ]
      backing = deriveHouseholdBacking
        observation current journal admittedPolicy
        budget entitlement consumption remaining backingPlans
      target = deriveDailyTarget observation current journal
        dailyScope currentOpenPlans
      comparison = alignedHouseholdCycleComparison
        observation current previous journal currentCycle
  pure HouseholdReportSurface
    { householdCurrentCycleAccounts = currentCycle
    , householdCycleComparison = comparison
    , householdPlannedTransactions = openPlans
    , householdIssues = issues
    , householdEnvelopeBacking = backing
    , householdDailyTarget = target
    }

-- | Compare the previous cycle at the same elapsed day count as the current
-- observation. An unavailable aligned baseline is retained as typed evidence
-- instead of clipping the window or failing unrelated Household reports.
alignedHouseholdCycleComparison
  :: Day
  -> Period
  -> Period
  -> Journal
  -> CurrentCycleAccounts
  -> HouseholdCycleComparison
alignedHouseholdCycleComparison observation current previous journal currentCycle =
  case currentCycleAccounts baselineObservation previous journal of
    Left err -> HouseholdCycleComparisonUnavailable
      (HouseholdCycleBaselineUnavailable err)
    Right baseline -> case cycleComparison AlignedElapsed currentCycle baseline of
      Left err -> HouseholdCycleComparisonUnavailable
        (HouseholdCycleComparisonRejected err)
      Right comparison -> HouseholdCycleComparisonAvailable comparison
  where
    baselineObservation = addDays elapsedDays (periodStart previous)
    elapsedDays = diffDays observation (periodStart current)

-- | Classify already admitted open outgoing Plans without changing which Plans
-- participate in current-cycle accounting calculations.
classifyPlannedTransactions
  :: Period
  -> [CommittedOutgoingPlan]
  -> [ClassifiedPlannedTransaction]
classifyPlannedTransactions current = map classifyOne
  where
    classifyOne plan = ClassifiedPlannedTransaction
      { classifiedPlanHorizon = classifyDate (committedPlanDate plan)
      , classifiedPlanValue = plan
      }
    classifyDate day
      | day < periodStart current = BeforeCurrentCycle
      | periodContains current day = InCurrentCycle
      | otherwise = AfterCurrentCycle

admitPlanJournal
  :: PlanJournal
  -> Either (NonEmpty HouseholdSourceError) AdmittedPlans
admitPlanJournal planJournal = do
  classified <- mapLeft
    (fmap (sourceError "plan.journal" 0 . tshow))
    (classifyPlanJournal planJournal)
  incoming <- mapLeft NonEmpty.singleton
    (traverse
      (projectIncomingCycleAnchor registry)
      (classifiedIncomingPlanTransactions classified))
  projected <- mapLeft
    (fmap (sourceError "plan.journal" 0 . tshow))
    (projectCommittedOutgoingPlans planJournal classified)
  pure AdmittedPlans
    { admittedIncomingAnchors = incoming
    , admittedOutgoingPlans = map projectedCommittedOutgoingPlan projected
    }
  where
    registry = journalAccountRegistry (planJournalValue planJournal)

admittedOutgoingPlanValues :: AdmittedPlans -> [CommittedOutgoingPlan]
admittedOutgoingPlanValues = admittedOutgoingPlans

projectIncomingCycleAnchor
  :: AccountRegistry
  -> IdentifiedPlanTransaction
  -> Either HouseholdSourceError IncomingCycleAnchor
projectIncomingCycleAnchor registry identified =
  case Set.toAscList incomeSources of
    [source] -> Right IncomingCycleAnchor
      { incomingAnchorId = identifiedPlanId identified
      , incomingAnchorDate = transactionDate transaction
      , incomingAnchorSource = source
      }
    _ -> Left (sourceError "plan.journal" 0
      "incoming cycle anchor requires exactly one Income source Account")
  where
    transaction = identifiedPlanTransaction identified
    incomeSources = Set.fromList
      [ postingAccount posting
      | posting <- NonEmpty.toList (transactionPostings transaction)
      , accountTypeFor (postingAccount posting) registry == Just Income
      , amountQuantity (postingAmount posting) < zeroQuantity
      ]

committedPlanDestination :: CommittedOutgoingPlan -> Account
committedPlanDestination plan =
  declaredAccount (declaredPaymentDestination direction)
  where
    direction =
      declaredOutgoingPaymentDirection (committedPlanDirection plan)

completionDeclarationsForOutgoingPlans
  :: AdmittedPlans
  -> [PlanCompletionDeclaration]
  -> Either (NonEmpty HouseholdSourceError) [PlanCompletionDeclaration]
completionDeclarationsForOutgoingPlans plans declarations =
  case NonEmpty.nonEmpty unknownErrors of
    Just errors -> Left errors
    Nothing -> Right
      [ declaration
      | declaration <- declarations
      , Set.member (declaredCompletionPlanId declaration) outgoingPlanIds
      ]
  where
    incomingPlanIds = Set.fromList
      (map incomingAnchorId (admittedIncomingAnchors plans))
    outgoingPlanIds = Set.fromList
      (map committedPlanId (admittedOutgoingPlans plans))
    knownPlanIds = Set.union incomingPlanIds outgoingPlanIds
    unknownErrors =
      [ sourceError "actual.journal" 0
          ("completion relation refers to unknown PlanId " <> planIdText planId)
      | declaration <- declarations
      , let planId = declaredCompletionPlanId declaration
      , Set.notMember planId knownPlanIds
      ]

sourceError :: Text -> Int -> Text -> HouseholdSourceError
sourceError = HouseholdSourceError

resolveCycles
  :: Day
  -> Journal
  -> Account
  -> [IncomingCycleAnchor]
  -> Either (NonEmpty HouseholdSourceError) (Period, Period)
resolveCycles observation journal incomeAccount anchors =
  case (reverse actualAnchors, plannedAnchors) of
    (currentStart : previousStart : _, currentEnd : _) -> do
      current <- period currentStart currentEnd
      previous <- period previousStart currentStart
      Right (current, previous)
    _ -> Left (sourceError "household.toml" 0
      "income-anchor cycle requires two observed Actual anchors and one future Plan anchor"
      NonEmpty.:| [])
  where
    actualAnchors = Set.toAscList (Set.fromList
      [ entryDate entry
      | entry <- journalEntries journal
      , entryDate entry <= observation
      , entryAccount entry == incomeAccount
      , amountQuantity (entryAmount entry) < zeroQuantity
      ])
    plannedAnchors = Set.toAscList (Set.fromList
      [ incomingAnchorDate anchor
      | anchor <- anchors
      , incomingAnchorSource anchor == incomeAccount
      , incomingAnchorDate anchor > observation
      ])
    period start end = mapLeft
      (NonEmpty.singleton . sourceError "household.toml" 0 . tshow)
      (mkPeriod start end)

openOutgoingPlans
  :: Set.Set PlanId
  -> [CommittedOutgoingPlan]
  -> [CommittedOutgoingPlan]
openOutgoingPlans openPlanIds =
  sortOn committedPlanDate
    . filter (\plan -> Set.member (committedPlanId plan) openPlanIds)

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value

tshow :: Show value => value -> Text
tshow = T.pack . show
