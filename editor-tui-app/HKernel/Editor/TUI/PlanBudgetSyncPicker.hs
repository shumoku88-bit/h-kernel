{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.PlanBudgetSyncPicker
  ( Action(..)
  , State
  , action
  , draw
  , handleEvent
  , start
  ) where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Lens.Micro (Traversal')
import Lens.Micro.Mtl ()

import qualified Data.Text as T

import HKernel.Editor.TUI.Model
  ( AppContext
  , AppEvent
  , Name(..)
  )
import HKernel.Ledger (transactionDate, transactionDescription)
import HKernel.Plan (PlanId, planIdText)
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , identifiedPlanId
  , identifiedPlanTransaction
  )

data State
  = Picking (L.List Name IdentifiedPlanTransaction)
  | PickerReturnRequested
  | PickerQuitRequested
  | PickerRetryRequested PlanId

data Action
  = Maintain
  | ReturnToWorkspace
  | QuitRequested
  | Retry PlanId

-- | The execution sync writer is retired. Completed Plans are observed directly
-- by Envelope Consumption/Fulfillment, so there is nothing to retry or publish
-- into budget.journal.
start :: AppContext -> Either T.Text State
start _ = Left
  "Budget sync is retired. Completed Plans are observed directly by Envelope semantics."

action :: State -> Action
action state = case state of
  Picking _ -> Maintain
  PickerReturnRequested -> ReturnToWorkspace
  PickerQuitRequested -> QuitRequested
  PickerRetryRequested planId -> Retry planId

draw :: State -> Widget Name
draw state = case state of
  Picking plans ->
    center
      (borderWithLabel (str "Retired Plan Budget sync")
        (hLimit 86
          (vLimit 24
            (padAll 1
              ( L.renderList renderCompletedPlan True plans
                <=> str " "
                <=> str "This compatibility picker is no longer opened by start."
                <=> str "[Esc] Back   [Q] Quit")))))
  PickerReturnRequested -> emptyWidget
  PickerQuitRequested -> emptyWidget
  PickerRetryRequested _ -> emptyWidget

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

stateListL :: Traversal' State (L.List Name IdentifiedPlanTransaction)
stateListL f (Picking plans) = Picking <$> f plans
stateListL _ state = pure state

handleEvent
  :: BrickEvent Name AppEvent
  -> EventM Name State ()
handleEvent event = do
  state <- get
  case state of
    Picking _ -> handlePickingEvent event
    PickerReturnRequested -> pure ()
    PickerQuitRequested -> pure ()
    PickerRetryRequested _ -> pure ()

handlePickingEvent
  :: BrickEvent Name AppEvent
  -> EventM Name State ()
handlePickingEvent event = case event of
  MouseDown PlanList V.BScrollUp _ _ ->
    zoom stateListL (L.handleListEvent (V.EvKey V.KUp []))
  MouseDown PlanList V.BScrollDown _ _ ->
    zoom stateListL (L.handleListEvent (V.EvKey V.KDown []))
  MouseDown PlanList V.BLeft _ (Location (_, row)) ->
    zoom stateListL (modify (L.listMoveTo row))
  VtyEvent (V.EvKey V.KEsc []) -> put PickerReturnRequested
  VtyEvent (V.EvKey (V.KChar 'q') []) -> put PickerQuitRequested
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> put PickerQuitRequested
  VtyEvent (V.EvKey V.KEnter []) -> do
    state <- get
    case state of
      Picking plans -> case L.listSelectedElement plans of
        Nothing -> put PickerReturnRequested
        Just (_, identified) -> put (PickerRetryRequested (identifiedPlanId identified))
      _ -> pure ()
  VtyEvent vtyEvent ->
    zoom stateListL (L.handleListEventVi L.handleListEvent vtyEvent)
  _ -> pure ()
