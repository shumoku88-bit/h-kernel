{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Plan.Workspace
  ( WorkspaceAction(..)
  , drawWorkspace
  , handleWorkspaceEvent
  ) where

import Brick
import Brick.Widgets.Border
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (Day)

import HKernel.Account (accountName)
import HKernel.Editor.TUI.DateUrgency (withDateUrgency)
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , contextOpenPlanObservation
  , contextPlanListL
  )
import HKernel.Editor.TUI.Scroll qualified as Scroll
import HKernel.Ledger
  ( Posting
  , postingAccount
  , postingAmount
  , transactionDate
  , transactionDescription
  , transactionPostings
  )
import HKernel.Money
  ( amountCommodity
  , amountQuantity
  , commodityCode
  , renderQuantity
  )
import HKernel.Plan (planIdText)
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , identifiedPlanId
  , identifiedPlanTransaction
  )

data WorkspaceAction
  = MaintainContext
  | OpenCompletion
  | OpenAdd
  | OpenEdit
  | OpenCancel
  | OpenReplace
  deriving (Eq, Show)

drawWorkspace :: AppContext -> Widget Name
drawWorkspace context = case contextOpenPlanObservation context of
  Left errors ->
    vBox
      [ borderWithLabel (str "Open Plans (plan.journal)")
          (padAll 1
            (withAttr (attrName "warning")
              (vBox
                [ strWrap "Open Plan observation is unavailable for this Household observation."
                , txtWrap ("Reason: " <> T.pack (show errors))
                , strWrap "Existing Plan mutation targets are hidden rather than treated as an empty set."
                ])))
      , strWrap "[a] Add Plan   Existing Plan Complete/Edit/Cancel/Replace unavailable"
      ]
  Right _ ->
    vBox
      [ borderWithLabel (str "Open Plans (plan.journal)")
          (vLimit 18
            (L.renderList
              (renderPlanItem (contextObservationDay context))
              True
              (contextPlanList context)))
      , borderWithLabel (str "Selected Plan")
          (padAll 1 (renderSelectedPlan context))
      , strWrap "[j/k/Arrows/wheel] Move   [Enter/c] Complete & Advance   [a] Add   [e] Edit"
      , strWrap "[x] Cancel   [r] Replace"
      ]

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppContext WorkspaceAction
handleWorkspaceEvent event = do
  context <- get
  case contextOpenPlanObservation context of
    Left _ -> handleUnavailable event
    Right _ -> handleAvailable event
  where
    handleUnavailable currentEvent = case currentEvent of
      VtyEvent (V.EvKey (V.KChar 'a') []) -> pure OpenAdd
      VtyEvent (V.EvKey (V.KChar 'A') []) -> pure OpenAdd
      _ -> pure MaintainContext
    handleAvailable currentEvent = case Scroll.listWheelEvent PlanList currentEvent of
      Just wheelEvent -> do
        zoom contextPlanListL (L.handleListEvent wheelEvent)
        pure MaintainContext
      Nothing -> case currentEvent of
        MouseDown PlanList V.BLeft _ (Location (_, row)) -> do
          zoom contextPlanListL (modify (L.listMoveTo row))
          pure MaintainContext
        VtyEvent (V.EvKey (V.KChar 'a') []) -> pure OpenAdd
        VtyEvent (V.EvKey (V.KChar 'A') []) -> pure OpenAdd
        VtyEvent (V.EvKey (V.KChar 'e') []) -> pure OpenEdit
        VtyEvent (V.EvKey (V.KChar 'E') []) -> pure OpenEdit
        VtyEvent (V.EvKey (V.KChar 'x') []) -> pure OpenCancel
        VtyEvent (V.EvKey (V.KChar 'X') []) -> pure OpenCancel
        VtyEvent (V.EvKey (V.KChar 'r') []) -> pure OpenReplace
        VtyEvent (V.EvKey (V.KChar 'R') []) -> pure OpenReplace
        VtyEvent (V.EvKey V.KEnter []) -> pure OpenCompletion
        VtyEvent (V.EvKey (V.KChar 'c') []) -> pure OpenCompletion
        VtyEvent (V.EvKey (V.KChar 'C') []) -> pure OpenCompletion
        VtyEvent (V.EvKey vtyKey vtyMods) -> do
          zoom contextPlanListL
            (L.handleListEventVi L.handleListEvent (V.EvKey vtyKey vtyMods))
          pure MaintainContext
        _ -> pure MaintainContext

renderPlanItem :: Day -> Bool -> IdentifiedPlanTransaction -> Widget Name
renderPlanItem observedOn selected identified
  | selected = withAttr L.listSelectedAttr (row dateWidget)
  | otherwise = row (withDateUrgency observedOn dueOn dateWidget)
  where
    transaction = identifiedPlanTransaction identified
    dueOn = transactionDate transaction
    dateWidget = txt (T.pack (show dueOn))
    row renderedDate = hBox
      [ renderedDate
      , txt ("  [" <> planIdText (identifiedPlanId identified) <> "]  "
          <> transactionDescription transaction)
      ]

renderSelectedPlan :: AppContext -> Widget Name
renderSelectedPlan context = case L.listSelectedElement (contextPlanList context) of
  Nothing -> str "No open Plans."
  Just (_, identified) -> renderIdentifiedPlan identified

renderIdentifiedPlan :: IdentifiedPlanTransaction -> Widget Name
renderIdentifiedPlan identified =
  let transaction = identifiedPlanTransaction identified
  in vBox
    ( txtWrap (T.pack (show (transactionDate transaction))
        <> "  [" <> planIdText (identifiedPlanId identified) <> "]  "
        <> transactionDescription transaction)
      : map renderPosting (NonEmpty.toList (transactionPostings transaction))
    )

renderPosting :: Posting -> Widget Name
renderPosting posting =
  txtWrap ("  " <> accountName (postingAccount posting) <> "  "
    <> renderQuantity (amountQuantity amount) <> " "
    <> commodityCode (amountCommodity amount))
  where
    amount = postingAmount posting
