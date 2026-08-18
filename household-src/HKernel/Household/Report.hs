{-# LANGUAGE OverloadedStrings #-}

-- | Pure Household report composition from already admitted typed values.
--
-- Source admission, writer authority, and delivery effects remain outside this
-- module. Native Household observers meet here without an intermediate Budget
-- calculation model or one shared Plan projection bundle.
module HKernel.Household.Report
  ( HouseholdSourceError(..)
  , HouseholdCycleComparison(..)
  , HouseholdCycleComparisonUnavailable(..)
  , HouseholdPlannedTransactions(..)
  , HouseholdReportSurface(..)
  , householdPlannedTransactions
  , PlannedTransactionHorizon(..)
  , ClassifiedPlannedTransaction(..)
  , classifyPlannedTransactions
  , EnvelopeBackingLine(..)
  , envelopePostPlanHeadroom
  , EnvelopeBacking(..)
  , envelopeFundingBalance
  , envelopeSignedTotal
  , envelopeBackingRequired
  , envelopeBackingSurplus
  , envelopeAvailableBackingSurplus
  , DailyTarget(..)
  , dailyTargetCapacity
  , dailyTargetRate
  , buildHouseholdReportSurfaceFromAdmitted
  ) where

import Data.Either (partitionEithers)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, addDays, diffDays)
import HKernel.Account
  ( AccountRegistry
  , AccountType(..)
  , accountTypeFor
  )
import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalCompletionDeclarations
  , actualJournalIdentifiedTransactions
  , actualJournalValue
  )
import HKernel.Envelope.EntitlementHistory (EnvelopeEntitlementHistory)
import HKernel.Envelope.ExpenseRouting (ExpenseRoutingHistory)
import HKernel.Envelope.FulfillmentRouting (FulfillmentRoutingHistory)
import HKernel.Envelope.StockOrigin (StockOrigin)
import HKernel.Household.Backing
  ( EnvelopeBackingLine(..)
  , envelopeLedgerRemaining
  , envelopePostPlanHeadroom
  , EnvelopeBacking(..)
  , envelopeFundingBalance
  , envelopeSignedTotal
  , envelopeBackingRequired
  , envelopeBackingSurplus
  , envelopeAvailableBackingSurplus
  , deriveHouseholdBacking
  , projectHouseholdBackingPlans
  )
import HKernel.Household.Cycle
  ( householdCycleCurrentPeriod
  , householdCyclePreviousPeriod
  , observeHouseholdCycle
  )
import HKernel.Household.DailyTarget
import HKernel.Household.EnvelopeObservation
  ( deriveHouseholdEnvelopeObservation
  , householdEnvelopeObservationStockOrigins
  , householdEnvelopeConsumption
  , householdEnvelopeEntitlement
  , householdEnvelopeHeadroom
  , householdEnvelopeRemaining
  )
import HKernel.Household.Policy
  ( HouseholdPolicy
  , householdBackingPolicy
  , householdEnvelopeOrder
  , householdPolicyCycle
  )
import HKernel.HouseholdIssue
import HKernel.Journal (Journal, journalAccountRegistry)
import HKernel.Ledger
  ( Posting
  , postingAccount
  , postingAmount
  , transactionPostings
  )
import HKernel.Money
import HKernel.Period
import HKernel.Plan
import HKernel.Plan.Completion
  ( IdentifiedActualTransaction
  , PlanCompletionDeclaration
  , declaredCompletionPlanId
  , resolveOpenCommittedOutgoingPlans
  )
import HKernel.Plan.Journal
  ( ClassifiedPlanTransaction(..)
  , IdentifiedPlanTransaction
  , PlanClassificationError(..)
  , PlanJournal
  , PlanReportProjectionError
  , admitPlanRetirements
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalTransactions
  , planJournalValue
  , planLifecycleErrorLine
  , projectCommittedOutgoingPlans
  , projectedCommittedOutgoingPlan
  , retiredPlanIdsAt
  )
import HKernel.Plan.Open (resolveOpenPlanTransactionsAt)
import HKernel.Report.CycleAccounts

data HouseholdSourceError = HouseholdSourceError
  { householdSourceName    :: Text
  , householdSourceLine    :: Int
  , householdSourceMessage :: Text
  } deriving (Eq, Show)

data PlannedTransactionHorizon
  = BeforeCurrentCycle
  | InCurrentCycle
  | AfterCurrentCycle
  deriving (Eq, Show)

data ClassifiedPlannedTransaction = ClassifiedPlannedTransaction
  { classifiedPlanHorizon :: PlannedTransactionHorizon
  , classifiedPlanValue   :: CommittedOutgoingPlan
  } deriving (Eq, Show)

data HouseholdCycleComparison
  = HouseholdCycleComparisonAvailable CycleComparison
  | HouseholdCycleComparisonUnavailable HouseholdCycleComparisonUnavailable
  deriving (Eq, Show)

data HouseholdCycleComparisonUnavailable
  = HouseholdCycleBaselineUnavailable CurrentCycleAccountsError
  | HouseholdCycleComparisonRejected CycleComparisonError
  deriving (Eq, Show)

-- | Availability of the narrow payment-facing Planned Transactions section.
--
-- A PlanJournal may be broadly valid while containing a Plan shape that this
-- presentation cannot flatten into one current 'CommittedOutgoingPlan'. Such a
-- failure belongs to this section and must not hide Cycle, Daily Target, or
-- Envelope observations that do not require that narrow interpretation.
data HouseholdPlannedTransactions
  = HouseholdPlannedTransactionsAvailable [CommittedOutgoingPlan]
  | HouseholdPlannedTransactionsUnavailable (NonEmpty HouseholdSourceError)
  deriving (Eq, Show)

data HouseholdReportSurface = HouseholdReportSurface
  { householdCurrentCycleAccounts               :: CurrentCycleAccounts
  , householdCycleComparison                    :: HouseholdCycleComparison
  , householdPlannedTransactionsAvailability    :: HouseholdPlannedTransactions
  , householdIssues                             :: [HouseholdIssue]
  , householdEnvelopeStockOrigins               :: Map Commodity StockOrigin
  , householdEnvelopeBacking                    :: EnvelopeBacking
  , householdDailyTarget                        :: DailyTarget
  } deriving (Eq, Show)

-- | Compatibility read of only successfully projected payment-facing Plans.
-- New delivery code that must distinguish empty from unavailable should inspect
-- 'householdPlannedTransactionsAvailability' instead.
householdPlannedTransactions
  :: HouseholdReportSurface
  -> [CommittedOutgoingPlan]
householdPlannedTransactions surface =
  case householdPlannedTransactionsAvailability surface of
    HouseholdPlannedTransactionsAvailable plans -> plans
    HouseholdPlannedTransactionsUnavailable _ -> []

buildHouseholdReportSurfaceFromAdmitted
  :: Day
  -> ActualJournal
  -> PlanJournal
  -> HouseholdPolicy
  -> ExpenseRoutingHistory
  -> FulfillmentRoutingHistory
  -> EnvelopeEntitlementHistory
  -> [HouseholdIssue]
  -> DailyTargetScope
  -> Either (NonEmpty HouseholdSourceError) HouseholdReportSurface
buildHouseholdReportSurfaceFromAdmitted observation actualJournal planJournal policy expenseRouting fulfillmentRouting entitlementHistory issues dailyScope = do
  let journal = actualJournalValue actualJournal
  cycleObservation <- mapLeft
    (fmap (sourceError "cycle" 0 . tshow))
    (observeHouseholdCycle
      observation actualJournal planJournal (householdPolicyCycle policy))
  let current = householdCycleCurrentPeriod cycleObservation
      previous = householdCyclePreviousPeriod cycleObservation
  currentCycle <- mapLeft
    (NonEmpty.singleton . sourceError "cycle" 0 . tshow)
    (currentCycleAccounts observation current journal)
  retirements <- mapLeft
    (fmap (\err -> sourceError "plan.journal" (planLifecycleErrorLine err) (tshow err)))
    (admitPlanRetirements planJournal)
  let retiredPlanIds = retiredPlanIdsAt observation retirements
      completionDeclarations = actualJournalCompletionDeclarations actualJournal
      identifiedActuals = actualJournalIdentifiedTransactions actualJournal
  openFundingTransactions <- mapLeft
    (fmap (sourceError "plan.journal" 0 . tshow))
    (resolveOpenPlanTransactionsAt observation planJournal actualJournal)
  backingPlans <- mapLeft
    (fmap (sourceError "plan.journal" 0 . tshow))
    (projectHouseholdBackingPlans
      current
      (journalAccountRegistry (planJournalValue planJournal))
      openFundingTransactions)
  envelopeObservation <- mapLeft
    (fmap (sourceError "envelope" 0 . tshow))
    (deriveHouseholdEnvelopeObservation
      observation
      current
      actualJournal
      planJournal
      expenseRouting
      fulfillmentRouting
      entitlementHistory)
  let envelopeConsumption = householdEnvelopeConsumption envelopeObservation
      entitlement = householdEnvelopeEntitlement envelopeObservation
      remaining = householdEnvelopeRemaining envelopeObservation
      headroom = householdEnvelopeHeadroom envelopeObservation
  backing <- mapLeft
    (fmap (sourceError "backing" 0 . tshow))
    (deriveHouseholdBacking
      observation
      current
      journal
      (householdBackingPolicy policy)
      (householdEnvelopeOrder policy)
      entitlement
      envelopeConsumption
      remaining
      headroom
      backingPlans)
  dailyTargetPlans <- mapLeft
    (fmap (sourceError "daily-target" 0 . tshow))
    (projectDailyTargetScopePlans planJournal dailyScope)
  dailyTargetDeclarations <- completionDeclarationsForOutgoingPlans
    planJournal dailyTargetPlans completionDeclarations
  dailyTargetCompletionOpen <- mapLeft
    (fmap (sourceError "actual.journal" 0 . tshow))
    (resolveOpenCommittedOutgoingPlans
      dailyTargetPlans identifiedActuals dailyTargetDeclarations)
  let currentDailyTargetPlans =
        [ plan
        | plan <- dailyTargetCompletionOpen
        , committedPlanId plan `Set.notMember` retiredPlanIds
        , periodContains current (committedPlanDate plan)
        ]
      target = deriveDailyTarget
        observation current journal dailyScope currentDailyTargetPlans
      comparison = alignedHouseholdCycleComparison
        observation current previous journal currentCycle
      plannedTransactions = case observeReportPlannedTransactions
          planJournal identifiedActuals completionDeclarations retiredPlanIds of
        Left errors -> HouseholdPlannedTransactionsUnavailable errors
        Right plans -> HouseholdPlannedTransactionsAvailable plans
  pure HouseholdReportSurface
    { householdCurrentCycleAccounts = currentCycle
    , householdCycleComparison = comparison
    , householdPlannedTransactionsAvailability = plannedTransactions
    , householdIssues = issues
    , householdEnvelopeStockOrigins =
        householdEnvelopeObservationStockOrigins envelopeObservation
    , householdEnvelopeBacking = backing
    , householdDailyTarget = target
    }

alignedHouseholdCycleComparison
  :: Day -> Period -> Period -> Journal -> CurrentCycleAccounts -> HouseholdCycleComparison
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

classifyPlannedTransactions
  :: Period -> [CommittedOutgoingPlan] -> [ClassifiedPlannedTransaction]
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

-- | Project only the narrow payment-facing subset used by Planned Transactions.
-- Role-neutral Asset transfers remain valid Plan evidence but stay outside this
-- presentation view. Other unsupported accounting role flows fail at this
-- report boundary rather than constraining canonical Plan admission.
projectReportOutgoingPlans
  :: PlanJournal
  -> Either (NonEmpty HouseholdSourceError) [CommittedOutgoingPlan]
projectReportOutgoingPlans planJournal = do
  classified <- case partitionEithers
      (map (classifyForNarrowReport registry) (planJournalTransactions planJournal)) of
    ([], values) -> Right [value | Just value <- values]
    (errors, _) -> Left
      (fmap (sourceError "plan.journal" 0 . tshow) (NonEmpty.fromList errors))
  projected <- mapLeft
    (fmap (sourceError "plan.journal" 0 . tshow))
    (projectCommittedOutgoingPlans planJournal classified)
  pure (map projectedCommittedOutgoingPlan projected)
  where
    registry = journalAccountRegistry (planJournalValue planJournal)

-- | Re-project only the Plan identities already selected by the admitted Daily
-- Target scope. Relevance is owned by Daily Target; this composition step merely
-- asks the existing Plan.Journal binary projection for those relevant values.
-- An unrelated Plan shape can therefore never make Daily Target unavailable.
projectDailyTargetScopePlans
  :: PlanJournal
  -> DailyTargetScope
  -> Either (NonEmpty PlanReportProjectionError) [CommittedOutgoingPlan]
projectDailyTargetScopePlans planJournal scope =
  fmap (map projectedCommittedOutgoingPlan)
    (projectCommittedOutgoingPlans planJournal selectedTransactions)
  where
    selectedIds = dailyTargetObligationPlanIds
      (dailyTargetScopeObligations scope)
    selectedTransactions =
      [ OutgoingPlanTransaction identified
      | identified <- planJournalTransactions planJournal
      , identifiedPlanId identified `Set.member` selectedIds
      ]

observeReportPlannedTransactions
  :: PlanJournal
  -> [IdentifiedActualTransaction]
  -> [PlanCompletionDeclaration]
  -> Set.Set PlanId
  -> Either (NonEmpty HouseholdSourceError) [CommittedOutgoingPlan]
observeReportPlannedTransactions planJournal actuals declarations retiredPlanIds = do
  outgoingPlans <- projectReportOutgoingPlans planJournal
  outgoingDeclarations <- completionDeclarationsForOutgoingPlans
    planJournal outgoingPlans declarations
  completionOpenPlanValues <- mapLeft
    (fmap (sourceError "actual.journal" 0 . tshow))
    (resolveOpenCommittedOutgoingPlans
      outgoingPlans actuals outgoingDeclarations)
  let openPlanValues = filter
        (\plan -> committedPlanId plan `Set.notMember` retiredPlanIds)
        completionOpenPlanValues
      openPlanIds = Set.fromList (map committedPlanId openPlanValues)
  pure (openOutgoingPlans openPlanIds outgoingPlans)

classifyForNarrowReport
  :: AccountRegistry
  -> IdentifiedPlanTransaction
  -> Either PlanClassificationError (Maybe ClassifiedPlanTransaction)
classifyForNarrowReport registry identified
  | incomingShape coordinates = Right (Just (IncomingPlanTransaction identified))
  | outgoingShape coordinates = Right (Just (OutgoingPlanTransaction identified))
  | assetTransferShape coordinates = Right Nothing
  | otherwise = Left (UnsupportedPlanRoleFlow (identifiedPlanId identified))
  where
    coordinates = map (postingCoordinate registry)
      (NonEmpty.toList
        (transactionPostings (identifiedPlanTransaction identified)))

type PostingCoordinate = (Maybe AccountType, Ordering)

postingCoordinate :: AccountRegistry -> Posting -> PostingCoordinate
postingCoordinate registry posting =
  ( accountTypeFor (postingAccount posting) registry
  , compare (amountQuantity (postingAmount posting)) zeroQuantity
  )

incomingShape :: [PostingCoordinate] -> Bool
incomingShape coordinates =
  hasCoordinate (Just Income, LT) coordinates
    && hasCoordinate (Just Asset, GT) coordinates
    && all (`elem` [(Just Income, LT), (Just Asset, GT)]) coordinates

outgoingShape :: [PostingCoordinate] -> Bool
outgoingShape coordinates =
  hasCoordinate (Just Asset, LT) coordinates
    && any (`hasCoordinate` coordinates)
      [(Just Expense, GT), (Just Liability, GT)]
    && all (`elem`
      [ (Just Asset, LT)
      , (Just Expense, GT)
      , (Just Liability, GT)
      ]) coordinates

assetTransferShape :: [PostingCoordinate] -> Bool
assetTransferShape coordinates =
  hasCoordinate (Just Asset, LT) coordinates
    && hasCoordinate (Just Asset, GT) coordinates
    && all (`elem` [(Just Asset, LT), (Just Asset, GT)]) coordinates

hasCoordinate :: PostingCoordinate -> [PostingCoordinate] -> Bool
hasCoordinate = elem

completionDeclarationsForOutgoingPlans
  :: PlanJournal
  -> [CommittedOutgoingPlan]
  -> [PlanCompletionDeclaration]
  -> Either (NonEmpty HouseholdSourceError) [PlanCompletionDeclaration]
completionDeclarationsForOutgoingPlans planJournal outgoingPlans declarations =
  case NonEmpty.nonEmpty unknownErrors of
    Just errors -> Left errors
    Nothing -> Right
      [ declaration
      | declaration <- declarations
      , Set.member (declaredCompletionPlanId declaration) outgoingPlanIds
      ]
  where
    knownPlanIds = Set.fromList
      (map identifiedPlanId (planJournalTransactions planJournal))
    outgoingPlanIds = Set.fromList (map committedPlanId outgoingPlans)
    unknownErrors =
      [ sourceError "actual.journal" 0
          ("completion relation refers to unknown PlanId " <> planIdText planId)
      | declaration <- declarations
      , let planId = declaredCompletionPlanId declaration
      , Set.notMember planId knownPlanIds
      ]

sourceError :: Text -> Int -> Text -> HouseholdSourceError
sourceError = HouseholdSourceError

openOutgoingPlans
  :: Set.Set PlanId -> [CommittedOutgoingPlan] -> [CommittedOutgoingPlan]
openOutgoingPlans openPlanIds =
  sortOn committedPlanDate . filter (\plan -> Set.member (committedPlanId plan) openPlanIds)

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value

tshow :: Show value => value -> Text
tshow = T.pack . show
