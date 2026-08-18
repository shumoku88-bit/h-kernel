{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Plan
  ( PublishRequest(..)
  , PublishResult(..)
  , State(..)
  , WorkspaceAction(..)
  , drawFlow
  , drawWorkspace
  , handleFlowEvent
  , handleWorkspaceEvent
  , publishCandidate
  , startAdd
  , startSelectedCancel
  , startSelectedCompletion
  , startSelectedEdit
  , startSelectedReplace
  ) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Graphics.Vty as V
import Lens.Micro (Traversal', singular)

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T

import HKernel.Application.Config (HouseholdSourcePaths(..))
import HKernel.Editor.PlanCompleteAdvance
  ( PlanCompleteAdvancePreview(..)
  , PlanCompleteAdvanceWriteError(..)
  , PlanCompleteAdvanceWriteIntent(..)
  , publishPlanCompleteAdvance
  )
import HKernel.Editor.PlanLifecycle
  ( PlanAddPreview(..)
  , PlanCancelPreview(..)
  , PlanEditPreview(..)
  , PlanSupersedePreview(..)
  )
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteIntent(..)
  , admitPlanJournalRootSource
  , publishWithPathAdmission
  )
import qualified HKernel.Editor.TUI.Plan.CompleteAdvance as CompleteAdvance
import qualified HKernel.Editor.TUI.Plan.Lifecycle as Lifecycle
import qualified HKernel.Editor.TUI.Plan.Workspace as Workspace
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name
  , contextHouseholdState
  , contextPlanSource
  , contextSource
  , contextSourcePath
  , reloadWorkspaceContext
  )
import HKernel.Household.Application
  ( HouseholdState(..)
  , loadCanonicalHousehold
  )
import HKernel.Plan (PlanId)

data State event
  = CompleteAdvanceFlow (CompleteAdvance.State event)
  | LifecycleFlow (Lifecycle.State event)
  | WriteOutcome Text
  | ReturnToWorkspace
  | PublishRequested PublishRequest
  | QuitRequested

data PublishRequest
  = PublishCompleteAdvance PlanId PlanCompleteAdvancePreview
  | PublishAdd PlanAddPreview
  | PublishEdit PlanEditPreview
  | PublishCancel PlanCancelPreview
  | PublishSupersede PlanSupersedePreview

data PublishResult
  = Published AppContext
  | PublicationFailed Text
  | ReloadFailed

startSelectedCompletion :: AppContext -> Maybe (State event)
startSelectedCompletion context = do
  result <- CompleteAdvance.startSelectedCompletion context
  pure $ case result of
    Left message -> WriteOutcome message
    Right flow -> CompleteAdvanceFlow flow

startAdd :: AppContext -> State event
startAdd = LifecycleFlow . Lifecycle.startAdd

startSelectedEdit :: AppContext -> Maybe (State event)
startSelectedEdit context =
  LifecycleFlow <$> Lifecycle.startSelectedEdit context

startSelectedCancel :: AppContext -> Maybe (State event)
startSelectedCancel context =
  LifecycleFlow <$> Lifecycle.startSelectedCancel context

startSelectedReplace :: AppContext -> Maybe (State event)
startSelectedReplace context =
  LifecycleFlow <$> Lifecycle.startSelectedReplace context

zoomCompleteAdvanceFlow
  :: Traversal' (State AppEvent) (CompleteAdvance.State AppEvent)
zoomCompleteAdvanceFlow f (CompleteAdvanceFlow state) =
  CompleteAdvanceFlow <$> f state
zoomCompleteAdvanceFlow _ state = pure state

zoomLifecycleFlow :: Traversal' (State AppEvent) (Lifecycle.State AppEvent)
zoomLifecycleFlow f (LifecycleFlow state) = LifecycleFlow <$> f state
zoomLifecycleFlow _ state = pure state

drawFlow :: State AppEvent -> Widget Name
drawFlow state = case state of
  CompleteAdvanceFlow flow -> CompleteAdvance.drawFlow flow
  LifecycleFlow flow -> Lifecycle.drawFlow flow
  WriteOutcome message ->
    center
      (borderWithLabel (str "Plan Result")
        (padAll 1
          (txtWrap message <=> str " " <=> strWrap "[Esc] Plans | [Q] Quit")))
  ReturnToWorkspace -> emptyWidget
  PublishRequested _ -> emptyWidget
  QuitRequested -> emptyWidget

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleFlowEvent context event = do
  state <- get
  case state of
    CompleteAdvanceFlow _ -> do
      action <- zoom (singular zoomCompleteAdvanceFlow)
        (CompleteAdvance.handleFlowEvent context event)
      case action of
        CompleteAdvance.FlowMaintain -> pure ()
        CompleteAdvance.FlowReturn -> put ReturnToWorkspace
        CompleteAdvance.FlowQuit -> put QuitRequested
        CompleteAdvance.FlowPublish planId preview ->
          put (PublishRequested (PublishCompleteAdvance planId preview))
    LifecycleFlow _ -> do
      action <- zoom (singular zoomLifecycleFlow)
        (Lifecycle.handleFlowEvent context event)
      case action of
        Lifecycle.FlowMaintain -> pure ()
        Lifecycle.FlowReturn -> put ReturnToWorkspace
        Lifecycle.FlowQuit -> put QuitRequested
        Lifecycle.FlowPublishAdd preview ->
          put (PublishRequested (PublishAdd preview))
        Lifecycle.FlowPublishEdit preview ->
          put (PublishRequested (PublishEdit preview))
        Lifecycle.FlowPublishCancel preview ->
          put (PublishRequested (PublishCancel preview))
        Lifecycle.FlowPublishSupersede preview ->
          put (PublishRequested (PublishSupersede preview))
    WriteOutcome _ -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
      VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
      _ -> pure ()
    ReturnToWorkspace -> pure ()
    PublishRequested _ -> pure ()
    QuitRequested -> pure ()

drawWorkspace :: AppContext -> Widget Name
drawWorkspace = Workspace.drawWorkspace

data WorkspaceAction
  = MaintainContext
  | StartFlow (State AppEvent)

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppContext WorkspaceAction
handleWorkspaceEvent event = do
  action <- Workspace.handleWorkspaceEvent event
  context <- get
  case action of
    Workspace.MaintainContext -> pure MaintainContext
    Workspace.OpenCompletion ->
      pure (maybe MaintainContext StartFlow (startSelectedCompletion context))
    Workspace.OpenAdd -> pure (StartFlow (startAdd context))
    Workspace.OpenEdit ->
      pure (maybe MaintainContext StartFlow (startSelectedEdit context))
    Workspace.OpenCancel ->
      pure (maybe MaintainContext StartFlow (startSelectedCancel context))
    Workspace.OpenReplace ->
      pure (maybe MaintainContext StartFlow (startSelectedReplace context))

publishCandidate :: AppContext -> PublishRequest -> IO PublishResult
publishCandidate context request = case request of
  PublishCompleteAdvance planId preview ->
    publishCompleteAdvance context planId preview
  PublishAdd preview ->
    publishPlanRoot context (addCandidateCompleteSource preview)
  PublishEdit preview ->
    publishPlanRoot context (editCandidateCompleteSource preview)
  PublishCancel preview ->
    publishPlanRoot context (cancelCandidateCompleteSource preview)
  PublishSupersede preview ->
    publishPlanRoot context (supersedeCandidateCompleteSource preview)

publishCompleteAdvance
  :: AppContext
  -> PlanId
  -> PlanCompleteAdvancePreview
  -> IO PublishResult
publishCompleteAdvance context _planId preview = do
  let state = contextHouseholdState context
      paths = householdStatePaths state
      root = householdStateRoot state
      planPath = householdPlanJournalPath paths
      intent = PlanCompleteAdvanceWriteIntent
        { writeActualPath = contextSourcePath context
        , writeExpectedActual = contextSource context
        , writeCandidateActual = completeAdvanceActualSource preview
        , writePlanPath = planPath
        , writeExpectedPlan = contextPlanSource context
        , writeCandidatePlan = completeAdvancePlanSource preview
        }
      postAdmission = loadCanonicalHousehold root
  writeResult <- publishPlanCompleteAdvance postAdmission intent
  case writeResult of
    Left writeError -> pure (PublicationFailed (renderWriteError writeError))
    Right () -> reloadPlans context

publishPlanRoot :: AppContext -> Text -> IO PublishResult
publishPlanRoot context candidate = do
  let state = contextHouseholdState context
      root = householdStateRoot state
      planPath = householdPlanJournalPath (householdStatePaths state)
  preAdmission <- admitPlanJournalRootSource planPath candidate
  case preAdmission of
    Left errors -> pure
      (PublicationFailed
        ("Plan candidate path admission failed: "
          <> showText (NonEmpty.toList errors)))
    Right _ -> do
      writeResult <- publishWithPathAdmission
        (\_ -> loadCanonicalHousehold root)
        WriteIntent
          { targetFilePath = planPath
          , expectedOldBytes = ExpectedSource (contextPlanSource context)
          , candidateNewBytes = CandidateSource candidate
          }
      case writeResult of
        Left err -> pure (PublicationFailed (showText err))
        Right () -> reloadPlans context

reloadPlans :: AppContext -> IO PublishResult
reloadPlans context = do
  reloaded <- reloadWorkspaceContext
    (context { contextCurrentSection = PlansSection })
  pure $ case reloaded of
    Nothing -> ReloadFailed
    Just freshContext -> Published
      (freshContext { contextCurrentSection = PlansSection })

renderWriteError :: PlanCompleteAdvanceWriteError admissionError -> Text
renderWriteError writeError = case writeError of
  PlanCompleteAdvanceActualStale ->
    "actual.journal changed after preview. Nothing was published."
  PlanCompleteAdvancePlanStale ->
    "plan.journal changed after preview. Nothing was published."
  PlanCompleteAdvancePostAdmissionFailed _ actualRestored planRestored ->
    "Whole-Household post-admission failed. Actual restored: "
      <> yesNo actualRestored <> "; Plan restored: " <> yesNo planRestored
  PlanCompleteAdvanceFileIOError _ actualRestored planRestored ->
    "Filesystem publication failed. Actual restored: "
      <> yesNo actualRestored <> "; Plan restored: " <> yesNo planRestored
  where
    yesNo True = "YES"
    yesNo False = "NO"

showText :: Show value => value -> Text
showText = T.pack . show
