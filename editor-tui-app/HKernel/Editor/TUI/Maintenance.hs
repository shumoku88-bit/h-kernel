{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Maintenance
  ( AccountsWorkspaceAction(..)
  , BudgetWorkspaceAction(..)
  , IssuesWorkspaceAction(..)
  , PublishRequest(..)
  , PublishResult(..)
  , State(..)
  , drawAccountsWorkspace
  , drawBudgetWorkspace
  , drawIssuesWorkspace
  , drawSettingsWorkspace
  , drawFlow
  , handleAccountsWorkspaceEvent
  , handleBudgetWorkspaceEvent
  , handleFlowEvent
  , handleIssuesWorkspaceEvent
  , handleSettingsWorkspaceEvent
  , publishCandidate
  , startAccountAdd
  , startBudgetMovement
  , startIssueAdd
  ) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Graphics.Vty as V
import Lens.Micro (Traversal', singular)

import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import HKernel.Account (accountName)
import HKernel.Editor.AccountAppend (AccountJournalAppendPreview)
import HKernel.Editor.BudgetMovementAppend (BudgetJournalMovementAppendPreview)
import HKernel.Editor.IssueAppend
  ( IssueAppendPreview
  , IssueClosePreview
  , IssueDueUpdatePreview
  )
import qualified HKernel.Editor.TUI.Maintenance.Accounts as Accounts
import qualified HKernel.Editor.TUI.Maintenance.Budget as Budget
import qualified HKernel.Editor.TUI.Maintenance.Issues as Issues
import HKernel.Editor.TUI.Model
  ( AppContext
  , AppEvent
  , Name(..)
  , contextHouseholdState
  )
import HKernel.Household.Application (HouseholdState(..))
import HKernel.Household.Policy
  ( householdAllocationEnvelopes
  , householdCycleIncomeAccount
  , householdEnvelopeOrder
  , householdPolicyCycle
  , householdUnassignedBudgetAccounts
  )
import HKernel.HouseholdIssue (HouseholdIssue)
import HKernel.Report.Config
  ( reportConfigurationPlan
  , reportConfigurationPresentation
  )

data State event
  = BudgetFlow (Budget.State event)
  | AccountFlow (Accounts.State event)
  | IssueFlow (Issues.State event)
  | WriteOutcome Text
  | ReturnToWorkspace
  | PublishRequested PublishRequest
  | QuitRequested

data PublishRequest
  = PublishBudget BudgetJournalMovementAppendPreview
  | PublishAccount Text AccountJournalAppendPreview
  | PublishIssueAdd IssueAppendPreview
  | PublishIssueDueUpdate IssueDueUpdatePreview
  | PublishIssueClose IssueClosePreview

data PublishResult
  = Published AppContext
  | PublicationFailed Text
  | ReloadFailed

data BudgetWorkspaceAction
  = BudgetActionMaintain
  | BudgetActionStartMovement
  deriving (Eq, Show)

data AccountsWorkspaceAction
  = AccountsActionMaintain
  | AccountsActionStartAdd
  deriving (Eq, Show)

data IssuesWorkspaceAction
  = IssuesActionMaintain
  | IssuesActionStartAdd
  | IssuesActionStartDueUpdate (State AppEvent)
  | IssuesActionStartClose (State AppEvent)
  | IssuesActionStartRealize HouseholdIssue

startBudgetMovement :: State event
startBudgetMovement = BudgetFlow Budget.start

startAccountAdd :: State event
startAccountAdd = AccountFlow Accounts.start

startIssueAdd :: State event
startIssueAdd = IssueFlow Issues.startAdd

drawBudgetWorkspace :: AppContext -> Widget Name
drawBudgetWorkspace = Budget.drawWorkspace

drawAccountsWorkspace :: AppContext -> Widget Name
drawAccountsWorkspace = Accounts.drawWorkspace

drawIssuesWorkspace :: AppContext -> Widget Name
drawIssuesWorkspace = Issues.drawWorkspace

-- | Read-only presentation of the admitted policy/configuration coordinates.
-- Main owns section navigation; this owner owns the Settings section body.
drawSettingsWorkspace :: AppContext -> Widget Name
drawSettingsWorkspace context =
  vBox
    [ borderWithLabel (str "Household Settings & Policy")
        (vLimit 18
          (viewport SettingsViewport Vertical
            (vBox
              [ str "=== [budget.toml] Envelope Policy ==="
              , str ("Envelopes count: "
                  <> show (length (householdEnvelopeOrder
                    (householdStatePolicy state))))
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
    , str "[wheel] Scroll   [h] Home   [1-7] Switch section   [q] Quit"
    ]
  where
    state = contextHouseholdState context

drawFlow :: State AppEvent -> Widget Name
drawFlow state = case state of
  BudgetFlow budgetState -> Budget.drawFlow budgetState
  AccountFlow accountState -> Accounts.drawFlow accountState
  IssueFlow issueState -> Issues.drawFlow issueState
  WriteOutcome message ->
    center (borderWithLabel (str "Maintenance Result")
      (hLimit 84 (padAll 1 (txt message <=> str " " <=> str "[Esc] Workspace   [Q] Quit"))))
  ReturnToWorkspace -> emptyWidget
  PublishRequested _ -> emptyWidget
  QuitRequested -> emptyWidget

zoomBudgetFlow :: Traversal' (State AppEvent) (Budget.State AppEvent)
zoomBudgetFlow f (BudgetFlow state) = BudgetFlow <$> f state
zoomBudgetFlow _ state = pure state

zoomAccountFlow :: Traversal' (State AppEvent) (Accounts.State AppEvent)
zoomAccountFlow f (AccountFlow state) = AccountFlow <$> f state
zoomAccountFlow _ state = pure state

zoomIssueFlow :: Traversal' (State AppEvent) (Issues.State AppEvent)
zoomIssueFlow f (IssueFlow state) = IssueFlow <$> f state
zoomIssueFlow _ state = pure state

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleFlowEvent context event = do
  state <- get
  case state of
    BudgetFlow _ -> do
      action <- zoom (singular zoomBudgetFlow) (Budget.handleFlowEvent context event)
      case action of
        Budget.FlowMaintain -> pure ()
        Budget.FlowReturn -> put ReturnToWorkspace
        Budget.FlowQuit -> put QuitRequested
        Budget.FlowPublish preview -> put (PublishRequested (PublishBudget preview))
    AccountFlow _ -> do
      action <- zoom (singular zoomAccountFlow) (Accounts.handleFlowEvent context event)
      case action of
        Accounts.FlowMaintain -> pure ()
        Accounts.FlowReturn -> put ReturnToWorkspace
        Accounts.FlowQuit -> put QuitRequested
        Accounts.FlowPublish source preview ->
          put (PublishRequested (PublishAccount source preview))
    IssueFlow _ -> do
      action <- zoom (singular zoomIssueFlow) (Issues.handleFlowEvent context event)
      case action of
        Issues.FlowMaintain -> pure ()
        Issues.FlowReturn -> put ReturnToWorkspace
        Issues.FlowQuit -> put QuitRequested
        Issues.FlowPublish request -> put (PublishRequested (fromIssueRequest request))
    WriteOutcome _ -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
      VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
      _ -> pure ()
    ReturnToWorkspace -> pure ()
    PublishRequested _ -> pure ()
    QuitRequested -> pure ()

fromIssueRequest :: Issues.PublishRequest -> PublishRequest
fromIssueRequest request = case request of
  Issues.PublishAdd preview -> PublishIssueAdd preview
  Issues.PublishDueUpdate preview -> PublishIssueDueUpdate preview
  Issues.PublishClose preview -> PublishIssueClose preview

handleBudgetWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name s BudgetWorkspaceAction
handleBudgetWorkspaceEvent event = do
  action <- Budget.handleWorkspaceEvent event
  pure $ case action of
    Budget.WorkspaceMaintain -> BudgetActionMaintain
    Budget.WorkspaceStartMovement -> BudgetActionStartMovement

handleAccountsWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name s AccountsWorkspaceAction
handleAccountsWorkspaceEvent event = do
  action <- Accounts.handleWorkspaceEvent event
  pure $ case action of
    Accounts.WorkspaceMaintain -> AccountsActionMaintain
    Accounts.WorkspaceStartAdd -> AccountsActionStartAdd

handleIssuesWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppContext IssuesWorkspaceAction
handleIssuesWorkspaceEvent event = do
  action <- Issues.handleWorkspaceEvent event
  pure $ case action of
    Issues.WorkspaceMaintain -> IssuesActionMaintain
    Issues.WorkspaceStartAdd -> IssuesActionStartAdd
    Issues.WorkspaceStartDueUpdate flow -> IssuesActionStartDueUpdate (IssueFlow flow)
    Issues.WorkspaceDueUpdateUnavailable message ->
      IssuesActionStartDueUpdate (WriteOutcome message)
    Issues.WorkspaceStartClose flow -> IssuesActionStartClose (IssueFlow flow)
    Issues.WorkspaceCloseUnavailable message ->
      IssuesActionStartClose (WriteOutcome message)
    Issues.WorkspaceStartRealize issue -> IssuesActionStartRealize issue

handleSettingsWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name s ()
handleSettingsWorkspaceEvent event = case event of
  MouseDown SettingsViewport V.BScrollUp _ _ ->
    vScrollBy (viewportScroll SettingsViewport) (-3)
  MouseDown SettingsViewport V.BScrollDown _ _ ->
    vScrollBy (viewportScroll SettingsViewport) 3
  _ -> pure ()

publishCandidate :: AppContext -> PublishRequest -> IO PublishResult
publishCandidate context request = case request of
  PublishBudget preview -> do
    result <- Budget.publishCandidate context preview
    pure $ case result of
      Budget.Published fresh -> Published fresh
      Budget.PublicationFailed message -> PublicationFailed message
      Budget.ReloadFailed -> ReloadFailed
  PublishAccount source preview -> do
    result <- Accounts.publishCandidate context source preview
    pure $ case result of
      Accounts.Published fresh -> Published fresh
      Accounts.PublicationFailed message -> PublicationFailed message
      Accounts.ReloadFailed -> ReloadFailed
  PublishIssueAdd preview -> publishIssue (Issues.PublishAdd preview)
  PublishIssueDueUpdate preview -> publishIssue (Issues.PublishDueUpdate preview)
  PublishIssueClose preview -> publishIssue (Issues.PublishClose preview)
  where
    publishIssue issueRequest = do
      result <- Issues.publishCandidate context issueRequest
      pure $ case result of
        Issues.Published fresh -> Published fresh
        Issues.PublicationFailed message -> PublicationFailed message
        Issues.ReloadFailed -> ReloadFailed
