{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Maintenance
  ( AccountsWorkspaceAction(..)
  , EntitlementWorkspaceAction(..)
  , IssuesWorkspaceAction(..)
  , PublishRequest(..)
  , PublishResult(..)
  , State(..)
  , drawAccountsWorkspace
  , drawEntitlementWorkspace
  , drawIssuesWorkspace
  , drawFlow
  , handleAccountsWorkspaceEvent
  , handleEntitlementWorkspaceEvent
  , handleFlowEvent
  , handleIssuesWorkspaceEvent
  , publishCandidate
  , startAccountAdd
  , startEntitlementTransfer
  , startIssueAdd
  ) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Graphics.Vty as V
import Lens.Micro (Traversal', singular)

import Data.Text (Text)

import HKernel.Editor.AccountAppend (AccountJournalAppendPreview)
import HKernel.Editor.EntitlementTransferAppend (EntitlementTransferAppendPreview)
import HKernel.Editor.IssueAppend
  ( IssueAppendPreview
  , IssueClosePreview
  , IssueDueUpdatePreview
  )
import qualified HKernel.Editor.TUI.Maintenance.Accounts as Accounts
import qualified HKernel.Editor.TUI.Maintenance.Entitlement as Entitlement
import qualified HKernel.Editor.TUI.Maintenance.Issues as Issues
import HKernel.Editor.TUI.Model
  ( AppContext
  , AppEvent
  , Name
  , WorkspaceReloadFailure
  )
import HKernel.HouseholdIssue (HouseholdIssue)

data State event
  = EntitlementFlow (Entitlement.State event)
  | AccountFlow (Accounts.State event)
  | IssueFlow (Issues.State event)
  | WriteOutcome Text
  | ReturnToWorkspace
  | PublishRequested PublishRequest
  | QuitRequested

data PublishRequest
  = PublishEntitlement EntitlementTransferAppendPreview
  | PublishAccount Text AccountJournalAppendPreview
  | PublishIssueAdd IssueAppendPreview
  | PublishIssueDueUpdate IssueDueUpdatePreview
  | PublishIssueClose IssueClosePreview

data PublishResult
  = Published AppContext
  | PublicationFailed Text
  | ReloadFailed WorkspaceReloadFailure

data EntitlementWorkspaceAction
  = EntitlementActionMaintain
  | EntitlementActionStartTransfer
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

startEntitlementTransfer :: State event
startEntitlementTransfer = EntitlementFlow Entitlement.start

startAccountAdd :: State event
startAccountAdd = AccountFlow Accounts.start

startIssueAdd :: State event
startIssueAdd = IssueFlow Issues.startAdd

drawEntitlementWorkspace :: AppContext -> Widget Name
drawEntitlementWorkspace = Entitlement.drawWorkspace

drawAccountsWorkspace :: AppContext -> Widget Name
drawAccountsWorkspace = Accounts.drawWorkspace

drawIssuesWorkspace :: AppContext -> Widget Name
drawIssuesWorkspace = Issues.drawWorkspace

drawFlow :: State AppEvent -> Widget Name
drawFlow state = case state of
  EntitlementFlow entitlementState -> Entitlement.drawFlow entitlementState
  AccountFlow accountState -> Accounts.drawFlow accountState
  IssueFlow issueState -> Issues.drawFlow issueState
  WriteOutcome message ->
    center (borderWithLabel (str "Maintenance Result")
      (hLimit 84
        (padAll 1
          (txtWrap message <=> str " " <=> strWrap "[Esc] Workspace   [Q] Quit"))))
  ReturnToWorkspace -> emptyWidget
  PublishRequested _ -> emptyWidget
  QuitRequested -> emptyWidget

zoomEntitlementFlow :: Traversal' (State AppEvent) (Entitlement.State AppEvent)
zoomEntitlementFlow f (EntitlementFlow state) = EntitlementFlow <$> f state
zoomEntitlementFlow _ state = pure state

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
    EntitlementFlow _ -> do
      action <- zoom (singular zoomEntitlementFlow) (Entitlement.handleFlowEvent context event)
      case action of
        Entitlement.FlowMaintain -> pure ()
        Entitlement.FlowReturn -> put ReturnToWorkspace
        Entitlement.FlowQuit -> put QuitRequested
        Entitlement.FlowPublish preview -> put (PublishRequested (PublishEntitlement preview))
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

handleEntitlementWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name s EntitlementWorkspaceAction
handleEntitlementWorkspaceEvent event = do
  action <- Entitlement.handleWorkspaceEvent event
  pure $ case action of
    Entitlement.WorkspaceMaintain -> EntitlementActionMaintain
    Entitlement.WorkspaceStartTransfer -> EntitlementActionStartTransfer

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

publishCandidate :: AppContext -> PublishRequest -> IO PublishResult
publishCandidate context request = case request of
  PublishEntitlement preview -> do
    result <- Entitlement.publishCandidate context preview
    pure $ case result of
      Entitlement.Published fresh -> Published fresh
      Entitlement.PublicationFailed message -> PublicationFailed message
      Entitlement.ReloadFailed failure -> ReloadFailed failure
  PublishAccount source preview -> do
    result <- Accounts.publishCandidate context source preview
    pure $ case result of
      Accounts.Published fresh -> Published fresh
      Accounts.PublicationFailed message -> PublicationFailed message
      Accounts.ReloadFailed failure -> ReloadFailed failure
  PublishIssueAdd preview -> publishIssue (Issues.PublishAdd preview)
  PublishIssueDueUpdate preview -> publishIssue (Issues.PublishDueUpdate preview)
  PublishIssueClose preview -> publishIssue (Issues.PublishClose preview)
  where
    publishIssue issueRequest = do
      result <- Issues.publishCandidate context issueRequest
      pure $ case result of
        Issues.Published fresh -> Published fresh
        Issues.PublicationFailed message -> PublicationFailed message
        Issues.ReloadFailed failure -> ReloadFailed failure
