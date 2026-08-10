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
import Data.Bifunctor (first)
import qualified Data.List.NonEmpty as NonEmpty
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
import HKernel.Loader (LoadError, loadJournalFromRootSource)
import HKernel.Plan.Journal
  ( PlanJournal
  , PlanJournalError(..)
  , admitPlanJournalFromResolvedJournal
  , planJournalValue
  )
import HKernel.Report.Config
  ( ReportConfiguration
  , parseReportConfiguration
  )
import HKernel.Spike.HouseholdReport
  ( HouseholdReportSurface
  , HouseholdSourceError
  , admitPlanJournal
  , admittedOutgoingPlanValues
  , buildHouseholdReportSurfaceFromAdmitted
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
-- This is deliberately narrower than a repository/session abstraction. Actual,
-- Plan, Budget, and Issues are retained because current mutation paths need
-- their exact roots and typed Household meaning to share the same expected-old
-- observation; other source families should join only when a concrete operation
-- needs the same ownership.
data HouseholdWriteSnapshot = HouseholdWriteSnapshot
  { householdWriteSnapshotState        :: HouseholdState
  , householdWriteSnapshotActualSource :: Text
  , householdWriteSnapshotPlanSource   :: Text
  , householdWriteSnapshotBudgetSource :: Text
  , householdWriteSnapshotIssuesSource :: Text
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
-- Journal roots are read once here, then resolved with
-- 'loadJournalFromRootSource'. Issues are likewise parsed from the exact bytes
-- retained for publication. This prevents the invalid temporal shape
-- @HouseholdState from observation A / expected root bytes from observation B@
-- without restricting ordinary include graphs.
loadCanonicalHouseholdWriteSnapshot
  :: HouseholdRoot
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdWriteSnapshot)
loadCanonicalHouseholdWriteSnapshot root = do
  let paths = householdSourcePaths root
  accountsContentResult <- readHouseholdSource (householdAccountsJournalPath paths)
  case accountsContentResult of
    Left errors -> pure (Left errors)
    Right accountsContent -> case parseAccountJournal accountsContent of
      Left errors -> pure (Left (pure (HouseholdAccountsParseFailed errors)))
      Right accountsRegistry -> loadActual root paths accountsRegistry

loadActual
  :: HouseholdRoot
  -> HouseholdSourcePaths
  -> AccountRegistry
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdWriteSnapshot)
loadActual root paths accountsRegistry = do
  rootTextResult <- readHouseholdSource (householdActualJournalPath paths)
  case rootTextResult of
    Left errors -> pure (Left errors)
    Right rootText -> do
      loaded <- loadJournalFromRootSource (householdActualJournalPath paths) rootText
      case loaded of
        Left err -> pure (Left (pure (HouseholdActualLoadFailed err)))
        Right resolved -> case admitActualJournalFromResolvedJournal resolved rootText of
          Left errors -> pure (Left (pure (HouseholdActualParseFailed errors)))
          Right actualJournal
            | accountsRegistry /= journalAccountRegistry (actualJournalValue actualJournal) ->
                pure (Left (pure (HouseholdAccountRegistryDisagreement
                  accountsRegistry
                  (journalAccountRegistry (actualJournalValue actualJournal)))))
            | otherwise -> loadPlan root paths accountsRegistry rootText actualJournal

loadPlan
  :: HouseholdRoot
  -> HouseholdSourcePaths
  -> AccountRegistry
  -> Text
  -> ActualJournal
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdWriteSnapshot)
loadPlan root paths accountsRegistry actualRootText actualJournal = do
  rootTextResult <- readHouseholdSource (householdPlanJournalPath paths)
  case rootTextResult of
    Left errors -> pure (Left errors)
    Right rootText -> do
      loaded <- loadJournalFromRootSource (householdPlanJournalPath paths) rootText
      case loaded of
        Left err -> pure (Left (pure (HouseholdPlanLoadFailed err)))
        Right resolved -> case admitPlanJournalFromResolvedJournal resolved rootText of
          Left errors -> pure (Left (pure (HouseholdPlanParseFailed errors)))
          Right planJournal
            | accountsRegistry /= journalAccountRegistry (planJournalValue planJournal) ->
                pure (Left (pure (HouseholdPlanRegistryDisagreement
                  (householdPlanJournalPath paths)
                  "Plan journal AccountRegistry does not exactly match accounts.journal AccountRegistry")))
            | otherwise -> loadBudget
                root
                paths
                accountsRegistry
                actualRootText
                actualJournal
                rootText
                planJournal

loadBudget
  :: HouseholdRoot
  -> HouseholdSourcePaths
  -> AccountRegistry
  -> Text
  -> ActualJournal
  -> Text
  -> PlanJournal
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdWriteSnapshot)
loadBudget root paths accountsRegistry actualRootText actualJournal planRootText planJournal = do
  rootTextResult <- readHouseholdSource (householdBudgetJournalPath paths)
  case rootTextResult of
    Left errors -> pure (Left errors)
    Right budgetRootText -> do
      loaded <- loadJournalFromRootSource
        (householdBudgetJournalPath paths)
        budgetRootText
      case loaded of
        Left err -> pure (Left (pure (HouseholdBudgetLoadFailed err)))
        Right budgetJournal
          | accountsRegistry /= journalAccountRegistry budgetJournal ->
              pure (Left (pure (HouseholdBudgetRegistryDisagreement
                (householdBudgetJournalPath paths)
                "Budget journal AccountRegistry does not exactly match accounts.journal AccountRegistry")))
          | otherwise -> case admitHouseholdBudgetMovementJournalFromResolvedJournal
              budgetJournal budgetRootText of
              Left errors -> pure (Left (pure (HouseholdBudgetMovementAdmitFailed errors)))
              Right budgetMovementJournal ->
                loadConfigsAndIssues
                  root
                  paths
                  accountsRegistry
                  actualRootText
                  actualJournal
                  planRootText
                  planJournal
                  budgetRootText
                  budgetMovementJournal

loadConfigsAndIssues
  :: HouseholdRoot
  -> HouseholdSourcePaths
  -> AccountRegistry
  -> Text
  -> ActualJournal
  -> Text
  -> PlanJournal
  -> Text
  -> HouseholdBudgetMovementJournal
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdWriteSnapshot)
loadConfigsAndIssues root paths accountsRegistry actualRootText actualJournal planRootText planJournal budgetRootText budgetMovementJournal = do
  budgetTextResult <- readHouseholdSource (householdBudgetConfigPath paths)
  case budgetTextResult of
    Left errors -> pure (Left errors)
    Right budgetText -> case parseBudgetPolicy budgetText of
      Left errors -> pure (Left (pure (HouseholdBudgetPolicyParseFailed errors)))
      Right budgetPolicy -> do
        householdTextResult <- readHouseholdSource (householdPolicyConfigPath paths)
        case householdTextResult of
          Left errors -> pure (Left errors)
          Right householdText -> case parseHouseholdConfiguration budgetPolicy householdText of
            Left errors -> pure (Left (pure (HouseholdPolicyParseFailed errors)))
            Right configuration -> do
              let policy = householdConfigurationPolicy configuration
              case validateHouseholdPolicyAccounts accountsRegistry policy of
                Left errors -> pure (Left (pure (HouseholdPolicyAccountValidationFailed errors)))
                Right validatedPolicy -> case validateHouseholdAccountPolicy accountsRegistry
                    (householdConfigurationAccountPolicy configuration) of
                  Left errors -> pure (Left errors)
                  Right () -> do
                    reportTextResult <- readHouseholdSource (householdReportConfigPath paths)
                    case reportTextResult of
                      Left errors -> pure (Left errors)
                      Right reportText -> case parseReportConfiguration reportText of
                        Left errors -> pure (Left (pure (HouseholdReportConfigParseFailed errors)))
                        Right reportConfig -> do
                          issuesTextResult <- readHouseholdSource (householdIssuesPath paths)
                          case issuesTextResult of
                            Left errors -> pure (Left errors)
                            Right issuesText -> case parseHouseholdIssues issuesText of
                              Left errors -> pure (Left (pure (HouseholdIssuesParseFailed errors)))
                              Right issues -> case assembleDailyScope
                                  accountsRegistry
                                  (householdConfigurationDailyTargetAssets configuration)
                                  planJournal of
                                Left errors -> pure (Left errors)
                                Right dailyScope ->
                                  let state = HouseholdState
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
                                  in pure (Right HouseholdWriteSnapshot
                                      { householdWriteSnapshotState = state
                                      , householdWriteSnapshotActualSource = actualRootText
                                      , householdWriteSnapshotPlanSource = planRootText
                                      , householdWriteSnapshotBudgetSource = budgetRootText
                                      , householdWriteSnapshotIssuesSource = issuesText
                                      })

readHouseholdSource
  :: FilePath
  -> IO (Either (NonEmpty HouseholdLoadError) Text)
readHouseholdSource path = do
  result <- tryIOError (TIO.readFile path)
  pure $ case result of
    Left err -> Left (pure (HouseholdSourceReadFailed path err))
    Right content -> Right content

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
  let actualRegistry = journalAccountRegistry (actualJournalValue actualJournal)
  if accountsRegistry == actualRegistry
    then Right ()
    else Left (pure (HouseholdAccountRegistryDisagreement accountsRegistry actualRegistry))

  resolvedPlan <- first (pure . HouseholdPlanParseFailed . fmap PlanJournalSyntaxError)
    (resolveInMemoryJournal accountsText planText)
  planJournal <- first (pure . HouseholdPlanParseFailed)
    (admitPlanJournalFromResolvedJournal resolvedPlan planText)
  let planRegistry = journalAccountRegistry (planJournalValue planJournal)
  if accountsRegistry == planRegistry
    then Right ()
    else Left (pure (HouseholdPlanRegistryDisagreement
      (householdPlanJournalPath paths)
      "Plan journal AccountRegistry does not exactly match accounts.journal AccountRegistry"))

  budgetJournal <- first (pure . HouseholdBudgetParseFailed)
    (resolveInMemoryJournal accountsText budgetText)
  let budgetRegistry = journalAccountRegistry budgetJournal
  if accountsRegistry == budgetRegistry
    then Right ()
    else Left (pure (HouseholdBudgetRegistryDisagreement
      (householdBudgetJournalPath paths)
      "Budget journal AccountRegistry does not exactly match accounts.journal AccountRegistry"))
  budgetMovementJournal <- first (pure . HouseholdBudgetMovementAdmitFailed)
    (admitHouseholdBudgetMovementJournalFromResolvedJournal budgetJournal budgetText)

  budgetPolicy <- first (pure . HouseholdBudgetPolicyParseFailed)
    (parseBudgetPolicy budgetPolicyText)
  configuration <- first (pure . HouseholdPolicyParseFailed)
    (parseHouseholdConfiguration budgetPolicy householdPolicyText)
  let policy = householdConfigurationPolicy configuration
  validatedPolicy <- first (pure . HouseholdPolicyAccountValidationFailed)
    (validateHouseholdPolicyAccounts accountsRegistry policy)
  validateHouseholdAccountPolicy accountsRegistry
    (householdConfigurationAccountPolicy configuration)
  reportConfig <- first (pure . HouseholdReportConfigParseFailed)
    (parseReportConfiguration reportConfigText)
  issues <- first (pure . HouseholdIssuesParseFailed)
    (parseHouseholdIssues issuesText)
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
