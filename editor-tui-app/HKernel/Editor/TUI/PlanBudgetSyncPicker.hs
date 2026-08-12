{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.PlanBudgetSyncPicker
  ( Action(..)
  , State
  , draw
  , handleEvent
  , start
  ) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Lens.Micro (Lens')
import Lens.Micro.Mtl ()

import qualified Data.Text as T
import qualified Data.Vector as Vec

import HKernel.Actual.Journal (actualJournalCompletionDeclarations)
import HKernel.Editor.TUI.Model
  ( AppContext
  , AppEvent
  , Name(..)
  , contextHouseholdState
  )
import HKernel.Household.Application (HouseholdState(..))
import HKernel.Ledger (transactionDate, transactionDescription)
import HKernel.Plan (PlanId, planIdText)
import HKernel.Plan.Completion (declaredCompletionPlanId)
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalTransactions
  )

newtype State = State (L.List Name IdentifiedPlanTransaction)

data Action
  = Maintain
  | ReturnToWorkspace
  | QuitRequested
  | Retry PlanId

start :: AppContext -> Either T.Text State
start context =
  case completedPlans of
    [] -> Left "No completed Plans are available for Budget sync retry."
    _ -> Right (State (L.list PlanList (Vec.fromList completedPlans) 1))
  where
    household = contextHouseholdState context
    completedIds = map declaredCompletionPlanId
      (actualJournalCompletionDeclarations (householdStateActualJournal household))
    completedPlans = filter
      (\identified -> identifiedPlanId identified `elem` completedIds)
      (planJournalTransactions (householdStatePlanJournal household))

draw :: State -> Widget Name
draw (State plans) =
  center
    (borderWithLabel (str "Retry completed Plan Budget sync")
      (hLimit 86
        (vLimit 24
          (padAll 1
            ( L.renderList renderCompletedPlan True plans
              <=> str " "
              <=> str "[wheel/↑/↓ or j/k] Move   [Enter] Retry sync   [Esc] Back   [Q] Quit")))))

renderCompletedPlan :: Bool -> IdentifiedPlanTransaction -> Widget Name
renderCompletedPlan selected identified
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    transaction = identifiedPlanTransaction identified
    row = txt
      ( T.pack (show (transactionDate transaction))
        <> "  " <> transactionDescription transaction
        <> "  [" <> planIdText (identifiedPlanId identified) <> "]"
      )

stateListL :: Lens' State (L.List Name IdentifiedPlanTransaction)
stateListL f (State plans) = State <$> f plans

handleEvent
  :: BrickEvent Name AppEvent
  -> EventM Name State Action
handleEvent event = case event of
  MouseDown PlanList V.BScrollUp _ _ -> do
    zoom stateListL (L.handleListEvent (V.EvKey V.KUp []))
    pure Maintain
  MouseDown PlanList V.BScrollDown _ _ -> do
    zoom stateListL (L.handleListEvent (V.EvKey V.KDown []))
    pure Maintain
  MouseDown PlanList V.BLeft _ (Location (_, row)) -> do
    zoom stateListL (modify (L.listMoveTo row))
    pure Maintain
  VtyEvent (V.EvKey V.KEsc []) -> pure ReturnToWorkspace
  VtyEvent (V.EvKey (V.KChar 'q') []) -> pure QuitRequested
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure QuitRequested
  VtyEvent (V.EvKey V.KEnter []) -> do
    State plans <- get
    pure $ case L.listSelectedElement plans of
      Nothing -> ReturnToWorkspace
      Just (_, identified) -> Retry (identifiedPlanId identified)
  VtyEvent vtyEvent -> do
    zoom stateListL (L.handleListEventVi L.handleListEvent vtyEvent)
    pure Maintain
  _ -> pure Maintain
