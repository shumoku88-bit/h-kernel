{-# LANGUAGE OverloadedStrings #-}

-- | Pure admission and IO bootstrap for a canonical Household application state.
module HKernel.Household.Application
  ( HouseholdState(..)
  , HouseholdWriteSnapshot(..)
  , HouseholdLoadError(..)
  , loadCanonicalHousehold
  , loadCanonicalHouseholdWriteSnapshot
  , admitCanonicalHousehold
  , buildHouseholdReportSurfaceFromHousehold
  ) where

import Control.Exception (IOException)
import Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import System.IO.Error (tryIOError)

import HKernel.Account (AccountRegistry)
import HKernel.Account.Journal
  ( AccountJournalError
  , parseAccountJournal
  )
import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError(..)
  , actualJournalValue
  , admitActualJournalFromResolvedJournal
  , admitActualJournalFromResolvedSources
  )
import HKernel.Application.Config
  ( HouseholdRoot
  , HouseholdSourcePaths(..)
  , householdSourcePaths
  )
import HKernel.Envelope
  ( CurrentEnvelopePolicy
  , parseCurrentEnvelopeConfiguration
  )
import HKernel.Envelope.Entitlement.Journal
  ( EntitlementJournalError
  , admitEntitlementJournal
  )
import HKernel.Envelope.EntitlementHistory (EnvelopeEntitlementHistory)
import HKernel.Household.Config
  ( HouseholdConfiguration
  , householdConfigurationDailyTargetAssets
  , householdConfigurationPolicy
  , parseHouseholdConfiguration
  )
import HKernel.Household.DailyTarget
  ( DailyTargetAssetSelection
  , DailyTargetObligationSelection
  , DailyTargetPlanJournalError
  , DailyTargetScope
  , DailyTargetSelectionError
  , admitDailyTargetPlanJournalSelections
  , dailyTargetObligationSelectionDeclaration
  , dailyTargetScopeFromSelections
  , declaredDailyTargetObligationPlanId
  )
import HKernel.Household.EnvelopeHistory
  ( HouseholdEnvelopeHistory
  , HouseholdEnvelopeHistoryReferenceError
  , admitHouseholdEnvelopeHistoryReferences
  , householdEnvelopeRegistry
  , householdExpenseRoutingHistory
  , householdFulfillmentRoutingHistory
  , parseHouseholdEnvelopeHistory
  )
import HKernel.Household.Issue.TSV
  ( HouseholdIssueTSVError
  , parseHouseholdIssues
  )
import HKernel.Household.Policy
  ( HouseholdPolicy
  , HouseholdPolicyAccountError
  , validateHouseholdPolicyAccounts
  )
import HKernel.Household.Report
  ( HouseholdReportSurface
  , HouseholdSourceError
  , admitPlanJournal
  , buildHouseholdReportSurfaceFromAdmitted
  )
import HKernel.HouseholdIssue (HouseholdIssue)
import HKernel.Journal
  ( Journal
  , JournalError(..)
  , JournalErrorReason(..)
  , includePath
  , journalAccountRegistry
  , parseJournalDocument
  , resolveJournalDocumentIncludes
  , validateJournalDocument
  )
import HKernel.Loader
  ( LoadError
  , journalRootObservationJournal
  , journalRootObservationTransactionSources
  , loadJournalRootObservationFromSource
  )
import HKernel.Plan (CommittedOutgoingPlan, PlanId)
import HKernel.Plan.Journal
  ( ClassifiedPlanTransaction(..)
  , PlanJournal
  , PlanJournalError(..)
  , PlanLifecycleError
  , PlanReportProjectionError
  , admitPlanJournalFromResolvedJournal
  , admitPlanJournalFromResolvedSources
  , admitPlanRetirements
  , identifiedPlanId
  , planJournalTransactions
  , planJournalValue
  , projectCommittedOutgoingPlans
  , projectedCommittedOutgoingPlan
  )
import HKernel.Report.Config
  ( ReportConfiguration
  , parseReportConfiguration
  )

data HouseholdState = HouseholdState
  { householdStateRoot               :: HouseholdRoot
  , householdStatePaths              :: HouseholdSourcePaths
  , householdStateAccountsRegistry   :: AccountRegistry
  , householdStateActualJournal      :: ActualJournal
  , householdStatePlanJournal        :: PlanJournal
  , householdStateEntitlementHistory :: EnvelopeEntitlementHistory
  , householdStateEnvelopePolicy     :: CurrentEnvelopePolicy
  , householdStateConfiguration      :: HouseholdConfiguration
  , householdStateEnvelopeHistory    :: HouseholdEnvelopeHistory
  , householdStatePolicy             :: HouseholdPolicy
  , householdStateReportConfig       :: ReportConfiguration
  , householdStateIssues             :: [HouseholdIssue]
  , householdStateDailyScope         :: DailyTargetScope
  } deriving (Eq, Show)

data HouseholdWriteSnapshot = HouseholdWriteSnapshot
  { householdWriteSnapshotState             :: HouseholdState
  , householdWriteSnapshotAccountsSource    :: Text
  , householdWriteSnapshotActualSource      :: Text
  , householdWriteSnapshotPlanSource        :: Text
  , householdWriteSnapshotEntitlementSource :: Text
  , householdWriteSnapshotIssuesSource      :: Text
  } deriving (Eq, Show)

data HouseholdLoadError
  = HouseholdSourceReadFailed FilePath IOException
  | HouseholdAccountsParseFailed (NonEmpty AccountJournalError)
  | HouseholdActualLoadFailed LoadError
  | HouseholdActualParseFailed (NonEmpty ActualJournalError)
  | HouseholdAccountRegistryDisagreement
      { accountsJournalRegistry :: AccountRegistry
      , actualJournalRegistry   :: AccountRegistry
      }
  | HouseholdPlanLoadFailed LoadError
  | HouseholdPlanParseFailed (NonEmpty PlanJournalError)
  | HouseholdPlanRegistryDisagreement FilePath Text
  | HouseholdPlanLifecycleAdmissionFailed (NonEmpty PlanLifecycleError)
  | HouseholdEntitlementParseFailed (NonEmpty EntitlementJournalError)
  | HouseholdEnvelopePolicyParseFailed [Text]
  | HouseholdPolicyParseFailed [Text]
  | HouseholdEnvelopeHistoryParseFailed [Text]
  | HouseholdEnvelopeHistoryMissing
  | HouseholdEnvelopeHistoryReferenceFailed HouseholdEnvelopeHistoryReferenceError
  | HouseholdPolicyAccountValidationFailed (NonEmpty HouseholdPolicyAccountError)
  | HouseholdReportConfigParseFailed [Text]
  | HouseholdIssuesParseFailed (NonEmpty HouseholdIssueTSVError)
  | HouseholdDailyTargetPlanMetadataFailed (NonEmpty DailyTargetPlanJournalError)
  | HouseholdDailyTargetPlanProjectionFailed (NonEmpty PlanReportProjectionError)
  | HouseholdDailyTargetScopeFailed (NonEmpty DailyTargetSelectionError)
  | HouseholdPlanProjectionFailed (NonEmpty HouseholdSourceError)
  | HouseholdReportCalculationFailed (NonEmpty HouseholdSourceError)
  deriving (Show)

loadCanonicalHousehold
  :: HouseholdRoot
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdState)
loadCanonicalHousehold root =
  fmap (fmap householdWriteSnapshotState)
    (loadCanonicalHouseholdWriteSnapshot root)

loadCanonicalHouseholdWriteSnapshot
  :: HouseholdRoot
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdWriteSnapshot)
loadCanonicalHouseholdWriteSnapshot root = runExceptT $ do
  let paths = householdSourcePaths root

  accountsSource <- readHouseholdSourceExcept (householdAccountsJournalPath paths)
  accountsRegistry <- liftEither . first (pure . HouseholdAccountsParseFailed) $
    parseAccountJournal accountsSource

  actualSource <- readHouseholdSourceExcept (householdActualJournalPath paths)
  actualObservation <- ExceptT $ first (pure . HouseholdActualLoadFailed) <$>
    loadJournalRootObservationFromSource (householdActualJournalPath paths) actualSource
  actualJournal <- liftEither . first (pure . HouseholdActualParseFailed) $
    admitActualJournalFromResolvedSources
      (journalRootObservationJournal actualObservation)
      (journalRootObservationTransactionSources actualObservation)
  liftEither $ validateAccountRegistryAgreement
    accountsRegistry
    (journalAccountRegistry (actualJournalValue actualJournal))
    (HouseholdAccountRegistryDisagreement accountsRegistry)

  planSource <- readHouseholdSourceExcept (householdPlanJournalPath paths)
  planObservation <- ExceptT $ first (pure . HouseholdPlanLoadFailed) <$>
    loadJournalRootObservationFromSource (householdPlanJournalPath paths) planSource
  planJournal <- liftEither . first (pure . HouseholdPlanParseFailed) $
    admitPlanJournalFromResolvedSources
      (journalRootObservationJournal planObservation)
      (journalRootObservationTransactionSources planObservation)
  liftEither $ validateAccountRegistryAgreement
    accountsRegistry
    (journalAccountRegistry (planJournalValue planJournal))
    (\_ -> HouseholdPlanRegistryDisagreement
      (householdPlanJournalPath paths)
      "Plan journal AccountRegistry does not exactly match accounts.journal AccountRegistry")

  envelopePolicySource <- readHouseholdSourceExcept (householdEnvelopeConfigPath paths)
  (envelopePolicy, backingPolicy) <-
    liftEither . first (pure . HouseholdEnvelopePolicyParseFailed) $
      parseCurrentEnvelopeConfiguration envelopePolicySource

  householdPolicySource <- readHouseholdSourceExcept (householdPolicyConfigPath paths)
  configuration <- liftEither . first (pure . HouseholdPolicyParseFailed) $
    parseHouseholdConfiguration envelopePolicy backingPolicy householdPolicySource
  envelopeHistory <- liftEither $
    admitRequiredEnvelopeHistory
      accountsRegistry
      (planIds planJournal)
      (householdConfigurationPolicy configuration)
      householdPolicySource

  policy <- liftEither $
    validateHouseholdPolicyAndAccounts accountsRegistry configuration

  entitlementSource <- readHouseholdSourceExcept (householdEntitlementJournalPath paths)
  entitlementHistory <- liftEither . first (pure . HouseholdEntitlementParseFailed) $
    admitEntitlementJournal (householdEnvelopeRegistry envelopeHistory) entitlementSource

  reportConfigSource <- readHouseholdSourceExcept (householdReportConfigPath paths)
  reportConfig <- liftEither . first (pure . HouseholdReportConfigParseFailed) $
    parseReportConfiguration reportConfigSource

  issuesSource <- readHouseholdSourceExcept (householdIssuesPath paths)
  issues <- liftEither . first (pure . HouseholdIssuesParseFailed) $
    parseHouseholdIssues issuesSource

  state <- liftEither $ assembleCanonicalHouseholdState
    root paths accountsRegistry actualJournal planJournal entitlementHistory
    envelopePolicy configuration envelopeHistory policy reportConfig issues

  pure HouseholdWriteSnapshot
    { householdWriteSnapshotState = state
    , householdWriteSnapshotAccountsSource = accountsSource
    , householdWriteSnapshotActualSource = actualSource
    , householdWriteSnapshotPlanSource = planSource
    , householdWriteSnapshotEntitlementSource = entitlementSource
    , householdWriteSnapshotIssuesSource = issuesSource
    }

readHouseholdSourceExcept
  :: FilePath
  -> ExceptT (NonEmpty HouseholdLoadError) IO Text
readHouseholdSourceExcept path = ExceptT $ do
  result <- tryIOError (TIO.readFile path)
  pure $ case result of
    Left err -> Left (pure (HouseholdSourceReadFailed path err))
    Right content -> Right content

liftEither :: Applicative m => Either e a -> ExceptT e m a
liftEither = ExceptT . pure

validateAccountRegistryAgreement
  :: AccountRegistry
  -> AccountRegistry
  -> (AccountRegistry -> HouseholdLoadError)
  -> Either (NonEmpty HouseholdLoadError) ()
validateAccountRegistryAgreement expected actual mkErr
  | expected == actual = Right ()
  | otherwise = Left (pure (mkErr actual))

admitRequiredEnvelopeHistory
  :: AccountRegistry
  -> [PlanId]
  -> HouseholdPolicy
  -> Text
  -> Either (NonEmpty HouseholdLoadError) HouseholdEnvelopeHistory
admitRequiredEnvelopeHistory registry knownPlans policy source = do
  maybeHistory <- first (pure . HouseholdEnvelopeHistoryParseFailed)
    (parseHouseholdEnvelopeHistory source)
  history <- case maybeHistory of
    Nothing -> Left (pure HouseholdEnvelopeHistoryMissing)
    Just value -> Right value
  first (fmap HouseholdEnvelopeHistoryReferenceFailed)
    (admitHouseholdEnvelopeHistoryReferences
      registry knownPlans policy history)

planIds :: PlanJournal -> [PlanId]
planIds = map identifiedPlanId . planJournalTransactions

validateHouseholdPolicyAndAccounts
  :: AccountRegistry
  -> HouseholdConfiguration
  -> Either (NonEmpty HouseholdLoadError) HouseholdPolicy
validateHouseholdPolicyAndAccounts registry configuration = do
  let policy = householdConfigurationPolicy configuration
  first (pure . HouseholdPolicyAccountValidationFailed)
    (validateHouseholdPolicyAccounts registry policy)
  pure policy

assembleCanonicalHouseholdState
  :: HouseholdRoot
  -> HouseholdSourcePaths
  -> AccountRegistry
  -> ActualJournal
  -> PlanJournal
  -> EnvelopeEntitlementHistory
  -> CurrentEnvelopePolicy
  -> HouseholdConfiguration
  -> HouseholdEnvelopeHistory
  -> HouseholdPolicy
  -> ReportConfiguration
  -> [HouseholdIssue]
  -> Either (NonEmpty HouseholdLoadError) HouseholdState
assembleCanonicalHouseholdState root paths accountsRegistry actualJournal planJournal entitlementHistory envelopePolicy configuration envelopeHistory policy reportConfig issues = do
  _ <- first (pure . HouseholdPlanLifecycleAdmissionFailed)
    (admitPlanRetirements planJournal)
  dailyScope <- assembleDailyScope
    accountsRegistry
    (householdConfigurationDailyTargetAssets configuration)
    planJournal
  pure HouseholdState
    { householdStateRoot = root
    , householdStatePaths = paths
    , householdStateAccountsRegistry = accountsRegistry
    , householdStateActualJournal = actualJournal
    , householdStatePlanJournal = planJournal
    , householdStateEntitlementHistory = entitlementHistory
    , householdStateEnvelopePolicy = envelopePolicy
    , householdStateConfiguration = configuration
    , householdStateEnvelopeHistory = envelopeHistory
    , householdStatePolicy = policy
    , householdStateReportConfig = reportConfig
    , householdStateIssues = issues
    , householdStateDailyScope = dailyScope
    }

assembleDailyScope
  :: AccountRegistry
  -> [DailyTargetAssetSelection]
  -> PlanJournal
  -> Either (NonEmpty HouseholdLoadError) DailyTargetScope
assembleDailyScope registry assetSelections planJournal = do
  obligationSelections <- first (pure . HouseholdDailyTargetPlanMetadataFailed)
    (admitDailyTargetPlanJournalSelections planJournal)
  selectedPlans <- first (pure . HouseholdDailyTargetPlanProjectionFailed)
    (projectDailyTargetSelectedPlans planJournal obligationSelections)
  first (pure . HouseholdDailyTargetScopeFailed)
    (dailyTargetScopeFromSelections
      registry
      selectedPlans
      assetSelections
      obligationSelections)

-- | Apply the current outgoing obligation shape only after Daily Target source
-- evidence has declared a Plan relevant. Ordinary Plans remain admitted even
-- when the narrower Daily Target value cannot represent their Posting shape.
projectDailyTargetSelectedPlans
  :: PlanJournal
  -> [DailyTargetObligationSelection]
  -> Either (NonEmpty PlanReportProjectionError) [CommittedOutgoingPlan]
projectDailyTargetSelectedPlans planJournal selections =
  fmap (map projectedCommittedOutgoingPlan)
    (projectCommittedOutgoingPlans planJournal selectedTransactions)
  where
    selectedIds = Set.fromList
      [ declaredDailyTargetObligationPlanId
          (dailyTargetObligationSelectionDeclaration selection)
      | selection <- selections
      ]
    selectedTransactions =
      [ OutgoingPlanTransaction identified
      | identified <- planJournalTransactions planJournal
      , identifiedPlanId identified `Set.member` selectedIds
      ]

resolveInMemoryJournal
  :: Text
  -> Text
  -> Either (NonEmpty JournalError) Journal
resolveInMemoryJournal accountsText input = do
  document <- parseJournalDocument input
  accountsDocument <- parseJournalDocument accountsText
  let resolve include
        | includePath include == "accounts.journal" = Right accountsDocument
        | otherwise = Left (pure (JournalError 0 (UnresolvedInclude include)))
  resolved <- resolveJournalDocumentIncludes resolve document
  validateJournalDocument resolved

admitCanonicalHousehold
  :: HouseholdRoot
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> Either (NonEmpty HouseholdLoadError) HouseholdState
admitCanonicalHousehold root accountsText actualText planText entitlementText envelopePolicyText householdPolicyText reportConfigText issuesText = do
  let paths = householdSourcePaths root
  accountsRegistry <- first (pure . HouseholdAccountsParseFailed)
    (parseAccountJournal accountsText)

  resolvedActual <- first (pure . HouseholdActualParseFailed . fmap ActualJournalSyntaxError)
    (resolveInMemoryJournal accountsText actualText)
  actualJournal <- first (pure . HouseholdActualParseFailed)
    (admitActualJournalFromResolvedJournal resolvedActual actualText)
  validateAccountRegistryAgreement
    accountsRegistry
    (journalAccountRegistry (actualJournalValue actualJournal))
    (HouseholdAccountRegistryDisagreement accountsRegistry)

  resolvedPlan <- first (pure . HouseholdPlanParseFailed . fmap PlanJournalSyntaxError)
    (resolveInMemoryJournal accountsText planText)
  planJournal <- first (pure . HouseholdPlanParseFailed)
    (admitPlanJournalFromResolvedJournal resolvedPlan planText)
  validateAccountRegistryAgreement
    accountsRegistry
    (journalAccountRegistry (planJournalValue planJournal))
    (\_ -> HouseholdPlanRegistryDisagreement
      (householdPlanJournalPath paths)
      "Plan journal AccountRegistry does not exactly match accounts.journal AccountRegistry")

  (envelopePolicy, backingPolicy) <-
    first (pure . HouseholdEnvelopePolicyParseFailed)
      (parseCurrentEnvelopeConfiguration envelopePolicyText)
  configuration <- first (pure . HouseholdPolicyParseFailed)
    (parseHouseholdConfiguration envelopePolicy backingPolicy householdPolicyText)
  envelopeHistory <- admitRequiredEnvelopeHistory
    accountsRegistry
    (planIds planJournal)
    (householdConfigurationPolicy configuration)
    householdPolicyText
  policy <- validateHouseholdPolicyAndAccounts
    accountsRegistry configuration

  entitlementHistory <- first (pure . HouseholdEntitlementParseFailed)
    (admitEntitlementJournal (householdEnvelopeRegistry envelopeHistory) entitlementText)

  reportConfig <- first (pure . HouseholdReportConfigParseFailed)
    (parseReportConfiguration reportConfigText)
  issues <- first (pure . HouseholdIssuesParseFailed)
    (parseHouseholdIssues issuesText)

  assembleCanonicalHouseholdState
    root paths accountsRegistry actualJournal planJournal entitlementHistory
    envelopePolicy configuration envelopeHistory policy reportConfig issues

buildHouseholdReportSurfaceFromHousehold
  :: Day
  -> HouseholdState
  -> Either (NonEmpty HouseholdLoadError) HouseholdReportSurface
buildHouseholdReportSurfaceFromHousehold observation state = do
  admittedPlans <- first (pure . HouseholdPlanProjectionFailed)
    (admitPlanJournal (householdStatePlanJournal state))
  let history = householdStateEnvelopeHistory state
  first (pure . HouseholdReportCalculationFailed)
    (buildHouseholdReportSurfaceFromAdmitted
      observation
      (householdStateActualJournal state)
      (householdStatePlanJournal state)
      (householdStatePolicy state)
      (householdExpenseRoutingHistory history)
      (householdFulfillmentRoutingHistory history)
      admittedPlans
      (householdStateEntitlementHistory state)
      (householdStateIssues state)
      (householdStateDailyScope state))