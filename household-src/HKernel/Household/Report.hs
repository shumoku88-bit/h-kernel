{-# LANGUAGE OverloadedStrings #-}

-- | Pure Household report composition from already admitted typed values.
--
-- Source admission, writer authority, and delivery effects remain outside this
-- module. Native Envelope owners meet here without an intermediate Budget
-- calculation model.
module HKernel.Household.Report
  ( HouseholdSourceError(..)
  , HouseholdCycleComparison(..)
  , HouseholdCycleComparisonUnavailable(..)
  , HouseholdReportSurface(..)
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
  , AdmittedPlans
  , admitPlanJournal
  , admittedOutgoingPlanValues
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
import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalCompletionDeclarations
  , actualJournalIdentifiedTransactions
  , actualJournalValue
  )
import HKernel.Engine (LedgerEntry(..), journalEntries)
import HKernel.Envelope.EntitlementHistory (EnvelopeEntitlementHistory)
import HKernel.Envelope.ExpenseRouting (ExpenseRoutingHistory)
import HKernel.Envelope.FulfillmentRouting (FulfillmentRoutingHistory)
import HKernel.Household.Backing
  ( HouseholdBackingPlan(..)
  , EnvelopeBackingLine(..)
  , envelopeLedgerRemaining
  , envelopePostPlanHeadroom
  , EnvelopeBacking(..)
  , envelopeFundingBalance
  , envelopeSignedTotal
  , envelopeBackingRequired
  , envelopeBackingSurplus
  , envelopeAvailableBackingSurplus
  , deriveHouseholdBacking
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
  , householdCycleIncomeAccount
  , householdEnvelopeOrder
  , householdPolicyCycle
  )
import HKernel.HouseholdIssue
import HKernel.Journal (Journal, journalAccountRegistry)
import HKernel.Ledger
  ( Posting
  , postingAccount
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
  ( ClassifiedPlanTransaction(..)
  , IdentifiedPlanTransaction
  , PlanClassificationError(..)
  , PlanJournal
  , admitPlanRetirements
  , classifiedIncomingPlanTransactions
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

data IncomingCycleAnchor = IncomingCycleAnchor
  { incomingAnchorId     :: PlanId
  , incomingAnchorDate   :: Day
  , incomingAnchorSource :: Account
  } deriving (Eq, Show)

data AdmittedPlans = AdmittedPlans
  { admittedIncomingAnchors :: [IncomingCycleAnchor]
  , admittedOutgoingPlans   :: [CommittedOutgoingPlan]
  , admittedPlanRetirements :: [PlanRetirement]
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

data HouseholdReportSurface = HouseholdReportSurface
  { householdCurrentCycleAccounts  :: CurrentCycleAccounts
  , householdCycleComparison       :: HouseholdCycleComparison
  , householdPlannedTransactions   :: [CommittedOutgoingPlan]
  , householdIssues                :: [HouseholdIssue]
  , householdEnvelopeStockOrigins  :: Map Commodity Day
  , householdEnvelopeBacking       :: EnvelopeBacking
  , householdDailyTarget           :: DailyTarget
  } deriving (Eq, Show)

buildHouseholdReportSurfaceFromAdmitted
  :: Day
  -> ActualJournal
  -> PlanJournal
  -> HouseholdPolicy
  -> ExpenseRoutingHistory
  -> FulfillmentRoutingHistory
  -> AdmittedPlans
  -> EnvelopeEntitlementHistory
  -> [HouseholdIssue]
  -> DailyTargetScope
  -> Either (NonEmpty HouseholdSourceError) HouseholdReportSurface
buildHouseholdReportSurfaceFromAdmitted observation actualJournal planJournal policy expenseRouting fulfillmentRouting admittedPlans entitlementHistory issues dailyScope = do
  let journal = actualJournalValue actualJournal
      cycleAccount = householdCycleIncomeAccount (householdPolicyCycle policy)
      retiredPlanIds = retiredPlanIdsAt observation
        (admittedPlanRetirements admittedPlans)
      activeIncomingAnchors = filter
        (\anchor -> incomingAnchorId anchor `Set.notMember` retiredPlanIds)
        (admittedIncomingAnchors admittedPlans)
  (current, previous) <- resolveCycles observation journal cycleAccount activeIncomingAnchors
  currentCycle <- mapLeft
    (NonEmpty.singleton . sourceError "cycle" 0 . tshow)
    (currentCycleAccounts observation current journal)
  let outgoingPlans = admittedOutgoingPlans admittedPlans
  outgoingDeclarations <- completionDeclarationsForOutgoingPlans
    planJournal admittedPlans (actualJournalCompletionDeclarations actualJournal)
  completionOpenPlanValues <- mapLeft
    (fmap (sourceError "actual.journal" 0 . tshow))
    (resolveOpenCommittedOutgoingPlans
      outgoingPlans
      (actualJournalIdentifiedTransactions actualJournal)
      outgoingDeclarations)
  openFundingTransactions <- mapLeft
    (fmap (sourceError "plan.journal" 0 . tshow))
    (resolveOpenPlanTransactionsAt observation planJournal actualJournal)
  backingPlans <- projectBackingFundingPlans
    current
    (journalAccountRegistry (planJournalValue planJournal))
    openFundingTransactions
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
      openPlanValues = filter
        (\plan -> committedPlanId plan `Set.notMember` retiredPlanIds)
        completionOpenPlanValues
      openPlanIds = Set.fromList (map committedPlanId openPlanValues)
      openPlans = openOutgoingPlans openPlanIds outgoingPlans
      currentOpenPlans = filter (periodContains current . committedPlanDate) openPlans
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
  let target = deriveDailyTarget observation current journal dailyScope currentOpenPlans
      comparison = alignedHouseholdCycleComparison
        observation current previous journal currentCycle
  pure HouseholdReportSurface
    { householdCurrentCycleAccounts = currentCycle
    , householdCycleComparison = comparison
    , householdPlannedTransactions = openPlans
    , householdIssues = issues
    , householdEnvelopeStockOrigins =
        householdEnvelopeObservationStockOrigins envelopeObservation
    , householdEnvelopeBacking = backing
    , householdDailyTarget = target
    }

-- | Project every negative Asset posting of every role-neutral open Plan into
-- the independent Backing funding horizon. Plan destination semantics never
-- enter this projection; Envelope claims are owned by Commitment routing.
projectBackingFundingPlans
  :: Period
  -> AccountRegistry
  -> [IdentifiedPlanTransaction]
  -> Either (NonEmpty HouseholdSourceError) [HouseholdBackingPlan]
projectBackingFundingPlans period registry = fmap concat . traverse projectPlan
  where
    projectPlan identified
      | transactionDate transaction >= periodEndExclusive period = Right []
      | otherwise = traverse projectPosting fundingPostings
      where
        transaction = identifiedPlanTransaction identified
        fundingPostings =
          [ posting
          | posting <- NonEmpty.toList (transactionPostings transaction)
          , accountTypeFor (postingAccount posting) registry == Just Asset
          , amountQuantity (postingAmount posting) < zeroQuantity
          ]

    projectPosting posting =
      case mkPositiveAmount (negateAmount (postingAmount posting)) of
        Right amount -> Right HouseholdBackingPlan
          { householdBackingPlanSource = postingAccount posting
          , householdBackingPlanAmount = amount
          }
        Left err -> Left
          (sourceError "plan.journal" 0
            ("open funding Asset posting failed sign normalization: " <> tshow err)
            NonEmpty.:| [])

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

-- | Admit only the legacy incoming/outgoing subset needed by the narrow report
-- surface. Role-neutral Asset-to-Asset Plans remain in the full PlanJournal for
-- native Envelope Commitment/Fulfillment observers and are deliberately absent
-- from this compatibility projection.
admitPlanJournal :: PlanJournal -> Either (NonEmpty HouseholdSourceError) AdmittedPlans
admitPlanJournal planJournal = do
  retirements <- mapLeft
    (fmap (\err -> sourceError "plan.journal" (planLifecycleErrorLine err) (tshow err)))
    (admitPlanRetirements planJournal)
  classified <- case partitionEithers
      (map (classifyForNarrowReport registry) (planJournalTransactions planJournal)) of
    ([], values) -> Right [value | Just value <- values]
    (errors, _) -> Left
      (fmap (sourceError "plan.journal" 0 . tshow) (NonEmpty.fromList errors))
  incoming <- mapLeft NonEmpty.singleton
    (traverse (projectIncomingCycleAnchor registry)
      (classifiedIncomingPlanTransactions classified))
  projected <- mapLeft
    (fmap (sourceError "plan.journal" 0 . tshow))
    (projectCommittedOutgoingPlans planJournal classified)
  pure AdmittedPlans
    { admittedIncomingAnchors = incoming
    , admittedOutgoingPlans = map projectedCommittedOutgoingPlan projected
    , admittedPlanRetirements = retirements
    }
  where
    registry = journalAccountRegistry (planJournalValue planJournal)

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

admittedOutgoingPlanValues :: AdmittedPlans -> [CommittedOutgoingPlan]
admittedOutgoingPlanValues = admittedOutgoingPlans

projectIncomingCycleAnchor
  :: AccountRegistry -> IdentifiedPlanTransaction -> Either HouseholdSourceError IncomingCycleAnchor
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

completionDeclarationsForOutgoingPlans
  :: PlanJournal
  -> AdmittedPlans
  -> [PlanCompletionDeclaration]
  -> Either (NonEmpty HouseholdSourceError) [PlanCompletionDeclaration]
completionDeclarationsForOutgoingPlans planJournal plans declarations =
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
    outgoingPlanIds = Set.fromList (map committedPlanId (admittedOutgoingPlans plans))
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
  :: Set.Set PlanId -> [CommittedOutgoingPlan] -> [CommittedOutgoingPlan]
openOutgoingPlans openPlanIds =
  sortOn committedPlanDate . filter (\plan -> Set.member (committedPlanId plan) openPlanIds)

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value

tshow :: Show value => value -> Text
tshow = T.pack . show
