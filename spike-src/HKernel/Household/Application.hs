{-# LANGUAGE OverloadedStrings #-}

-- | Pure admission and IO bootstrap for a canonical Household application state.
--
-- Delivery adapters (CLI, TUI, Report launchers) receive one 'HouseholdRoot',
-- resolve canonical file paths, and load the 8 canonical files into a typed
-- 'HouseholdState'. All domain operations and UI projections consume this
-- state without re-parsing raw files or invoking intermediate shell hubs.
module HKernel.Household.Application
  ( HouseholdState(..)
  , HouseholdLoadError(..)
  , loadCanonicalHousehold
  , admitCanonicalHousehold
  , buildHouseholdReportSurfaceFromHousehold
  ) where

import Control.Exception (IOException)
import Data.Bifunctor (first)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import System.Directory (doesFileExist)
import System.FilePath ((</>), takeDirectory)
import System.IO.Error (tryIOError)

import HKernel.Account
  ( Account
  , AccountRegistry
  , AccountType(..)
  , accountDeclarations
  , accountName
  , accountTypeFor
  , declaredAccount
  , declaredAccountType
  , lookupAccountDeclaration
  )
import HKernel.Account.Journal
  ( AccountJournalError
  , parseAccountJournal
  )
import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , actualJournalCompletionDeclarations
  , actualJournalIdentifiedTransactions
  , actualJournalValue
  , parseActualJournal
  )
import HKernel.Application.Config
  ( HouseholdRoot
  , HouseholdSourcePaths(..)
  , householdSourcePaths
  )
import HKernel.Budget.Config (parseBudgetPolicy)
import HKernel.Budget.Policy (BudgetPolicy)
import HKernel.Engine (journalEntries, entryAccount, entryAmount, entryDate)
import HKernel.Household.Backing
  ( HouseholdBackingPlan(..)
  , deriveHouseholdBacking
  )
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement(..)
  , HouseholdBudgetMovementJournalError
  , admitHouseholdBudgetMovementJournal
  )
import HKernel.Household.Config (parseHouseholdPolicy)
import HKernel.Household.DailyTarget
  ( DailyTargetScope
  , DailyTargetScopeId
  , DailyTargetSelectionError
  , dailyTargetScopeFromSelections
  , deriveDailyTarget
  , mkDailyTargetScopeId
  , parseDailyTargetPlanJournalSelections
  , selectDailyTargetAsset
  )
import HKernel.Household.DailyTarget.TSV (parseDailyTargetScope)
import HKernel.Household.Issue.TSV (HouseholdIssueTSVError, parseHouseholdIssues)
import HKernel.Household.Policy
  ( AccountValidatedHouseholdPolicy
  , HouseholdPolicy
  , HouseholdPolicyAccountError
  , householdCycleIncomeAccount
  , householdPolicyCycle
  , validateHouseholdPolicyAccounts
  )
import HKernel.HouseholdIssue (HouseholdIssue)
import HKernel.Journal
  ( Journal
  , journalAccountRegistry
  )
import HKernel.Ledger
  ( postingAccount
  , postingAmount
  , transactionDate
  , transactionPostings
  )
import HKernel.Loader (LoadError, loadJournal)
import HKernel.Money (amountQuantity, zeroQuantity)
import HKernel.Period (Period, mkPeriod, periodContains)
import HKernel.Plan (CommittedOutgoingPlan, PlanId, committedPlanAmount, committedPlanDate, committedPlanDirection, committedPlanId, declaredOutgoingPaymentDirection, declaredPaymentDestination, declaredPaymentSource, planIdText)
import HKernel.Plan.Completion
  ( PlanCompletionDeclaration
  , declaredCompletionPlanId
  , resolveOpenCommittedOutgoingPlans
  )
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , PlanJournal
  , PlanJournalError
  , ProjectedCommittedOutgoingPlan
  , classifiedIncomingPlanTransactions
  , classifyPlanJournal
  , identifiedPlanId
  , identifiedPlanTransaction
  , parsePlanJournal
  , planJournalValue
  , projectCommittedOutgoingPlans
  , projectedCommittedOutgoingPlan
  )
import HKernel.Report.Config (ReportConfiguration, parseReportConfiguration)
import HKernel.Report.CycleAccounts (cycleAccounts)
import HKernel.Spike.HouseholdConsumption
  ( HouseholdBudgetError
  , deriveHouseholdBudgetObservation
  , householdBudgetConsumption
  , householdBudgetEntitlement
  , householdBudgetObservationPolicy
  , householdBudgetRemaining
  )
import HKernel.Spike.HouseholdReport
  ( HouseholdReportSurface(..)
  )

-- | The canonical Household application state loaded from the 8 canonical paths.
data HouseholdState = HouseholdState
  { householdStateRoot             :: HouseholdRoot
  , householdStatePaths            :: HouseholdSourcePaths
  , householdStateAccountsRegistry :: AccountRegistry
  , householdStateActualJournal    :: ActualJournal
  , householdStatePlanJournal      :: PlanJournal
  , householdStateBudgetJournal    :: Journal
  , householdStateBudgetMovements  :: [HouseholdBudgetMovement]
  , householdStateBudgetPolicy     :: BudgetPolicy
  , householdStatePolicy           :: HouseholdPolicy
  , householdStateValidatedPolicy  :: AccountValidatedHouseholdPolicy
  , householdStateReportConfig     :: ReportConfiguration
  , householdStateIssues          :: [HouseholdIssue]
  , householdStateDailyScope       :: DailyTargetScope
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
  | HouseholdBudgetMovementAdmitFailed (NonEmpty HouseholdBudgetMovementJournalError)
  | HouseholdBudgetRegistryDisagreement FilePath Text
  | HouseholdBudgetPolicyParseFailed [Text]
  | HouseholdPolicyParseFailed [Text]
  | HouseholdPolicyAccountValidationFailed (NonEmpty HouseholdPolicyAccountError)
  | HouseholdReportConfigParseFailed [Text]
  | HouseholdIssuesParseFailed (NonEmpty HouseholdIssueTSVError)
  | HouseholdDailyTargetScopeFailed (NonEmpty DailyTargetSelectionError)
  | HouseholdPlanAnalysisFailed Text
  | HouseholdCycleError Text
  | HouseholdPlanResolutionFailed Text
  | HouseholdBudgetObservationFailed (NonEmpty HouseholdBudgetError)
  deriving (Show)

-- | Load one canonical Household root from disk into a typed 'HouseholdState'.
loadCanonicalHousehold
  :: HouseholdRoot
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdState)
loadCanonicalHousehold root = do
  let paths = householdSourcePaths root

  -- 1. accounts.journal
  accountsResult <- tryIOError (TIO.readFile (householdAccountsJournalPath paths))
  accountsContent <- case accountsResult of
    Left err -> pure (Left (NonEmpty.singleton (HouseholdSourceReadFailed (householdAccountsJournalPath paths) err)))
    Right content -> pure (Right content)

  accountsRegistry <- case accountsContent of
    Left errs -> pure (Left errs)
    Right content -> case parseAccountJournal content of
      Left errs -> pure (Left (NonEmpty.singleton (HouseholdAccountsParseFailed errs)))
      Right registry -> pure (Right registry)

  case accountsRegistry of
    Left errs -> pure (Left errs)
    Right admittedAccountsRegistry -> loadRest root paths admittedAccountsRegistry

loadRest
  :: HouseholdRoot
  -> HouseholdSourcePaths
  -> AccountRegistry
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdState)
loadRest root paths accountsRegistry = do
  -- 2. actual.journal via loadJournal include resolution
  actualLoadResult <- loadJournal (householdActualJournalPath paths)
  resolvedActualJournal <- case actualLoadResult of
    Left err -> pure (Left (NonEmpty.singleton (HouseholdActualLoadFailed err)))
    Right j -> pure (Right j)

  actualJournalResult <- case resolvedActualJournal of
    Left errs -> pure (Left errs)
    Right journal -> do
      content <- TIO.readFile (householdActualJournalPath paths)
      case parseActualJournal content of
        Left errs -> pure (Left (NonEmpty.singleton (HouseholdActualParseFailed errs)))
        Right aj -> pure (Right (journal, aj))

  case actualJournalResult of
    Left errs -> pure (Left errs)
    Right (resolvedActualJournal', actualJournal) -> do
      let actualRegistry = journalAccountRegistry resolvedActualJournal'

      -- Exact AccountRegistry equality gate
      if accountsRegistry /= actualRegistry
        then pure (Left (NonEmpty.singleton (HouseholdAccountRegistryDisagreement accountsRegistry actualRegistry)))
        else loadWithActual root paths accountsRegistry resolvedActualJournal' actualJournal

loadWithActual
  :: HouseholdRoot
  -> HouseholdSourcePaths
  -> AccountRegistry
  -> Journal
  -> ActualJournal
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdState)
loadWithActual root paths accountsRegistry resolvedActualJournal actualJournal = do
  -- 3. plan.journal
  planLoadResult <- loadJournal (householdPlanJournalPath paths)
  resolvedPlanJournal <- case planLoadResult of
    Left err -> pure (Left (NonEmpty.singleton (HouseholdPlanLoadFailed err)))
    Right j -> pure (Right j)

  planJournalResult <- case resolvedPlanJournal of
    Left errs -> pure (Left errs)
    Right journal -> do
      content <- TIO.readFile (householdPlanJournalPath paths)
      case parsePlanJournal content of
        Left errs -> pure (Left (NonEmpty.singleton (HouseholdPlanParseFailed errs)))
        Right pj -> pure (Right (content, pj))

  case planJournalResult of
    Left errs -> pure (Left errs)
    Right (planContent, planJournal) -> do
      case validatePlanRegistry paths accountsRegistry planJournal of
        Left errs -> pure (Left errs)
        Right () -> loadWithPlan root paths accountsRegistry resolvedActualJournal actualJournal planContent planJournal

validatePlanRegistry
  :: HouseholdSourcePaths
  -> AccountRegistry
  -> PlanJournal
  -> Either (NonEmpty HouseholdLoadError) ()
validatePlanRegistry paths actualRegistry planJournal =
  case NonEmpty.nonEmpty errors of
    Nothing -> Right ()
    Just errs -> Left errs
  where
    planRegistry = journalAccountRegistry (planJournalValue planJournal)
    errors =
      [ HouseholdPlanRegistryDisagreement (householdPlanJournalPath paths)
          ("Account metadata disagrees with accounts.journal for " <> accountName account)
      | declaration <- accountDeclarations planRegistry
      , let account = declaredAccount declaration
      , lookupAccountDeclaration account actualRegistry /= Just declaration
      ]

loadWithPlan
  :: HouseholdRoot
  -> HouseholdSourcePaths
  -> AccountRegistry
  -> Journal
  -> ActualJournal
  -> Text
  -> PlanJournal
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdState)
loadWithPlan root paths accountsRegistry resolvedActualJournal actualJournal planContent planJournal = do
  -- 4. budget.journal
  budgetLoadResult <- loadJournal (householdBudgetJournalPath paths)
  budgetJournal <- case budgetLoadResult of
    Left err -> pure (Left (NonEmpty.singleton (HouseholdBudgetLoadFailed err)))
    Right j -> pure (Right j)

  budgetResult <- case budgetJournal of
    Left errs -> pure (Left errs)
    Right bj -> case admitHouseholdBudgetMovementJournal bj of
      Left errs -> pure (Left (NonEmpty.singleton (HouseholdBudgetMovementAdmitFailed errs)))
      Right movements -> case validateBudgetRegistry paths accountsRegistry bj of
        Left errs -> pure (Left errs)
        Right () -> pure (Right (bj, movements))

  case budgetResult of
    Left errs -> pure (Left errs)
    Right (budgetJournal', budgetMovements) ->
      loadConfigsAndIssues root paths accountsRegistry actualJournal planContent planJournal budgetJournal' budgetMovements

validateBudgetRegistry
  :: HouseholdSourcePaths
  -> AccountRegistry
  -> Journal
  -> Either (NonEmpty HouseholdLoadError) ()
validateBudgetRegistry paths actualRegistry budgetJournal =
  case NonEmpty.nonEmpty errors of
    Nothing -> Right ()
    Just errs -> Left errs
  where
    budgetRegistry = journalAccountRegistry budgetJournal
    errors =
      [ HouseholdBudgetRegistryDisagreement (householdBudgetJournalPath paths)
          ("Account metadata disagrees with accounts.journal for " <> accountName account)
      | declaration <- accountDeclarations budgetRegistry
      , let account = declaredAccount declaration
      , lookupAccountDeclaration account actualRegistry /= Just declaration
      ]

loadConfigsAndIssues
  :: HouseholdRoot
  -> HouseholdSourcePaths
  -> AccountRegistry
  -> ActualJournal
  -> Text
  -> PlanJournal
  -> Journal
  -> [HouseholdBudgetMovement]
  -> IO (Either (NonEmpty HouseholdLoadError) HouseholdState)
loadConfigsAndIssues root paths accountsRegistry actualJournal planContent planJournal budgetJournal budgetMovements = do
  -- 5. budget.toml
  budgetConfigContent <- TIO.readFile (householdBudgetConfigPath paths)
  budgetPolicy <- case parseBudgetPolicy budgetConfigContent of
    Left errs -> pure (Left (NonEmpty.singleton (HouseholdBudgetPolicyParseFailed errs)))
    Right bp -> pure (Right bp)

  case budgetPolicy of
    Left errs -> pure (Left errs)
    Right admittedBudgetPolicy -> do
      -- 6. household.toml
      policyContent <- TIO.readFile (householdPolicyConfigPath paths)
      policyResult <- case parseHouseholdPolicy admittedBudgetPolicy policyContent of
        Left errs -> pure (Left (NonEmpty.singleton (HouseholdPolicyParseFailed errs)))
        Right hp -> case validateHouseholdPolicyAccounts accountsRegistry hp of
          Left errs -> pure (Left (NonEmpty.singleton (HouseholdPolicyAccountValidationFailed errs)))
          Right vp -> pure (Right (hp, vp))

      case policyResult of
        Left errs -> pure (Left errs)
        Right (householdPolicy, validatedPolicy) -> do
          -- 7. report.toml
          reportConfigContent <- TIO.readFile (householdReportConfigPath paths)
          reportConfig <- case parseReportConfiguration reportConfigContent of
            Left errs -> pure (Left (NonEmpty.singleton (HouseholdReportConfigParseFailed errs)))
            Right rc -> pure (Right rc)

          case reportConfig of
            Left errs -> pure (Left errs)
            Right admittedReportConfig -> do
              -- 8. issues.tsv
              issuesContent <- TIO.readFile (householdIssuesPath paths)
              issues <- case parseHouseholdIssues issuesContent of
                Left errs -> pure (Left (NonEmpty.singleton (HouseholdIssuesParseFailed errs)))
                Right iss -> pure (Right iss)

              case issues of
                Left errs -> pure (Left errs)
                Right admittedIssues -> do
                  dailyScopeResult <- assembleDailyScope paths accountsRegistry planContent planJournal
                  case dailyScopeResult of
                    Left errs -> pure (Left errs)
                    Right dailyScope ->
                      pure (Right HouseholdState
                        { householdStateRoot = root
                        , householdStatePaths = paths
                        , householdStateAccountsRegistry = accountsRegistry
                        , householdStateActualJournal = actualJournal
                        , householdStatePlanJournal = planJournal
                        , householdStateBudgetJournal = budgetJournal
                        , householdStateBudgetMovements = budgetMovements
                        , householdStateBudgetPolicy = admittedBudgetPolicy
                        , householdStatePolicy = householdPolicy
                        , householdStateValidatedPolicy = validatedPolicy
                        , householdStateReportConfig = admittedReportConfig
                        , householdStateIssues = admittedIssues
                        , householdStateDailyScope = dailyScope
                        })

assembleDailyScope
  :: HouseholdSourcePaths
  -> AccountRegistry
  -> Text
  -> PlanJournal
  -> IO (Either (NonEmpty HouseholdLoadError) DailyTargetScope)
assembleDailyScope paths registry planContent planJournal = do
  let assetSelections =
        [ selectDailyTargetAsset (safeScopeId (accountName acc)) acc
        | decl <- accountDeclarations registry
        , let acc = declaredAccount decl
        , declaredAccountType decl == Asset
        ]
  case parseDailyTargetPlanJournalSelections planContent planJournal of
    Right obligationSelections -> do
      case admitPlanJournalForScope planJournal of
        Left err -> pure (Left (NonEmpty.singleton (HouseholdPlanAnalysisFailed err)))
        Right committedPlans ->
          case dailyTargetScopeFromSelections registry committedPlans assetSelections obligationSelections of
            Left errs -> pure (Left (NonEmpty.singleton (HouseholdDailyTargetScopeFailed errs)))
            Right scope -> pure (Right scope)
    Left _ -> do
      let rootDir = takeDirectory (householdAccountsJournalPath paths)
          legacyPath = rootDir </> "daily_target_scope.tsv"
      legacyExists <- doesFileExist legacyPath
      if legacyExists
        then do
          tsvText <- TIO.readFile legacyPath
          case admitPlanJournalForScope planJournal of
            Left err -> pure (Left (NonEmpty.singleton (HouseholdPlanAnalysisFailed err)))
            Right committedPlans ->
              case parseDailyTargetScope registry committedPlans tsvText of
                Left _ -> pure (Left (NonEmpty.singleton (HouseholdPlanAnalysisFailed "Failed to parse daily_target_scope.tsv")))
                Right scope -> pure (Right scope)
        else
          case admitPlanJournalForScope planJournal of
            Left err -> pure (Left (NonEmpty.singleton (HouseholdPlanAnalysisFailed err)))
            Right committedPlans ->
              case dailyTargetScopeFromSelections registry committedPlans assetSelections [] of
                Left errs -> pure (Left (NonEmpty.singleton (HouseholdDailyTargetScopeFailed errs)))
                Right scope -> pure (Right scope)

safeScopeId :: Text -> DailyTargetScopeId
safeScopeId txt = case mkDailyTargetScopeId txt of
  Right val -> val
  Left _ -> case mkDailyTargetScopeId "scope" of
    Right fallback -> fallback
    Left _ -> error "unreachable scope id"

admitPlanJournalForScope :: PlanJournal -> Either Text [CommittedOutgoingPlan]
admitPlanJournalForScope planJournal = case classifyPlanJournal planJournal of
  Left err -> Left (T.pack (show err))
  Right classified -> case projectCommittedOutgoingPlans planJournal classified of
    Left err -> Left (T.pack (show err))
    Right projected -> Right (map projectedCommittedOutgoingPlan projected)

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
  paths <- Right (householdSourcePaths root)
  accountsRegistry <- first (NonEmpty.singleton . HouseholdAccountsParseFailed) (parseAccountJournal accountsText)
  actualJournal <- first (NonEmpty.singleton . HouseholdActualParseFailed) (parseActualJournal actualText)
  let actualRegistry = journalAccountRegistry (actualJournalValue actualJournal)
  if accountsRegistry /= actualRegistry
    then Left (NonEmpty.singleton (HouseholdAccountRegistryDisagreement accountsRegistry actualRegistry))
    else Right ()

  planJournal <- first (NonEmpty.singleton . HouseholdPlanParseFailed) (parsePlanJournal planText)
  case validatePlanRegistry paths accountsRegistry planJournal of
    Left errs -> Left errs
    Right () -> Right ()

  budgetJournal <- first (pure . HouseholdBudgetLoadFailed . const (undefined :: LoadError))
    (case parseActualJournal budgetText of
       Left _ -> Left ()
       Right aj -> Right (actualJournalValue aj))
  budgetMovements <- first (NonEmpty.singleton . HouseholdBudgetMovementAdmitFailed) (admitHouseholdBudgetMovementJournal budgetJournal)

  budgetPolicy <- first (NonEmpty.singleton . HouseholdBudgetPolicyParseFailed) (parseBudgetPolicy budgetPolicyText)
  policy <- first (NonEmpty.singleton . HouseholdPolicyParseFailed) (parseHouseholdPolicy budgetPolicy householdPolicyText)
  validatedPolicy <- first (NonEmpty.singleton . HouseholdPolicyAccountValidationFailed) (validateHouseholdPolicyAccounts accountsRegistry policy)
  reportConfig <- first (NonEmpty.singleton . HouseholdReportConfigParseFailed) (parseReportConfiguration reportConfigText)
  issues <- first (NonEmpty.singleton . HouseholdIssuesParseFailed) (parseHouseholdIssues issuesText)

  committedPlans <- first (NonEmpty.singleton . HouseholdPlanAnalysisFailed) (admitPlanJournalForScope planJournal)
  let assetSelections =
        [ selectDailyTargetAsset (safeScopeId (accountName acc)) acc
        | decl <- accountDeclarations accountsRegistry
        , let acc = declaredAccount decl
        , declaredAccountType decl == Asset
        ]
  obligationSelections <- first (pure . HouseholdPlanAnalysisFailed . T.pack . show) (parseDailyTargetPlanJournalSelections planText planJournal)
  dailyScope <- first (NonEmpty.singleton . HouseholdDailyTargetScopeFailed) (dailyTargetScopeFromSelections accountsRegistry committedPlans assetSelections obligationSelections)

  pure HouseholdState
    { householdStateRoot = root
    , householdStatePaths = paths
    , householdStateAccountsRegistry = accountsRegistry
    , householdStateActualJournal = actualJournal
    , householdStatePlanJournal = planJournal
    , householdStateBudgetJournal = budgetJournal
    , householdStateBudgetMovements = budgetMovements
    , householdStateBudgetPolicy = budgetPolicy
    , householdStatePolicy = policy
    , householdStateValidatedPolicy = validatedPolicy
    , householdStateReportConfig = reportConfig
    , householdStateIssues = issues
    , householdStateDailyScope = dailyScope
    }

-- | Build 'HouseholdReportSurface' directly from the loaded 'HouseholdState'.
buildHouseholdReportSurfaceFromHousehold
  :: Day
  -> HouseholdState
  -> Either (NonEmpty HouseholdLoadError) HouseholdReportSurface
buildHouseholdReportSurfaceFromHousehold observation state = do
  let actualJournal = householdStateActualJournal state
      journal = actualJournalValue actualJournal
      planJournal = householdStatePlanJournal state
      policy = householdStatePolicy state
      validatedPolicy = householdStateValidatedPolicy state
      budgetMovements = householdStateBudgetMovements state
      issues = householdStateIssues state
      dailyScope = householdStateDailyScope state
      cycleAccount = householdCycleIncomeAccount (householdPolicyCycle policy)

  admittedPlans <- first (NonEmpty.singleton . HouseholdPlanAnalysisFailed . T.pack . show)
    (admitPlanJournalPure planJournal)

  (current, previous) <- first (NonEmpty.singleton . HouseholdCycleError)
    (resolveCyclesPure observation journal cycleAccount (admittedIncomingAnchors admittedPlans))

  outgoingDeclarations <- first (NonEmpty.singleton . HouseholdPlanResolutionFailed . T.pack . show)
    (completionDeclarationsForOutgoingPlansPure admittedPlans (actualJournalCompletionDeclarations actualJournal))

  let outgoingPlans = admittedOutgoingPlans admittedPlans

  openPlanValues <- first (NonEmpty.singleton . HouseholdPlanResolutionFailed . T.pack . show)
    (resolveOpenCommittedOutgoingPlans
      (map planFactValue outgoingPlans)
      (actualJournalIdentifiedTransactions actualJournal)
      outgoingDeclarations)

  budgetObservation <- first (NonEmpty.singleton . HouseholdBudgetObservationFailed)
    (deriveHouseholdBudgetObservation observation current journal validatedPolicy budgetMovements)

  let admittedPolicy = householdBudgetObservationPolicy budgetObservation
      consumption = householdBudgetConsumption budgetObservation
      entitlement = householdBudgetEntitlement budgetObservation
      remaining = householdBudgetRemaining budgetObservation
      openPlanIds = Set.fromList (map committedPlanId openPlanValues)
      openPlans = openPlansInPeriodPure current (journalAccountRegistry journal) openPlanIds outgoingPlans
      backingPlans =
        [ HouseholdBackingPlan
            { householdBackingPlanDestination = planFactTo plan
            , householdBackingPlanAmount = committedPlanAmount (planFactValue plan)
            }
        | plan <- openPlans
        ]
      backing = deriveHouseholdBacking
        observation current journal admittedPolicy
        budgetMovements entitlement consumption remaining backingPlans
      target = deriveDailyTarget observation current journal
        dailyScope (map planFactValue openPlans)

  pure HouseholdReportSurface
    { householdCycleAccounts = cycleAccounts current previous journal
    , householdPlannedTransactions = map planFactValue openPlans
    , householdIssues = issues
    , householdEnvelopeBacking = backing
    , householdDailyTarget = target
    }

-- Pure helpers matching HouseholdReport

data IncomingCycleAnchor = IncomingCycleAnchor
  { incomingAnchorId     :: PlanId
  , incomingAnchorDate   :: Day
  , incomingAnchorSource :: Account
  } deriving (Eq, Show)

data PlanFact = PlanFact
  { planFactValue :: CommittedOutgoingPlan
  , planFactFrom  :: Account
  , planFactTo    :: Account
  } deriving (Eq, Show)

data AdmittedPlans = AdmittedPlans
  { admittedIncomingAnchors :: [IncomingCycleAnchor]
  , admittedOutgoingPlans   :: [PlanFact]
  } deriving (Eq, Show)

admitPlanJournalPure :: PlanJournal -> Either Text AdmittedPlans
admitPlanJournalPure planJournal = case classifyPlanJournal planJournal of
  Left err -> Left (T.pack (show err))
  Right classified -> case projectIncomingCycleAnchor registry (classifiedIncomingPlanTransactions classified) of
    Left err -> Left err
    Right incoming -> case projectCommittedOutgoingPlans planJournal classified of
      Left err -> Left (T.pack (show err))
      Right projected -> Right AdmittedPlans
        { admittedIncomingAnchors = incoming
        , admittedOutgoingPlans = map projectPlanFact projected
        }
  where
    registry = journalAccountRegistry (planJournalValue planJournal)

projectIncomingCycleAnchor
  :: AccountRegistry
  -> [IdentifiedPlanTransaction]
  -> Either Text [IncomingCycleAnchor]
projectIncomingCycleAnchor registry identifiedList =
  traverse projectOne identifiedList
  where
    projectOne identified = case Set.toAscList incomeSources of
      [source] -> Right IncomingCycleAnchor
        { incomingAnchorId = identifiedPlanId identified
        , incomingAnchorDate = transactionDate transaction
        , incomingAnchorSource = source
        }
      _ -> Left "incoming cycle anchor requires exactly one Income source Account"
      where
        transaction = identifiedPlanTransaction identified
        incomeSources = Set.fromList
          [ postingAccount posting
          | posting <- NonEmpty.toList (transactionPostings transaction)
          , accountTypeFor (postingAccount posting) registry == Just Income
          , amountQuantity (postingAmount posting) < zeroQuantity
          ]

projectPlanFact :: ProjectedCommittedOutgoingPlan -> PlanFact
projectPlanFact projected = PlanFact
  { planFactValue = plan
  , planFactFrom = declaredAccount (declaredPaymentSource direction)
  , planFactTo = declaredAccount (declaredPaymentDestination direction)
  }
  where
    plan = projectedCommittedOutgoingPlan projected
    direction = declaredOutgoingPaymentDirection (committedPlanDirection plan)

completionDeclarationsForOutgoingPlansPure
  :: AdmittedPlans
  -> [PlanCompletionDeclaration]
  -> Either Text [PlanCompletionDeclaration]
completionDeclarationsForOutgoingPlansPure plans declarations =
  case unknownErrors of
    _ : _ -> Left (T.pack (show unknownErrors))
    [] -> Right
      [ declaration
      | declaration <- declarations
      , Set.member (declaredCompletionPlanId declaration) outgoingPlanIds
      ]
  where
    incomingPlanIds = Set.fromList (map incomingAnchorId (admittedIncomingAnchors plans))
    outgoingPlanIds = Set.fromList (map (committedPlanId . planFactValue) (admittedOutgoingPlans plans))
    knownPlanIds = Set.union incomingPlanIds outgoingPlanIds
    unknownErrors =
      [ "completion relation refers to unknown PlanId " <> planIdText planId
      | declaration <- declarations
      , let planId = declaredCompletionPlanId declaration
      , Set.notMember planId knownPlanIds
      ]

resolveCyclesPure
  :: Day
  -> Journal
  -> Account
  -> [IncomingCycleAnchor]
  -> Either Text (Period, Period)
resolveCyclesPure observation journal incomeAccount anchors =
  case (reverse actualAnchors, plannedAnchors) of
    (currentStart : previousStart : _, currentEnd : _) -> do
      current <- first (T.pack . show) (mkPeriod currentStart currentEnd)
      previous <- first (T.pack . show) (mkPeriod previousStart currentStart)
      Right (current, previous)
    _ -> Left "income-anchor cycle requires two observed Actual anchors and one future Plan anchor"
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

openPlansInPeriodPure
  :: Period
  -> AccountRegistry
  -> Set.Set PlanId
  -> [PlanFact]
  -> [PlanFact]
openPlansInPeriodPure period registry openPlanIds =
  sortOn (committedPlanDate . planFactValue)
    . filter eligible
  where
    eligible plan =
      Set.member (committedPlanId (planFactValue plan)) openPlanIds
        && periodContains period (committedPlanDate (planFactValue plan))
        && accountTypeFor (planFactFrom plan) registry == Just Asset
        && accountTypeFor (planFactTo plan) registry `elem` [Just Expense, Just Liability]
