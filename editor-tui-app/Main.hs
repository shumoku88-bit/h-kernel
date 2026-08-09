{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Main (main) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Graphics.Vty.CrossPlatform (mkVty)
import Lens.Micro (Traversal')
import Lens.Micro.Mtl ()

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import System.Directory (doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeDirectory)

import HKernel.Account
  ( AccountDeclaration
  , accountDeclarations
  , accountName
  , declaredAccount
  , declaredAccountDefaultCommodity
  , declaredAccountType
  )
import qualified HKernel.Account
import HKernel.Actual.Journal (actualJournalValue)
import HKernel.Application.Config (HouseholdSourcePaths(..), mkHouseholdRoot)
import HKernel.Budget.Policy
  ( EnvelopeDefinition
  , budgetPolicyEnvelopeDefinitions
  , envelopeDefinitionExpenseAccounts
  , envelopeDefinitionId
  )
import HKernel.Engine (mkDateRange)
import qualified HKernel.Editor.TUI.Actual as Actual
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , ReportChoice(..)
  , WorkspaceFocus(..)
  , makeWorkspaceContext
  )
import qualified HKernel.Editor.TUI.Plan as Plan
import HKernel.Household.Application
  ( HouseholdState(..)
  , HouseholdWriteSnapshot(..)
  , buildHouseholdReportSurfaceFromHousehold
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.Policy
  ( householdAllocationEnvelopes
  , householdCycleIncomeAccount
  , householdPolicyCycle
  , householdUnassignedBudgetAccounts
  )
import HKernel.HouseholdIssue (HouseholdIssue(..))
import qualified HKernel.Ledger
import HKernel.Money
  ( amountCommodity
  , amountQuantity
  , commodityCode
  , renderQuantity
  )
import qualified HKernel.Plan.Journal
import HKernel.Render
  ( renderBalanceSheetWithPresentation
  , renderDailyFlowWithPresentation
  , renderMonthlyAccountsWithPresentation
  , renderProfitAndLossWithPresentation
  , renderRecentTransactionsWithPresentation
  , renderTrialBalanceWithPresentation
  )
import HKernel.Report
  ( balanceSheetAsOf
  , dailyFlow
  , defaultRecentCount
  , monthlyAccounts
  , profitAndLoss
  , recentTransactions
  , reportBook
  , trialBalanceAsOf
  )
import HKernel.Report.Config
  ( reportConfigurationPlan
  , reportConfigurationPresentation
  )
import HKernel.Spike.HouseholdReport.Render
  ( HouseholdReportSection(..)
  , renderHouseholdReportSection
  , renderReportBookWithHouseholdPresentation
  )

data UIState
  = Workspace
  | ActualFlow (Actual.State AppEvent)
  | PlanFlow (Plan.State AppEvent)
  | ShowWorkspaceReloadFailure

data AppWrapper = AppWrapper AppContext UIState

zoomActualFlow :: Traversal' AppWrapper (Actual.State AppEvent)
zoomActualFlow f (AppWrapper context (ActualFlow state)) =
  (\updated -> AppWrapper context (ActualFlow updated)) <$> f state
zoomActualFlow _ wrapper = pure wrapper

zoomPlanFlow :: Traversal' AppWrapper (Plan.State AppEvent)
zoomPlanFlow f (AppWrapper context (PlanFlow state)) =
  (\updated -> AppWrapper context (PlanFlow updated)) <$> f state
zoomPlanFlow _ wrapper = pure wrapper

zoomWorkspaceAccounts :: Traversal' AppWrapper (L.List Name (Maybe HKernel.Account.Account))
zoomWorkspaceAccounts f (AppWrapper context Workspace) =
  (\updated -> AppWrapper (context { contextWorkspaceAccounts = updated }) Workspace)
    <$> f (contextWorkspaceAccounts context)
zoomWorkspaceAccounts _ wrapper = pure wrapper

zoomWorkspaceList :: Traversal' AppWrapper (L.List Name HKernel.Ledger.Transaction)
zoomWorkspaceList f (AppWrapper context Workspace) =
  (\updated -> AppWrapper (context { contextWorkspaceList = updated }) Workspace)
    <$> f (contextWorkspaceList context)
zoomWorkspaceList _ wrapper = pure wrapper

zoomPlanList :: Traversal' AppWrapper (L.List Name HKernel.Plan.Journal.IdentifiedPlanTransaction)
zoomPlanList f (AppWrapper context Workspace) =
  (\updated -> AppWrapper (context { contextPlanList = updated }) Workspace)
    <$> f (contextPlanList context)
zoomPlanList _ wrapper = pure wrapper

drawUI :: AppWrapper -> [Widget Name]
drawUI (AppWrapper context Workspace) = [drawHouseholdShell context]
drawUI (AppWrapper context (ActualFlow state)) = [Actual.drawFlow context state]
drawUI (AppWrapper _ (PlanFlow state)) = [Plan.drawFlow state]
drawUI (AppWrapper _ ShowWorkspaceReloadFailure) =
  [ center
      (borderWithLabel (str "Household reload")
        (padAll 1
          (withAttr (attrName "error")
            (vBox
              [ str "The source write succeeded, but the Household could not reload."
              , str "Restart the TUI before continuing."
              , str " "
              , str "[Esc/Q] Quit"
              ]))))
  ]

drawHouseholdShell :: AppContext -> Widget Name
drawHouseholdShell context =
  vBox [drawSectionTabBar (contextCurrentSection context), drawSectionBody context]

drawSectionTabBar :: HouseholdSection -> Widget Name
drawSectionTabBar currentSection =
  borderWithLabel (str "h-kernel Household")
    (hBox (map renderTab [minBound .. maxBound]))
  where
    renderTab section
      | section == currentSection = withAttr (attrName "activeTab")
          (str (" [" <> sectionNum section <> ": " <> sectionName section <> "] "))
      | otherwise = str ("  " <> sectionNum section <> ": " <> sectionName section <> "  ")
    sectionNum ActualSection = "1"
    sectionNum PlansSection = "2"
    sectionNum BudgetSection = "3"
    sectionNum AccountsSection = "4"
    sectionNum IssuesSection = "5"
    sectionNum ReportsSection = "6"
    sectionNum SettingsSection = "7"
    sectionName ActualSection = "Actual"
    sectionName PlansSection = "Plans"
    sectionName BudgetSection = "Budget"
    sectionName AccountsSection = "Accounts"
    sectionName IssuesSection = "Issues"
    sectionName ReportsSection = "Reports"
    sectionName SettingsSection = "Settings"

drawSectionBody :: AppContext -> Widget Name
drawSectionBody context = case contextCurrentSection context of
  ActualSection -> Actual.drawWorkspace context
  PlansSection -> Plan.drawWorkspace context
  BudgetSection -> drawBudgetView context
  AccountsSection -> drawAccountsView context
  IssuesSection -> drawIssuesView context
  ReportsSection -> drawReportsView context
  SettingsSection -> drawSettingsView context

drawBudgetView :: AppContext -> Widget Name
drawBudgetView context =
  vBox
    [ borderWithLabel (str "Budget Movements & Policy (budget.journal)")
        (vLimit 18
          (viewport BudgetViewport Vertical
            (vBox
              [ str "--- Budget Movements ---"
              , vBox (map renderBudgetMovement (householdStateBudgetMovements state))
              , str " "
              , str "--- Spendable Envelopes ---"
              , vBox (map renderEnvelopeDef
                  (budgetPolicyEnvelopeDefinitions (householdStateBudgetPolicy state)))
              ])))
    , str "[1-7] Switch section   [q] Quit"
    ]
  where
    state = contextHouseholdState context

renderBudgetMovement :: HouseholdBudgetMovement -> Widget Name
renderBudgetMovement movement =
  txt (T.pack (show (householdBudgetMovementDate movement)) <> "  "
        <> householdBudgetMovementMemo movement <> "  "
        <> accountName (householdBudgetMovementFrom movement) <> " -> "
        <> accountName (householdBudgetMovementTo movement) <> "  "
        <> renderQuantity (amountQuantity (householdBudgetMovementAmount movement)) <> " "
        <> commodityCode (amountCommodity (householdBudgetMovementAmount movement)))

renderEnvelopeDef :: EnvelopeDefinition -> Widget Name
renderEnvelopeDef definition =
  txt ("Envelope: " <> T.pack (show (envelopeDefinitionId definition))
    <> "  Expenses: "
    <> T.intercalate ", " (map accountName (envelopeDefinitionExpenseAccounts definition)))

drawAccountsView :: AppContext -> Widget Name
drawAccountsView context =
  vBox
    [ borderWithLabel (str "Canonical Account Declarations (accounts.journal)")
        (vLimit 18
          (viewport AccountsViewport Vertical
            (vBox (map renderAccountDecl
              (accountDeclarations
                (householdStateAccountsRegistry (contextHouseholdState context)))))))
    , str "[1-7] Switch section   [q] Quit"
    ]

renderAccountDecl :: AccountDeclaration -> Widget Name
renderAccountDecl declaration =
  txt (accountName (declaredAccount declaration) <> "  type: "
    <> T.pack (show (declaredAccountType declaration))
    <> maybe "" (\commodity -> "  default commodity: " <> commodityCode commodity)
      (declaredAccountDefaultCommodity declaration))

drawIssuesView :: AppContext -> Widget Name
drawIssuesView context =
  vBox
    [ borderWithLabel (str "Household Notebook (issues.tsv)")
        (vLimit 18
          (viewport IssuesViewport Vertical
            (if null issues then str "No issues recorded." else vBox (map renderIssue issues))))
    , str "[1-7] Switch section   [q] Quit"
    ]
  where
    issues = householdStateIssues (contextHouseholdState context)

renderIssue :: HouseholdIssue -> Widget Name
renderIssue issue =
  padBottom (Pad 1)
    (vBox
      [ txt ("[" <> T.pack (show (householdIssueStatus issue)) <> "]  "
          <> T.pack (show (householdIssueRecordedOn issue)) <> "  Due: "
          <> T.pack (show (householdIssueDue issue)))
      , txt ("  Text: " <> householdIssueText issue)
      , maybe emptyWidget
          (\amount -> txt ("  Amount: " <> renderQuantity (amountQuantity amount)
            <> " " <> commodityCode (amountCommodity amount)))
          (householdIssueAmount issue)
      , txt ("  Details: " <> householdIssueDetails issue)
      ])

drawReportsView :: AppContext -> Widget Name
drawReportsView context =
  vBox
    [ borderWithLabel (txt ("Household Report: " <> reportChoiceLabel selected))
        (vLimit 18 (viewport ReportsViewport Vertical (renderSelectedReport context)))
    , txt ("Active report: " <> reportChoiceLabel selected)
    , str "[t] Trial   [b] Balance Sheet   [p] P&L   [d] Daily   [m] Monthly   [a] Recent"
    , str "[c] Cycle   [T] Target   [P] Planned   [E] Envelope   [h] Household   [r] Next"
    , str "[1-7] Switch section   [q] Quit"
    ]
  where
    selected = contextSelectedReport context

reportChoiceLabel :: ReportChoice -> Text
reportChoiceLabel choice = case choice of
  ReportTrialBalance -> "Trial Balance"
  ReportBalanceSheet -> "Balance Sheet"
  ReportProfitAndLoss -> "Profit & Loss"
  ReportDailyFlow -> "Daily Flow"
  ReportMonthlyAccounts -> "Monthly Accounts"
  ReportHousehold section -> case section of
    HouseholdCycleAccounts -> "Current Cycle"
    HouseholdDailyTarget -> "Daily Target"
    HouseholdPlannedTransactions -> "Planned Transactions"
    HouseholdIssues _ -> "Household Issues"
    HouseholdEnvelopeBacking -> "Envelope & Backing"
  ReportRecentTransactions -> "Recent Actual"
  ReportCombinedBook -> "Household"

reportChoices :: [ReportChoice]
reportChoices =
  [ ReportTrialBalance
  , ReportBalanceSheet
  , ReportProfitAndLoss
  , ReportDailyFlow
  , ReportMonthlyAccounts
  , ReportHousehold HouseholdCycleAccounts
  , ReportHousehold HouseholdDailyTarget
  , ReportHousehold HouseholdPlannedTransactions
  , ReportHousehold HouseholdEnvelopeBacking
  , ReportRecentTransactions
  , ReportCombinedBook
  ]

renderSelectedReport :: AppContext -> Widget Name
renderSelectedReport context = case contextSelectedReport context of
  ReportTrialBalance ->
    txt (renderTrialBalanceWithPresentation pres (trialBalanceAsOf day journal))
  ReportBalanceSheet ->
    txt (renderBalanceSheetWithPresentation pres (balanceSheetAsOf day journal))
  ReportProfitAndLoss ->
    txt (renderProfitAndLossWithPresentation pres (profitAndLoss (defaultDateRange day) journal))
  ReportDailyFlow ->
    txt (renderDailyFlowWithPresentation pres (dailyFlow (defaultDateRange day) journal))
  ReportMonthlyAccounts ->
    txt (renderMonthlyAccountsWithPresentation pres (monthlyAccounts (defaultDateRange day) journal))
  ReportHousehold section -> case buildHouseholdReportSurfaceFromHousehold day state of
    Left err -> txt ("Report surface error: " <> T.pack (show err))
    Right surface -> txt (renderHouseholdReportSection pres section surface)
  ReportRecentTransactions ->
    txt (renderRecentTransactionsWithPresentation pres
      (recentTransactions defaultRecentCount day journal))
  ReportCombinedBook -> case buildHouseholdReportSurfaceFromHousehold day state of
    Left err -> txt ("Report surface error: " <> T.pack (show err))
    Right surface -> txt
      (renderReportBookWithHouseholdPresentation pres (reportBook (defaultDateRange day) journal) surface)
  where
    state = contextHouseholdState context
    day = contextObservationDay context
    journal = actualJournalValue (householdStateActualJournal state)
    pres = reportConfigurationPresentation (householdStateReportConfig state)
    defaultDateRange value = case mkDateRange value value of
      Right range -> range
      Left _ -> error "unreachable date range"

drawSettingsView :: AppContext -> Widget Name
drawSettingsView context =
  vBox
    [ borderWithLabel (str "Household Settings & Policy")
        (vLimit 18
          (viewport SettingsViewport Vertical
            (vBox
              [ str "=== [budget.toml] Budget Policy ==="
              , str ("Envelopes count: "
                  <> show (length (budgetPolicyEnvelopeDefinitions
                    (householdStateBudgetPolicy state))))
              , str " "
              , str "=== [household.toml] Household Policy ==="
              , txt ("Income Cycle Account: "
                  <> accountName (householdCycleIncomeAccount
                    (householdPolicyCycle (householdStatePolicy state))))
              , txt ("Allocation Envelopes: "
                  <> T.pack (show (householdAllocationEnvelopes
                    (householdStatePolicy state))))
              , txt ("Unassigned Accounts: "
                  <> T.intercalate ", "
                    (map accountName
                      (Set.toAscList (householdUnassignedBudgetAccounts
                        (householdStatePolicy state)))))
              , str " "
              , str "=== [report.toml] Report Configuration ==="
              , txt ("Report Plan: "
                  <> T.pack (show (reportConfigurationPlan
                    (householdStateReportConfig state))))
              , txt ("Presentation: "
                  <> T.pack (show (reportConfigurationPresentation
                    (householdStateReportConfig state))))
              ])))
    , str "[1-7] Switch section   [q] Quit"
    ]
  where
    state = contextHouseholdState context

appEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
appEvent event = do
  AppWrapper context state <- get
  case state of
    Workspace -> handleWorkspaceEvent context event
    ActualFlow _ -> handleActualFlow context event
    PlanFlow _ -> handlePlanFlow context event
    ShowWorkspaceReloadFailure -> handleExitOnlyEvent event

handleWorkspaceEvent :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleWorkspaceEvent context event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey (V.KChar '1') []) -> switchSection ActualSection
  VtyEvent (V.EvKey (V.KChar '2') []) -> switchSection PlansSection
  VtyEvent (V.EvKey (V.KChar '3') []) -> switchSection BudgetSection
  VtyEvent (V.EvKey (V.KChar '4') []) -> switchSection AccountsSection
  VtyEvent (V.EvKey (V.KChar '5') []) -> switchSection IssuesSection
  VtyEvent (V.EvKey (V.KChar '6') []) -> switchSection ReportsSection
  VtyEvent (V.EvKey (V.KChar '7') []) -> switchSection SettingsSection
  VtyEvent (V.EvKey (V.KChar 't') [])
    | inReports -> selectReport ReportTrialBalance
  VtyEvent (V.EvKey (V.KChar 'b') [])
    | inReports -> selectReport ReportBalanceSheet
  VtyEvent (V.EvKey (V.KChar 'p') [])
    | inReports -> selectReport ReportProfitAndLoss
  VtyEvent (V.EvKey (V.KChar 'd') [])
    | inReports -> selectReport ReportDailyFlow
  VtyEvent (V.EvKey (V.KChar 'm') [])
    | inReports -> selectReport ReportMonthlyAccounts
  VtyEvent (V.EvKey (V.KChar 'c') [])
    | inReports -> selectReport (ReportHousehold HouseholdCycleAccounts)
  VtyEvent (V.EvKey (V.KChar 'T') [])
    | inReports -> selectReport (ReportHousehold HouseholdDailyTarget)
  VtyEvent (V.EvKey (V.KChar 'P') [])
    | inReports -> selectReport (ReportHousehold HouseholdPlannedTransactions)
  VtyEvent (V.EvKey (V.KChar 'E') [])
    | inReports -> selectReport (ReportHousehold HouseholdEnvelopeBacking)
  VtyEvent (V.EvKey (V.KChar 'a') [])
    | inReports -> selectReport ReportRecentTransactions
  VtyEvent (V.EvKey (V.KChar 'h') [])
    | inReports -> selectReport ReportCombinedBook
  VtyEvent (V.EvKey (V.KChar 'r') [])
    | inReports -> selectReport (cycleReport (contextSelectedReport context))
  VtyEvent (V.EvKey (V.KChar 'a') [])
    | inActual -> put (AppWrapper context (ActualFlow (Actual.startDaily (contextEntryDay context))))
  VtyEvent (V.EvKey (V.KChar 'A') [])
    | inActual -> put (AppWrapper context (ActualFlow (Actual.startDaily (contextEntryDay context))))
  VtyEvent (V.EvKey (V.KChar 'm') [])
    | inActual -> put (AppWrapper context (ActualFlow (Actual.startMulti (contextEntryDay context))))
  VtyEvent (V.EvKey (V.KChar 'M') [])
    | inActual -> put (AppWrapper context (ActualFlow (Actual.startMulti (contextEntryDay context))))
  VtyEvent (V.EvKey V.KEnter [])
    | inActual && contextWorkspaceFocus context == AccountsFocus ->
        put (AppWrapper (context { contextWorkspaceFocus = TransactionsFocus }) Workspace)
  VtyEvent (V.EvKey V.KEnter [])
    | inActual -> put (AppWrapper context (ActualFlow (Actual.startSelectedReverse context)))
  VtyEvent (V.EvKey V.KEnter [])
    | inPlans -> openSelectedPlan
  VtyEvent (V.EvKey (V.KChar 'c') [])
    | inPlans -> openSelectedPlan
  VtyEvent (V.EvKey (V.KChar 'C') [])
    | inPlans -> openSelectedPlan
  VtyEvent (V.EvKey (V.KChar '\t') [])
    | inActual -> put (AppWrapper (Actual.toggleWorkspaceFocus context) Workspace)
  VtyEvent (V.EvKey V.KLeft [])
    | inActual -> put (AppWrapper (context { contextWorkspaceFocus = AccountsFocus }) Workspace)
  VtyEvent (V.EvKey V.KRight [])
    | inActual -> put (AppWrapper (context { contextWorkspaceFocus = TransactionsFocus }) Workspace)
  VtyEvent vtyEvent
    | inActual -> handleActualListEvent context vtyEvent
  VtyEvent vtyEvent
    | inPlans -> zoom zoomPlanList (L.handleListEventVi L.handleListEvent vtyEvent)
  _ -> pure ()
  where
    inActual = contextCurrentSection context == ActualSection
    inPlans = contextCurrentSection context == PlansSection
    inReports = contextCurrentSection context == ReportsSection
    switchSection section =
      put (AppWrapper (context { contextCurrentSection = section }) Workspace)
    selectReport report =
      put (AppWrapper (context { contextSelectedReport = report }) Workspace)
    openSelectedPlan = case Plan.startSelectedCompletion context of
      Nothing -> pure ()
      Just flow -> put (AppWrapper context (PlanFlow flow))

handleActualListEvent :: AppContext -> V.Event -> EventM Name AppWrapper ()
handleActualListEvent context vtyEvent = case contextWorkspaceFocus context of
  AccountsFocus -> do
    zoom zoomWorkspaceAccounts (L.handleListEventVi L.handleListEvent vtyEvent)
    AppWrapper updatedContext _ <- get
    put (AppWrapper (Actual.applyWorkspaceAccountFilter updatedContext) Workspace)
  TransactionsFocus ->
    zoom zoomWorkspaceList (L.handleListEventVi L.handleListEvent vtyEvent)

handleActualFlow :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleActualFlow context event = do
  zoom zoomActualFlow (Actual.handleFlowEvent context event)
  AppWrapper currentContext state <- get
  case state of
    ActualFlow Actual.ReturnToWorkspace -> put (AppWrapper currentContext Workspace)
    ActualFlow Actual.QuitRequested -> halt
    ActualFlow (Actual.PublishRequested stickyDay block) -> do
      result <- suspendAndResume' (Actual.publishCandidate context stickyDay block)
      case result of
        Actual.Published freshContext -> put (AppWrapper freshContext Workspace)
        Actual.PublicationFailed outcome ->
          put (AppWrapper context (ActualFlow (Actual.WriteOutcome outcome)))
        Actual.ReloadFailed -> put (AppWrapper context ShowWorkspaceReloadFailure)
    _ -> pure ()

handlePlanFlow :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handlePlanFlow context event = do
  zoom zoomPlanFlow (Plan.handleFlowEvent context event)
  AppWrapper currentContext state <- get
  case state of
    PlanFlow Plan.ReturnToWorkspace -> put (AppWrapper currentContext Workspace)
    PlanFlow Plan.QuitRequested -> halt
    PlanFlow (Plan.PublishRequested preview) -> do
      result <- suspendAndResume' (Plan.publishCandidate context preview)
      case result of
        Plan.Published freshContext -> put (AppWrapper freshContext Workspace)
        Plan.PublicationFailed message ->
          put (AppWrapper context (PlanFlow (Plan.WriteOutcome message)))
        Plan.ReloadFailed -> put (AppWrapper context ShowWorkspaceReloadFailure)
    _ -> pure ()

handleExitOnlyEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleExitOnlyEvent event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()

cycleReport :: ReportChoice -> ReportChoice
cycleReport choice = go reportChoices
  where
    go [] = ReportTrialBalance
    go [_] = ReportTrialBalance
    go (current : next : rest)
      | current == choice = next
      | otherwise = go (next : rest)

app :: App AppWrapper AppEvent Name
app = App
  { appDraw = drawUI
  , appChooseCursor = showFirstCursor
  , appHandleEvent = appEvent
  , appStartEvent = pure ()
  , appAttrMap = const
      (attrMap V.defAttr
        [ (L.listSelectedAttr, V.black `on` V.white)
        , (attrName "activeTab", V.black `on` V.cyan)
        , (attrName "error", fg V.red)
        , (attrName "success", fg V.green)
        , (attrName "warning", fg V.yellow)
        ])
  }

main :: IO ()
main = do
  today <- localDay . zonedTimeToLocalTime <$> getZonedTime
  arguments <- getArgs
  case arguments of
    [path] -> do
      pathIsDirectory <- doesDirectoryExist path
      let rootDir
            | pathIsDirectory = path
            | otherwise = takeDirectory path
          rootPath = if rootDir == "" then "." else rootDir
      root <- case mkHouseholdRoot rootPath of
        Left err -> die ("Invalid household root: " <> show err)
        Right value -> pure value
      householdResult <- loadCanonicalHouseholdWriteSnapshot root
      snapshot <- case householdResult of
        Left errs -> die
          ("Failed to load canonical Household:\n"
            <> unlines (map show (NonEmpty.toList errs)))
        Right value -> pure value
      let state = householdWriteSnapshotState snapshot
          paths = householdStatePaths state
          journalFile = householdActualJournalPath paths
          source = householdWriteSnapshotActualSource snapshot
          planSource = householdWriteSnapshotPlanSource snapshot
          context = makeWorkspaceContext False today journalFile source planSource state
          initialState = AppWrapper context Workspace
          buildVty = mkVty V.defaultConfig
      initialVty <- buildVty
      _ <- customMain initialVty buildVty Nothing app initialState
      pure ()
    _ -> die "Usage: h-kernel-editor-tui <household-root-or-actual.journal>"
