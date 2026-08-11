{-# LANGUAGE OverloadedStrings #-}

-- | Pure admission and IO bootstrap for a canonical Household application state.
--
-- Delivery adapters (CLI, TUI, Report launchers) receive one 'HouseholdRoot',
-- resolve canonical file paths, and load the 8 canonical files into a typed
-- 'HouseholdState'. All domain operations and UI projections consume this
-- state without re-parsing raw files or invoking intermediate shell hubs.
module HKernel.Household.Application
  ( HouseholdState(..)
  , householdStateBudgetJournal
  , householdStateBudgetMovements
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
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import System.IO.Error (tryIOError)

import HKernel.Account
  ( AccountRegistry
  , AccountType(..)
  , accountTypeFor
  )
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
import HKernel.Budget.Config (parseBudgetPolicy)
import HKernel.Budget.Policy (BudgetPolicy)
import HKernel.Household.AccountProfile
  ( HouseholdAccountPolicy
  , householdAssetClassByAccount
  , householdBudgetGroupByAccount
  , householdBudgetKindByAccount
  , householdEnvelopeRoleByAccount
  , householdSpendClassByAccount
  )
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement
  , HouseholdBudgetMovementJournal
  , HouseholdBudgetMovementJournalError
  , admitHouseholdBudgetMovementJournalFromResolvedJournal
  , admitHouseholdBudgetMovementJournalFromResolvedSources
  , householdBudgetMovementJournalMovements
  , householdBudgetMovementJournalValue
  )
import HKernel.Household.Config
  ( HouseholdConfiguration
  , householdConfigurationAccountPolicy
  , householdConfigurationDailyTargetAssets
  , householdConfigurationPolicy
  , parseHouseholdConfiguration
  )
import HKernel.Household.DailyTarget
  ( DailyTargetAssetSelection
  , DailyTargetPlanJournalError
  , DailyTargetScope
  , DailyTargetSelectionError
  , admitDailyTargetPlanJournalSelections
  , dailyTargetScopeFromSelections
  )
import HKernel.Household.Issue.TSV
  ( HouseholdIssueTSVError
  , parseHouseholdIssues
  )
import HKernel.Household.Policy
  ( AccountValidatedHouseholdPolicy
  , HouseholdPolicy
  , HouseholdPolicyAccountError
  , validateHouseholdPolicyAccounts
  )
import HKernel.Household.Report
  ( HouseholdReportSurface
  , HouseholdSourceError
  , admitPlanJournal
  , admittedOutgoingPlanValues
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
import HKernel.Plan.Journal
  ( PlanJournal
  , PlanJournalError(..)
  , admitPlanJournalFromResolvedJournal
  , admitPlanJournalFromResolvedSources
  , planJournalValue
  )
import HKernel.Report.Config
  ( ReportConfiguration
  , parseReportConfiguration
  )

-- | The canonical Household application state loaded from the 8 canonical paths.
data HouseholdState = HouseholdState
  { householdStateRoot                  :: HouseholdRoot
  , householdStatePaths                 :: HouseholdSourcePaths
  , householdStateAccountsRegistry      :: AccountRegistry
  , householdStateActualJournal         :: ActualJournal
  , householdStatePlanJournal           :: PlanJournal
  , householdStateBudgetMovementJournal :: HouseholdBudgetMovementJournal
  , householdStateBudgetPolicy          :: BudgetPolicy
  , householdStateConfiguration         :: HouseholdConfiguration
  , householdStatePolicy                :: HouseholdPolicy
  , householdStateValidatedPolicy       :: AccountValidatedHouseholdPolicy
  , householdStateReportConfig          :: ReportConfiguration
  , householdStateIssues                :: [HouseholdIssue]
  , householdStateDailyScope            :: DailyTargetScope
  } deriving (Eq, Show)

-- | Compatibility/read projection for callers that need accounting Budget
-- Journal meaning but do not need root metadata evidence.
householdStateBudgetJournal :: HouseholdState -> Journal
householdStateBudgetJournal =
  householdBudgetMovementJournalValue . householdStateBudgetMovementJournal

-- | Compatibility/read projection for report and delivery callers that need
-- only ordered household Budget movement facts.
householdStateBudgetMovements :: HouseholdState -> [HouseholdBudgetMovement]
householdStateBudgetMovements =
  householdBudgetMovementJournalMovements . householdStateBudgetMovementJournal

-- | One admitted Household observation together with the exact root bytes used
-- by current coordinated Editor operations.
--
-- This is deliberately narrower than a repository/session abstraction.
-- Accounts, Actual, Plan, Budget, and Issues are retained because current
-- mutation paths need their exact roots and typed Household meaning to share
-- the same expected-old observation; other source families should join only
-- when a concrete operation needs the same ownership.
data HouseholdWriteSnapshot = HouseholdWriteSnapshot
  { householdWriteSnapshotState          :: HouseholdState
  , householdWriteSnapshotAccountsSource :: Text
  , householdWriteSnapshotActualSource   :: Text
  , householdWriteSnapshotPlanSource     :: Text
  , householdWriteSnapshotBudgetSource   :: Text
  , householdWriteSnapshotIssuesSource   :: Text
  } deriving (Eq, Show)

-- | Errors during canonical Household loading.
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
  | HouseholdBudgetLoadFailed LoadError
  | HouseholdBudgetParseFailed (NonEmpty JournalError)
  | HouseholdBudgetMovementAdmitFailed (NonEmpty HouseholdBudgetMovementJournalError)
  | HouseholdBudgetRegistryDisagreement FilePath Text
  | HouseholdBudgetPolicyParseFailed [Text]
  | HouseholdPolicyParseFailed [Text]
  | HouseholdPolicyAccountValidationFailed (NonEmpty HouseholdPolicyAccountError)
  | HouseholdAccountPolicyRegistryDisagreement Text
  | HouseholdReportConfigParseFailed [Text]
  | HouseholdIssuesParseFailed (NonEmpty HouseholdIssueTSVError)
  | HouseholdDailyTargetPlanMetadataFailed (NonEmpty DailyTargetPlanJournalError)
  | HouseholdDailyTargetScopeFailed (NonEmpty DailyTargetSelectionError)
  | HouseholdPlanProjectionFailed (NonEmpty HouseholdSourceError)
  | HouseholdReportCalculationFailed (NonEmpty HouseholdSourceError)
  deriving (Show)

-- | Load one canonical Household root from disk into a typed 'HouseholdState'.
--
-- The ordinary read-only API projects from the same snapshot loader used by
-- mutation delivery, so there is only one filesystem admission algorithm.
loadCanonicalHousehold
  :: HouseholdRoot
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdState)
loadCanonicalHousehold root =
  fmap (fmap householdWriteSnapshotState)
    (loadCanonicalHouseholdWriteSnapshot root)

-- | Load one canonical Household observation and retain the exact mutable root
-- bytes from which its typed meaning was admitted.
--
-- Journal roots are read once here, then each exact root is parsed once into a
-- sealed Loader observation containing resolved accounting meaning and root-only
-- transaction source evidence. Issues are likewise parsed from the exact bytes
-- retained for publication. This prevents the invalid temporal shape
-- @HouseholdState from observation A / expected root bytes from observation B@
-- without restricting ordinary include graphs.
loadCanonicalHouseholdWriteSnapshot
  :: HouseholdRoot
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdWriteSnapshot)
loadCanonicalHouseholdWriteSnapshot root = runExceptT $ do
  let paths = householdSourcePaths root

  -- 1. accounts.journal
  accountsSource <- readHouseholdSourceExcept (householdAccountsJournalPath paths)
  accountsRegistry <- liftEither . first (pure . HouseholdAccountsParseFailed) $
    parseAccountJournal accountsSource

  -- 2. actual.journal
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

  -- 3. plan.journal
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

  -- 4. budget.journal
  budgetSource <- readHouseholdSourceExcept (householdBudgetJournalPath paths)
  budgetObservation <- ExceptT $ first (pure . HouseholdBudgetLoadFailed) <$>
    loadJournalRootObservationFromSource (householdBudgetJournalPath paths) budgetSource
  let budgetJournal = journalRootObservationJournal budgetObservation
      budgetSources = journalRootObservationTransactionSources budgetObservation
  liftEither $ validateAccountRegistryAgreement
    accountsRegistry
    (journalAccountRegistry budgetJournal)
    (\_ -> HouseholdBudgetRegistryDisagreement
      (householdBudgetJournalPath paths)
      "Budget journal AccountRegistry does not exactly match accounts.journal AccountRegistry")
  budgetMovementJournal <- liftEither . first (pure . HouseholdBudgetMovementAdmitFailed) $
    admitHouseholdBudgetMovementJournalFromResolvedSources budgetJournal budgetSources

  -- 5. budget.toml
  budgetPolicySource <- readHouseholdSourceExcept (householdBudgetConfigPath paths)
  budgetPolicy <- liftEither . first (pure . HouseholdBudgetPolicyParseFailed) $
    parseBudgetPolicy budgetPolicySource

  -- 6. household.toml
  householdPolicySource <- readHouseholdSourceExcept (householdPolicyConfigPath paths)
  configuration <- liftEither . first (pure . HouseholdPolicyParseFailed) $
    parseHouseholdConfiguration budgetPolicy householdPolicySource

  -- 7. report.toml
  reportConfigSource <- readHouseholdSourceExcept (householdReportConfigPath paths)
  reportConfig <- liftEither . first (pure . HouseholdReportConfigParseFailed) $
    parseReportConfiguration reportConfigSource

  -- 8. issues.tsv
  issuesSource <- readHouseholdSourceExcept (householdIssuesPath paths)
  issues <- liftEither . first (pure . HouseholdIssuesParseFailed) $
    parseHouseholdIssues issuesSource

  -- 9. Post-admission validation & state assembly
  state <- liftEither $ assembleCanonicalHouseholdState
    root
    paths
    accountsRegistry
    actualJournal
    planJournal
    budgetMovementJournal
    budgetPolicy
    configuration
    reportConfig
    issues

  pure HouseholdWriteSnapshot
    { householdWriteSnapshotState = state
    , householdWriteSnapshotAccountsSource = accountsSource
    , householdWriteSnapshotActualSource = actualSource
    , householdWriteSnapshotPlanSource = planSource
    , householdWriteSnapshotBudgetSource = budgetSource
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

assembleCanonicalHouseholdState
  :: HouseholdRoot
  -> HouseholdSourcePaths
  -> AccountRegistry
  -> ActualJournal
  -> PlanJournal
  -> HouseholdBudgetMovementJournal
  -> BudgetPolicy
  -> HouseholdConfiguration
  -> ReportConfiguration
  -> [HouseholdIssue]
  -> Either (NonEmpty HouseholdLoadError) HouseholdState
assembleCanonicalHouseholdState root paths accountsRegistry actualJournal planJournal budgetMovementJournal budgetPolicy configuration reportConfig issues = do
  let policy = householdConfigurationPolicy configuration
  validatedPolicy <- first (pure . HouseholdPolicyAccountValidationFailed)
    (validateHouseholdPolicyAccounts accountsRegistry policy)
  validateHouseholdAccountPolicy accountsRegistry
    (householdConfigurationAccountPolicy configuration)
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
    , householdStateBudgetMovementJournal = budgetMovementJournal
    , householdStateBudgetPolicy = budgetPolicy
    , householdStateConfiguration = configuration
    , householdStatePolicy = policy
    , householdStateValidatedPolicy = validatedPolicy
    , householdStateReportConfig = reportConfig
    , householdStateIssues = issues
    , householdStateDailyScope = dailyScope
    }

validateHouseholdAccountPolicy
  :: AccountRegistry
  -> Maybe HouseholdAccountPolicy
  -> Either (NonEmpty HouseholdLoadError) ()
validateHouseholdAccountPolicy _ Nothing = Right ()
validateHouseholdAccountPolicy registry (Just policy) =
  case mismatches of
    [] -> Right ()
    label : _ -> Left (pure (HouseholdAccountPolicyRegistryDisagreement label))
  where
    allHaveType expected accounts =
      all ((== Just expected) . (`accountTypeFor` registry)) accounts
    checks =
      [ ("asset classification", Asset, Map.keys (householdAssetClassByAccount policy))
      , ("Budget kind classification", Budget, Map.keys (householdBudgetKindByAccount policy))
      , ("Budget envelope-role classification", Budget, Map.keys (householdEnvelopeRoleByAccount policy))
      , ("Budget group classification", Budget, Map.keys (householdBudgetGroupByAccount policy))
      , ("Expense spend classification", Expense, Map.keys (householdSpendClassByAccount policy))
      ]
    mismatches =
      [ label
      | (label, expected, accounts) <- checks
      , not (allHaveType expected accounts)
      ]

assembleDailyScope
  :: AccountRegistry
  -> [DailyTargetAssetSelection]
  -> PlanJournal
  -> Either (NonEmpty HouseholdLoadError) DailyTargetScope
assembleDailyScope registry assetSelections planJournal = do
  admittedPlans <- first (pure . HouseholdPlanProjectionFailed)
    (admitPlanJournal planJournal)
  obligationSelections <- first (pure . HouseholdDailyTargetPlanMetadataFailed)
    (admitDailyTargetPlanJournalSelections planJournal)
  first (pure . HouseholdDailyTargetScopeFailed)
    (dailyTargetScopeFromSelections
      registry
      (admittedOutgoingPlanValues admittedPlans)
      assetSelections
      obligationSelections)

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

-- | Parse pure text of all 8 canonical Household files in memory.
admitCanonicalHousehold
  :: HouseholdRoot
  -> Text -- ^ accounts.journal
  -> Text -- ^ actual.journal
  -> Text -- ^ plan.journal
  -> Text -- ^ budget.journal
  -> Text -- ^ budget.toml
  -> Text -- ^ household.toml
  -> Text -- ^ report.toml
  -> Text -- ^ issues.tsv
  -> Either (NonEmpty HouseholdLoadError) HouseholdState
admitCanonicalHousehold root accountsText actualText planText budgetText budgetPolicyText householdPolicyText reportConfigText issuesText = do
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

  budgetJournal <- first (pure . HouseholdBudgetParseFailed)
    (resolveInMemoryJournal accountsText budgetText)
  validateAccountRegistryAgreement
    accountsRegistry
    (journalAccountRegistry budgetJournal)
    (\_ -> HouseholdBudgetRegistryDisagreement
      (householdBudgetJournalPath paths)
      "Budget journal AccountRegistry does not exactly match accounts.journal AccountRegistry")
  budgetMovementJournal <- first (pure . HouseholdBudgetMovementAdmitFailed)
    (admitHouseholdBudgetMovementJournalFromResolvedJournal budgetJournal budgetText)

  budgetPolicy <- first (pure . HouseholdBudgetPolicyParseFailed)
    (parseBudgetPolicy budgetPolicyText)
  configuration <- first (pure . HouseholdPolicyParseFailed)
    (parseHouseholdConfiguration budgetPolicy householdPolicyText)
  reportConfig <- first (pure . HouseholdReportConfigParseFailed)
    (parseReportConfiguration reportConfigText)
  issues <- first (pure . HouseholdIssuesParseFailed)
    (parseHouseholdIssues issuesText)

  assembleCanonicalHouseholdState
    root
    paths
    accountsRegistry
    actualJournal
    planJournal
    budgetMovementJournal
    budgetPolicy
    configuration
    reportConfig
    issues

-- | Build the report surface using the shared typed calculation owner.
buildHouseholdReportSurfaceFromHousehold
  :: Day
  -> HouseholdState
  -> Either (NonEmpty HouseholdLoadError) HouseholdReportSurface
buildHouseholdReportSurfaceFromHousehold observation state = do
  admittedPlans <- first (pure . HouseholdPlanProjectionFailed)
    (admitPlanJournal (householdStatePlanJournal state))
  first (pure . HouseholdReportCalculationFailed)
    (buildHouseholdReportSurfaceFromAdmitted
      observation
      (householdStateActualJournal state)
      (householdStatePolicy state)
      (householdStateValidatedPolicy state)
      admittedPlans
      (householdStateBudgetMovements state)
      (householdStateIssues state)
      (householdStateDailyScope state))
