{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Maintenance.Accounts
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

import HKernel.Account
  ( AccountDeclaration
  , AccountType(..)
  , accountDeclarations
  , accountName
  , declareAccount
  , declareAccountWithDefaultCommodity
  , declaredAccount
  , declaredAccountDefaultCommodity
  , declaredAccountType
  , mkAccount
  )
import HKernel.Application.Config (HouseholdSourcePaths(..))
import HKernel.Editor.AccountAppend
  ( AccountJournalAppendPreview(..)
  , prepareAccountJournalAppend
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
  , contextAccountsSource
  , contextHouseholdState
  , reloadWorkspaceContext
  )
import HKernel.Household.Application
  ( HouseholdState(..)
  , loadCanonicalHousehold
  )
import HKernel.Money (commodityCode, mkCommodity)

data PreviewResult preview
  = PreviewRejected Text
  | PreviewReady preview

data AccountInput = AccountInput
  { accountNameText      :: Text
  , accountTypeText      :: Text
  , accountCommodityText :: Text
  } deriving (Eq, Show)

data State event
  = Input (Form AccountInput event Name)
  | Preview (PreviewResult (Text, AccountJournalAppendPreview)) (Form AccountInput event Name)

data FlowAction
  = FlowMaintain
  | FlowReturn
  | FlowQuit
  | FlowPublish Text AccountJournalAppendPreview

data WorkspaceAction
  = WorkspaceMaintain
  | WorkspaceStartAdd
  deriving (Eq, Show)

data PublishResult
  = Published AppContext
  | PublicationFailed Text
  | ReloadFailed

accountNameL :: Lens' AccountInput Text
accountNameL f input = (\value -> input { accountNameText = value }) <$> f (accountNameText input)

accountTypeL :: Lens' AccountInput Text
accountTypeL f input = (\value -> input { accountTypeText = value }) <$> f (accountTypeText input)

accountCommodityL :: Lens' AccountInput Text
accountCommodityL f input = (\value -> input { accountCommodityText = value }) <$> f (accountCommodityText input)

labelField :: String -> Widget Name -> Widget Name
labelField labelText widget =
  padBottom (Pad 1) ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)

mkForm :: Form AccountInput event Name
mkForm =
  newForm
    [ labelField "Account:" @@= editTextField accountNameL AccountNameField (Just 1)
    , labelField "Type:" @@= editTextField accountTypeL AccountTypeField (Just 1)
    , labelField "Commodity:" @@= editTextField accountCommodityL AccountCommodityField (Just 1)
    ]
    (AccountInput "" "expense" "JPY")

start :: State event
start = Input mkForm

zoomForm :: Traversal' (State AppEvent) (Form AccountInput AppEvent Name)
zoomForm f (Input form) = Input <$> f form
zoomForm _ state = pure state

drawFlow :: State AppEvent -> Widget Name
drawFlow state = case state of
  Input form ->
    inputBox "Add Account" form
      [ "Type: asset | liability | equity | income | expense | budget"
      , "Commodity may be blank when no default is required."
      , "[Tab] Next field   [Enter] Preview   [Esc] Accounts"
      ]
  Preview result _ ->
    previewBox "Account Preview"
      (renderPreviewResult (txtWrap . accountCandidateBlock . snd) result)
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
        case prepareAccountDeclaration (formState form) of
          Left message -> put (Preview (PreviewRejected message) form)
          Right declaration ->
            let source = contextAccountsSource context
            in case prepareAccountJournalAppend source declaration of
              Left errors -> put (Preview
                (PreviewRejected ("Account rejected: " <> T.pack (show (NonEmpty.toList errors)))) form)
              Right preview -> put (Preview (PreviewReady (source, preview)) form)
        pure FlowMaintain
      _ -> do
        zoom zoomForm (handleFormEvent event)
        pure FlowMaintain
    Preview result form -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put (Input form) >> pure FlowMaintain
      VtyEvent (V.EvKey V.KEnter []) -> case result of
        PreviewRejected _ -> pure FlowMaintain
        PreviewReady (source, preview) -> pure (FlowPublish source preview)
      VtyEvent (V.EvKey (V.KChar 'q') []) -> pure FlowQuit
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure FlowQuit
      _ -> pure FlowMaintain

prepareAccountDeclaration :: AccountInput -> Either Text AccountDeclaration
prepareAccountDeclaration input = do
  account <- either (Left . showText) Right (mkAccount (T.strip (accountNameText input)))
  accountType <- parseAccountType (T.strip (accountTypeText input))
  let commodityText = T.strip (accountCommodityText input)
  if T.null commodityText
    then Right (declareAccount account accountType)
    else do
      commodity <- either (Left . showText) Right (mkCommodity commodityText)
      Right (declareAccountWithDefaultCommodity account accountType commodity)

parseAccountType :: Text -> Either Text AccountType
parseAccountType value = case T.toCaseFold value of
  "asset" -> Right Asset
  "liability" -> Right Liability
  "equity" -> Right Equity
  "income" -> Right Income
  "expense" -> Right Expense
  _ -> Left "Unknown Account type."

publishCandidate :: AppContext -> Text -> AccountJournalAppendPreview -> IO PublishResult
publishCandidate context source preview = do
  let state = contextHouseholdState context
      paths = householdStatePaths state
      root = householdStateRoot state
  result <- publishWithPathAdmission
    (\_ -> loadCanonicalHousehold root)
    WriteIntent
      { targetFilePath = householdAccountsJournalPath paths
      , expectedOldBytes = ExpectedSource source
      , candidateNewBytes = CandidateSource (accountCandidateCompleteSource preview)
      }
  case result of
    Left err -> pure (PublicationFailed (T.pack (show err)))
    Right () -> do
      reloaded <- reloadWorkspaceContext (context { contextCurrentSection = AccountsSection })
      pure $ case reloaded of
        Nothing -> ReloadFailed
        Just fresh -> Published (fresh { contextCurrentSection = AccountsSection })

drawWorkspace :: AppContext -> Widget Name
drawWorkspace context =
  vBox
    [ borderWithLabel (str "Canonical Account Declarations (accounts.journal)")
        (vLimit 18
          (viewport AccountsViewport Vertical
            (vBox (map renderAccountDecl
              (accountDeclarations
                (householdStateAccountsRegistry (contextHouseholdState context)))))))
    , strWrap "[Enter/A] Add Account   [1-7] Sections   [q] Quit"
    ]

renderAccountDecl :: AccountDeclaration -> Widget Name
renderAccountDecl declaration =
  txtWrap (accountName (declaredAccount declaration) <> "  type: "
    <> T.pack (show (declaredAccountType declaration))
    <> maybe "" (\commodity -> "  default commodity: " <> commodityCode commodity)
      (declaredAccountDefaultCommodity declaration))

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name s WorkspaceAction
handleWorkspaceEvent event = case event of
  MouseDown AccountsViewport V.BScrollUp _ _ -> do
    vScrollBy (viewportScroll AccountsViewport) (-3)
    pure WorkspaceMaintain
  MouseDown AccountsViewport V.BScrollDown _ _ -> do
    vScrollBy (viewportScroll AccountsViewport) 3
    pure WorkspaceMaintain
  VtyEvent (V.EvKey V.KEnter []) -> pure WorkspaceStartAdd
  VtyEvent (V.EvKey (V.KChar 'a') []) -> pure WorkspaceStartAdd
  VtyEvent (V.EvKey (V.KChar 'A') []) -> pure WorkspaceStartAdd
  _ -> pure WorkspaceMaintain

showText :: Show value => value -> Text
showText = T.pack . show
