{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Maintenance.Entitlement
  ( State
  , FlowAction(..)
  , WorkspaceAction(..)
  , PublishResult(..)
  , drawFlow
  , drawWorkspace
  , handleFlowEvent
  , handleWorkspaceEvent
  , publishCandidate
  , start
  ) where

import Brick
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Graphics.Vty as V
import Lens.Micro (Lens', Traversal')

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)

import HKernel.Application.Config (HouseholdSourcePaths(..))
import HKernel.Envelope.Entitlement.Journal (renderEntitlementTransfer, renderStockOrigin)
import HKernel.Envelope.StockOrigin (StockOrigin(..))
import HKernel.Money (mkAmount, mkCommodity, parseQuantity)
import HKernel.Envelope.EntitlementHistory
  ( envelopeEntitlementHistoryOrigins
  , envelopeEntitlementHistoryTransfers
  )
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , EnvelopeEntitlementTransfer
  , mkEnvelopeEntitlementTransfer
  )
import HKernel.Envelope.Identity (envelopeIdText, mkEnvelopeId)
import HKernel.Envelope.Policy
  ( EnvelopeDefinition
  , currentEnvelopePolicyDefinitions
  , envelopeDefinitionId
  )
import HKernel.Editor.EntitlementTransferAppend
  ( EntitlementTransferAppendPreview(..)
  , prepareCurrentEntitlementTransferAppend
  , publishCurrentEntitlementTransferFromPreview
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , WorkspaceReloadFailure
  , contextEntitlementSource
  , contextHouseholdState
  , reloadWorkspaceContext
  )
import HKernel.Editor.TUI.Scroll qualified as Scroll
import HKernel.Household.Application
  ( HouseholdState(..)
  , loadCanonicalHousehold
  )
import HKernel.Household.EnvelopeHistory (householdEnvelopeRegistry)

data PreviewResult preview
  = PreviewRejected Text
  | PreviewReady preview

data EntitlementInput = EntitlementInput
  { entitlementMemoText      :: Text
  , entitlementFromText      :: Text
  , entitlementToText        :: Text
  , entitlementAmountText    :: Text
  , entitlementCommodityText :: Text
  } deriving (Eq, Show)

data State event
  = Input (Form EntitlementInput event Name)
  | Preview (PreviewResult EntitlementTransferAppendPreview) (Form EntitlementInput event Name)

data FlowAction
  = FlowMaintain
  | FlowReturn
  | FlowQuit
  | FlowPublish EntitlementTransferAppendPreview

data WorkspaceAction
  = WorkspaceMaintain
  | WorkspaceStartTransfer
  deriving (Eq, Show)

data PublishResult
  = Published AppContext
  | PublicationFailed Text
  | ReloadFailed WorkspaceReloadFailure

entitlementMemoL :: Lens' EntitlementInput Text
entitlementMemoL f input = (\value -> input { entitlementMemoText = value }) <$> f (entitlementMemoText input)

entitlementFromL :: Lens' EntitlementInput Text
entitlementFromL f input = (\value -> input { entitlementFromText = value }) <$> f (entitlementFromText input)

entitlementToL :: Lens' EntitlementInput Text
entitlementToL f input = (\value -> input { entitlementToText = value }) <$> f (entitlementToText input)

entitlementAmountL :: Lens' EntitlementInput Text
entitlementAmountL f input = (\value -> input { entitlementAmountText = value }) <$> f (entitlementAmountText input)

entitlementCommodityL :: Lens' EntitlementInput Text
entitlementCommodityL f input = (\value -> input { entitlementCommodityText = value }) <$> f (entitlementCommodityText input)

labelField :: String -> Widget Name -> Widget Name
labelField labelText widget =
  padBottom (Pad 1) ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)

mkForm :: Form EntitlementInput event Name
mkForm =
  newForm
    [ labelField "Memo:" @@= editTextField entitlementMemoL EntitlementMemoField (Just 1)
    , labelField "From (unallocated/env):" @@= editTextField entitlementFromL EntitlementFromField (Just 1)
    , labelField "To (unallocated/env):" @@= editTextField entitlementToL EntitlementToField (Just 1)
    , labelField "Amount:" @@= editTextField entitlementAmountL EntitlementAmountField (Just 1)
    , labelField "Commodity:" @@= editTextField entitlementCommodityL EntitlementCommodityField (Just 1)
    ]
    (EntitlementInput "alloc" "unallocated" "" "" "JPY")

start :: State event
start = Input mkForm

zoomForm :: Traversal' (State AppEvent) (Form EntitlementInput AppEvent Name)
zoomForm f (Input form) = Input <$> f form
zoomForm _ state = pure state

drawFlow :: State AppEvent -> Widget Name
drawFlow state = case state of
  Input form ->
    inputBox "New Entitlement Transfer" form
      [ "Endpoints must be 'unallocated' or a valid current Envelope identity."
      , "[Tab] Next field   [Enter] Preview   [Esc] Envelopes"
      ]
  Preview result _ ->
    previewBox "Entitlement Transfer Preview"
      (renderPreviewResult (txtWrap . entitlementCandidateBlock) result)
      (previewControls result)

inputBox :: String -> Form input AppEvent Name -> [String] -> Widget Name
inputBox title form helpLines =
  center
    (borderWithLabel (str title)
      (hLimit 82
        (padAll 1
          (renderForm form <=> str " " <=> vBox (map strWrap helpLines)))))

previewBox :: String -> Widget Name -> String -> Widget Name
previewBox title body controls =
  center
    (borderWithLabel (str title)
      (hLimit 88
        (vLimit 32
          (padAll 1
            (body <=> str " " <=> strWrap controls)))))

renderPreviewResult
  :: (preview -> Widget Name)
  -> PreviewResult preview
  -> Widget Name
renderPreviewResult renderPreview result = case result of
  PreviewRejected message -> withAttr (attrName "error") (txtWrap message)
  PreviewReady preview -> renderPreview preview

previewControls :: PreviewResult preview -> String
previewControls result = case result of
  PreviewReady _ -> "[Enter] Publish   [Esc] Back   [Q] Quit"
  PreviewRejected _ -> "[Esc] Back   [Q] Quit"

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleFlowEvent context event = do
  state <- get
  case state of
    Input form -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
      VtyEvent (V.EvKey V.KEnter []) -> do
        case prepareEntitlement context (formState form) of
          Left message -> put (Preview (PreviewRejected message) form)
          Right preview -> put (Preview (PreviewReady preview) form)
        pure FlowMaintain
      _ -> do
        zoom zoomForm (handleFormEvent event)
        pure FlowMaintain
    Preview result form -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put (Input form) >> pure FlowMaintain
      VtyEvent (V.EvKey V.KEnter []) -> case result of
        PreviewRejected _ -> pure FlowMaintain
        PreviewReady preview -> pure (FlowPublish preview)
      VtyEvent (V.EvKey (V.KChar 'q') []) -> pure FlowQuit
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure FlowQuit
      _ -> pure FlowMaintain

prepareEntitlement :: AppContext -> EntitlementInput -> Either Text EntitlementTransferAppendPreview
prepareEntitlement context input = do
  fromEndpoint <- parseEndpoint (T.strip (entitlementFromText input))
  toEndpoint <- parseEndpoint (T.strip (entitlementToText input))
  qtyText <- case T.strip (entitlementAmountText input) of
    "" -> Left "Amount is required."
    val -> Right val
  commText <- case T.strip (entitlementCommodityText input) of
    "" -> Left "Commodity is required."
    val -> Right val
  quantity <- case parseQuantity qtyText of
    Right q -> Right q
    Left _ -> Left "Invalid quantity."
  commodity <- case mkCommodity commText of
    Right c -> Right c
    Left _ -> Left "Invalid Commodity."
  let amount = mkAmount commodity quantity
      memo = T.strip (entitlementMemoText input)
      day = contextEntryDay context
  transfer <- case mkEnvelopeEntitlementTransfer day fromEndpoint toEndpoint amount memo of
    Left err -> Left ("Invalid transfer: " <> showText err)
    Right tr -> Right tr
  let state = contextHouseholdState context
      envelopePolicy = householdStateEnvelopePolicy state
      registry = householdEnvelopeRegistry (householdStateEnvelopeHistory state)
  case prepareCurrentEntitlementTransferAppend envelopePolicy registry (contextEntitlementSource context) transfer of
    Left errors -> Left ("Entitlement transfer rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview
  where
    parseEndpoint text
      | T.toCaseFold text == "unallocated" = Right Unallocated
      | otherwise = case mkEnvelopeId text of
          Right eid -> Right (Spendable eid)
          Left err -> Left ("Invalid Envelope identity: " <> showText err)

publishCandidate :: AppContext -> EntitlementTransferAppendPreview -> IO PublishResult
publishCandidate context preview = do
  let state = contextHouseholdState context
      paths = householdStatePaths state
      root = householdStateRoot state
      envelopePolicy = householdStateEnvelopePolicy state
      registry = householdEnvelopeRegistry (householdStateEnvelopeHistory state)
  result <- publishCurrentEntitlementTransferFromPreview
    (\_ -> loadCanonicalHousehold root)
    (householdEntitlementJournalPath paths)
    envelopePolicy
    registry
    preview
  case result of
    Left err -> pure (PublicationFailed (T.pack (show err)))
    Right () -> do
      reloaded <- reloadWorkspaceContext (context { contextCurrentSection = EntitlementSection })
      pure $ case reloaded of
        Left failure -> ReloadFailed failure
        Right fresh -> Published (fresh { contextCurrentSection = EntitlementSection })

drawWorkspace :: AppContext -> Widget Name
drawWorkspace context =
  vBox
    [ borderWithLabel (str "Entitlement Transfers & Envelopes (entitlement.journal)")
        (vLimit 18
          (viewport EntitlementViewport Vertical
            (vBox
              [ strWrap "--- Stock Origins ---"
              , vBox (map renderStockOriginItem (Map.elems (envelopeEntitlementHistoryOrigins (householdStateEntitlementHistory state))))
              , str " "
              , strWrap "--- Entitlement Transfers ---"
              , vBox (map renderTransfer (envelopeEntitlementHistoryTransfers (householdStateEntitlementHistory state)))
              , str " "
              , strWrap "--- Spendable Envelopes ---"
              , vBox (map renderEnvelopeDef
                  (currentEnvelopePolicyDefinitions (householdStateEnvelopePolicy state)))
              ])))
    , strWrap "[Enter/M] New transfer   [wheel] Scroll"
    ]
  where
    state = contextHouseholdState context

renderStockOriginItem :: StockOrigin -> Widget Name
renderStockOriginItem = txtWrap . renderStockOrigin

renderTransfer :: EnvelopeEntitlementTransfer -> Widget Name
renderTransfer = txtWrap . renderEntitlementTransfer

renderEnvelopeDef :: EnvelopeDefinition -> Widget Name
renderEnvelopeDef definition =
  txtWrap ("Envelope: " <> envelopeIdText (envelopeDefinitionId definition))

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name s WorkspaceAction
handleWorkspaceEvent event =
  case Scroll.viewportWheelHandler EntitlementViewport Scroll.VerticalOnly event of
    Just scroll -> scroll >> pure WorkspaceMaintain
    Nothing -> case event of
      VtyEvent (V.EvKey V.KEnter []) -> pure WorkspaceStartTransfer
      VtyEvent (V.EvKey (V.KChar 'm') []) -> pure WorkspaceStartTransfer
      VtyEvent (V.EvKey (V.KChar 'M') []) -> pure WorkspaceStartTransfer
      _ -> pure WorkspaceMaintain

showText :: Show value => value -> Text
showText = T.pack . show
