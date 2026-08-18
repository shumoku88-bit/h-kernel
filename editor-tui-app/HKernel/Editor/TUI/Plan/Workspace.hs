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

import HKernel.Account (accountName)
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , contextPlanListL
  )
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
drawWorkspace context =
  vBox
    [ borderWithLabel (str "Open Plans (plan.journal)")
        (vLimit 18
          (L.renderList renderPlanItem True (contextPlanList context)))
    , borderWithLabel (str "Selected Plan")
        (padAll 1 (renderSelectedPlan context))
    , strWrap "[j/k/Arrows] Move   [Enter/C] Complete & Advance   [A] Add   [E] Edit"
    , strWrap "[X] Cancel   [R] Replace   [1-7] Sections   [q] Quit"
    ]

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppContext WorkspaceAction
handleWorkspaceEvent event = case event of
  MouseDown PlanList V.BScrollUp _ _ -> do
    zoom contextPlanListL (L.handleListEvent (V.EvKey V.KUp []))
    pure MaintainContext
  MouseDown PlanList V.BScrollDown _ _ -> do
    zoom contextPlanListL (L.handleListEvent (V.EvKey V.KDown []))
    pure MaintainContext
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

renderPlanItem :: Bool -> IdentifiedPlanTransaction -> Widget Name
renderPlanItem selected identified
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    transaction = identifiedPlanTransaction identified
    row = txt
      (T.pack (show (transactionDate transaction))
        <> "  [" <> planIdText (identifiedPlanId identified) <> "]  "
        <> transactionDescription transaction)

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
