{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Maintenance.Budget
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
import Data.Text (Text)
import qualified Data.Text as T

import HKernel.Account (accountName, mkAccount)
import HKernel.Application.Config (HouseholdSourcePaths(..))
import HKernel.Envelope.Policy
  ( EnvelopeDefinition
  , currentEnvelopePolicyDefinitions
  , envelopeDefinitionId
  )
import HKernel.Editor.BudgetMovementAppend
  ( BudgetJournalMovementAppendPreview(..)
  , prepareCurrentBudgetJournalMovementAppend
  )
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteIntent(..)
  , publishWithPathAdmission
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , contextBudgetSource
  , contextHouseholdState
  , reloadWorkspaceContext
  )
import HKernel.Household.Application
  ( HouseholdState(..)
  , householdStateBudgetMovements
  , loadCanonicalHousehold
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Money
  ( amountCommodity
  , amountQuantity
  , commodityCode
  , mkAmount
  , mkCommodity
  , parseQuantity
  , renderQuantity
  )

data PreviewResult preview
  = PreviewRejected Text
  | PreviewReady preview

data BudgetInput = BudgetInput
  { budgetMemoText      :: Text
  , budgetFromText      :: Text
  , budgetToText        :: Text
  , budgetAmountText    :: Text
  , budgetCommodityText :: Text
  } deriving (Eq, Show)

data State event
  = Input (Form BudgetInput event Name)
  | Preview (PreviewResult BudgetJournalMovementAppendPreview) (Form BudgetInput event Name)

data FlowAction
  = FlowMaintain
  | FlowReturn
  | FlowQuit
  | FlowPublish BudgetJournalMovementAppendPreview

data WorkspaceAction
  = WorkspaceMaintain
  | WorkspaceStartMovement
  deriving (Eq, Show)

data PublishResult
  = Published AppContext
  | PublicationFailed Text
  | ReloadFailed

budgetMemoL :: Lens' BudgetInput Text
budgetMemoL f input = (\value -> input { budgetMemoText = value }) <$> f (budgetMemoText input)

budgetFromL :: Lens' BudgetInput Text
budgetFromL f input = (\value -> input { budgetFromText = value }) <$> f (budgetFromText input)

budgetToL :: Lens' BudgetInput Text
budgetToL f input = (\value -> input { budgetToText = value }) <$> f (budgetToText input)

budgetAmountL :: Lens' BudgetInput Text
budgetAmountL f input = (\value -> input { budgetAmountText = value }) <$> f (budgetAmountText input)

budgetCommodityL :: Lens' BudgetInput Text
budgetCommodityL f input = (\value -> input { budgetCommodityText = value }) <$> f (budgetCommodityText input)

labelField :: String -> Widget Name -> Widget Name
labelField labelText widget =
  padBottom (Pad 1) ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)

mkForm :: Form BudgetInput event Name
mkForm =
  newForm
    [ labelField "Memo:" @@= editTextField budgetMemoL BudgetMemoField (Just 1)
    , labelField "From Budget:" @@= editTextField budgetFromL BudgetFromField (Just 1)
    , labelField "To Budget:" @@= editTextField budgetToL BudgetToField (Just 1)
    , labelField "Amount:" @@= editTextField budgetAmountL BudgetAmountField (Just 1)
    , labelField "Commodity:" @@= editTextField budgetCommodityL BudgetCommodityField (Just 1)
    ]
    (BudgetInput "alloc" "" "" "" "JPY")

start :: State event
start = Input mkForm

zoomForm :: Traversal' (State AppEvent) (Form BudgetInput AppEvent Name)
zoomForm f (Input form) = Input <$> f form
zoomForm _ state = pure state

drawFlow :: State AppEvent -> Widget Name
drawFlow state = case state of
  Input form ->
    inputBox "New Budget Movement" form
      [ "Both Accounts must be canonical Budget Accounts."
      , "[Tab] Next field   [Enter] Preview   [Esc] Budget"
      ]
  Preview result _ ->
    previewBox "Budget Movement Preview"
      (renderPreviewResult (txt . budgetJournalCandidateBlock) result)
      (previewControls result)

inputBox :: String -> Form input AppEvent Name -> [String] -> Widget Name
inputBox title form helpLines =
  center
    (borderWithLabel (str title)
      (hLimit 82
        (padAll 1
          (renderForm form <=> str " " <=> vBox (map str helpLines)))))

previewBox :: String -> Widget Name -> String -> Widget Name
previewBox title body controls =
  center
    (borderWithLabel (str title)
      (hLimit 88
        (vLimit 32
          (padAll 1
            (body <=> str " " <=> str controls)))))

renderPreviewResult
  :: (preview -> Widget Name)
  -> PreviewResult preview
  -> Widget Name
renderPreviewResult renderPreview result = case result of
  PreviewRejected message -> withAttr (attrName "error") (txt message)
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
        case prepareBudget context (formState form) of
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

prepareBudget :: AppContext -> BudgetInput -> Either Text BudgetJournalMovementAppendPreview
prepareBudget context input = do
  fromAccount <- either (Left . showText) Right (mkAccount (T.strip (budgetFromText input)))
  toAccount <- either (Left . showText) Right (mkAccount (T.strip (budgetToText input)))
  quantity <- either (Left . showText) Right (parseQuantity (T.strip (budgetAmountText input)))
  commodity <- either (Left . showText) Right (mkCommodity (T.strip (budgetCommodityText input)))
  let movement = HouseholdBudgetMovement
        { householdBudgetMovementDate = contextEntryDay context
        , householdBudgetMovementMemo = T.strip (budgetMemoText input)
        , householdBudgetMovementFrom = fromAccount
        , householdBudgetMovementTo = toAccount
        , householdBudgetMovementAmount = mkAmount commodity quantity
        }
      state = contextHouseholdState context
      registry = householdStateAccountsRegistry state
      policy = householdStatePolicy state
  case prepareCurrentBudgetJournalMovementAppend registry policy (contextBudgetSource context) movement of
    Left errors -> Left ("Budget movement rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview

publishCandidate :: AppContext -> BudgetJournalMovementAppendPreview -> IO PublishResult
publishCandidate context preview = do
  let state = contextHouseholdState context
      paths = householdStatePaths state
      root = householdStateRoot state
  result <- publishWithPathAdmission
    (\_ -> loadCanonicalHousehold root)
    WriteIntent
      { targetFilePath = householdBudgetJournalPath paths
      , expectedOldBytes = ExpectedSource (contextBudgetSource context)
      , candidateNewBytes = CandidateSource (budgetJournalCandidateCompleteSource preview)
      }
  case result of
    Left err -> pure (PublicationFailed (T.pack (show err)))
    Right () -> do
      reloaded <- reloadWorkspaceContext (context { contextCurrentSection = BudgetSection })
      pure $ case reloaded of
        Nothing -> ReloadFailed
        Just fresh -> Published (fresh { contextCurrentSection = BudgetSection })

drawWorkspace :: AppContext -> Widget Name
drawWorkspace context =
  vBox
    [ borderWithLabel (str "Budget Movements & Envelopes (budget.journal)")
        (vLimit 18
          (viewport BudgetViewport Vertical
            (vBox
              [ str "--- Budget Movements ---"
              , vBox (map renderBudgetMovement (householdStateBudgetMovements state))
              , str " "
              , str "--- Spendable Envelopes ---"
              , vBox (map renderEnvelopeDef
                  (currentEnvelopePolicyDefinitions (householdStateEnvelopePolicy state)))
              ])))
    , str "[Enter/M] New movement   [1-7] Sections   [q] Quit"
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
  txt ("Envelope: " <> T.pack (show (envelopeDefinitionId definition)))

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name s WorkspaceAction
handleWorkspaceEvent event = case event of
  MouseDown BudgetViewport V.BScrollUp _ _ -> do
    vScrollBy (viewportScroll BudgetViewport) (-3)
    pure WorkspaceMaintain
  MouseDown BudgetViewport V.BScrollDown _ _ -> do
    vScrollBy (viewportScroll BudgetViewport) 3
    pure WorkspaceMaintain
  VtyEvent (V.EvKey V.KEnter []) -> pure WorkspaceStartMovement
  VtyEvent (V.EvKey (V.KChar 'm') []) -> pure WorkspaceStartMovement
  VtyEvent (V.EvKey (V.KChar 'M') []) -> pure WorkspaceStartMovement
  _ -> pure WorkspaceMaintain

showText :: Show value => value -> Text
showText = T.pack . show
