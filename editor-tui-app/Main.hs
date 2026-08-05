{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Main (main) where

import Brick
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Graphics.Vty.CrossPlatform (mkVty)
import Lens.Micro (Lens', Traversal')
import Lens.Micro.Mtl ()

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Vector as Vec
import System.Environment (getArgs)
import System.Exit (die)

import HKernel.Account
  ( accountDeclarations
  , accountName
  , declaredAccount
  )
import HKernel.Actual.Journal
  ( actualJournalValue
  , parseActualJournal
  )
import HKernel.Editor.TUI.ActualAdd
  ( AccountSelectionTarget(..)
  , ActualAddAction(..)
  , ActualAddInput(..)
  , ActualAddMode(..)
  , ActualAddPreview(..)
  , ActualAddState(..)
  , emptyActualAddInput
  , transitionActualAdd
  )
import HKernel.Journal (journalAccountRegistry)


data Name
  = DateField
  | DescriptionField
  | FromAccountField
  | ToAccountField
  | AmountField
  | AccountList
  deriving (Eq, Ord, Show)

addDateTextL :: Lens' ActualAddInput Text
addDateTextL f input =
  (\value -> input { addDateText = value }) <$> f (addDateText input)

addDescriptionTextL :: Lens' ActualAddInput Text
addDescriptionTextL f input =
  (\value -> input { addDescriptionText = value })
    <$> f (addDescriptionText input)

addFromAccountTextL :: Lens' ActualAddInput Text
addFromAccountTextL f input =
  (\value -> input { addFromAccountText = value })
    <$> f (addFromAccountText input)

addToAccountTextL :: Lens' ActualAddInput Text
addToAccountTextL f input =
  (\value -> input { addToAccountText = value })
    <$> f (addToAccountText input)

addAmountTextL :: Lens' ActualAddInput Text
addAmountTextL f input =
  (\value -> input { addAmountText = value }) <$> f (addAmountText input)

data UIState event
  = InputForm (Form ActualAddInput event Name)
  | SelectAccount
      AccountSelectionTarget
      (L.List Name Text)
      (Form ActualAddInput event Name)
  | ShowPreview
      ActualAddPreview
      (Form ActualAddInput event Name)

data AppContext = AppContext
  { contextAccounts :: [Text]
  , contextSource   :: Text
  }

data AppWrapper = AppWrapper AppContext (UIState AppEvent)

type AppEvent = ()

mkForm :: ActualAddInput -> Form ActualAddInput event Name
mkForm =
  let label labelText widget =
        padBottom (Pad 1)
          ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)
  in newForm
      [ label "Date (YYYY-MM-DD):"
          @@= editTextField addDateTextL DateField (Just 1)
      , label "Description:"
          @@= editTextField addDescriptionTextL DescriptionField (Just 1)
      , label "From Account:"
          @@= editTextField addFromAccountTextL FromAccountField (Just 1)
      , label "To Account:"
          @@= editTextField addToAccountTextL ToAccountField (Just 1)
      , label "Positive Amount:"
          @@= editTextField addAmountTextL AmountField (Just 1)
      ]

zoomForm :: Traversal' AppWrapper (Form ActualAddInput AppEvent Name)
zoomForm f (AppWrapper context (InputForm form)) =
  (\updated -> AppWrapper context (InputForm updated)) <$> f form
zoomForm _ wrapper = pure wrapper

zoomList :: Traversal' AppWrapper (L.List Name Text)
zoomList f (AppWrapper context (SelectAccount target accountList form)) =
  (\updated -> AppWrapper context (SelectAccount target updated form))
    <$> f accountList
zoomList _ wrapper = pure wrapper

drawUI :: AppWrapper -> [Widget Name]
drawUI (AppWrapper _ (InputForm form)) =
  [ center
      (borderWithLabel (str "Actual Add Preview")
        (padAll 1
          (vBox
            [ renderForm form
            , str " "
            , str "[Esc] Quit | [Enter] Preview | [Ctrl-F] From | [Ctrl-T] To"
            ])))
  ]
drawUI (AppWrapper _ (SelectAccount target accountList _)) =
  [ center
      (borderWithLabel (str (selectionLabel target))
        (hLimit 48
          (vLimit 15
            (L.renderList renderAccount True accountList
              <=> str " "
              <=> str "[Enter] Select | [Esc] Cancel"))))
  ]
drawUI (AppWrapper _ (ShowPreview preview _)) =
  [ center
      (borderWithLabel (str "Preview")
        (padAll 1
          (renderPreview preview
            <=> str " "
            <=> str "[Esc/B] Back | [Q] Quit")))
  ]

selectionLabel :: AccountSelectionTarget -> String
selectionLabel SelectFromAccount = "Select From Account"
selectionLabel SelectToAccount = "Select To Account"

renderAccount :: Bool -> Text -> Widget Name
renderAccount selected accountText
  | selected = withAttr L.listSelectedAttr (txt accountText)
  | otherwise = txt accountText

renderPreview :: ActualAddPreview -> Widget Name
renderPreview preview = case preview of
  ActualAddInputRejected inputError ->
    withAttr (attrName "error")
      (txt ("Input rejected: " <> T.pack (show inputError)))
  ActualAddCandidateRejected sourceErrors ->
    withAttr (attrName "error")
      (txt
        (T.intercalate "\n"
          (map (T.pack . show) (NonEmpty.toList sourceErrors))))
  ActualAddCandidateReady block ->
    withAttr (attrName "success")
      (str "Validation successful. Source unmodified.")
      <=> str " "
      <=> txt block

appEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
appEvent event = do
  AppWrapper context state <- get
  case state of
    InputForm form -> handleInputEvent context form event
    SelectAccount target accountList form ->
      handleAccountSelection context target accountList form event
    ShowPreview _ form -> handlePreviewEvent context form event

handleInputEvent
  :: AppContext
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleInputEvent context form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey V.KEnter []) -> do
    let pureState =
          transitionActualAdd
            (contextSource context)
            RequestActualAddPreview
            (ActualAddState (formState form) EditingActualAdd)
    case actualAddMode pureState of
      ShowingActualAddPreview preview ->
        put (AppWrapper context (ShowPreview preview form))
      _ -> put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey (V.KFun 2) []) ->
    openAccountSelection context SelectFromAccount form
  VtyEvent (V.EvKey (V.KChar 'f') [V.MCtrl]) ->
    openAccountSelection context SelectFromAccount form
  VtyEvent (V.EvKey (V.KFun 3) []) ->
    openAccountSelection context SelectToAccount form
  VtyEvent (V.EvKey (V.KChar 't') [V.MCtrl]) ->
    openAccountSelection context SelectToAccount form
  _ -> zoom zoomForm (handleFormEvent event)

openAccountSelection
  :: AppContext
  -> AccountSelectionTarget
  -> Form ActualAddInput AppEvent Name
  -> EventM Name AppWrapper ()
openAccountSelection context target form =
  put
    (AppWrapper context
      (SelectAccount
        target
        (L.list AccountList (Vec.fromList (contextAccounts context)) 1)
        form))

handleAccountSelection
  :: AppContext
  -> AccountSelectionTarget
  -> L.List Name Text
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleAccountSelection context target accountList form event = case event of
  VtyEvent (V.EvKey V.KEsc []) ->
    put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey V.KEnter []) ->
    case L.listSelectedElement accountList of
      Nothing -> put (AppWrapper context (InputForm form))
      Just (_, accountText) -> do
        let state =
              transitionActualAdd
                (contextSource context)
                (ChooseAccount accountText)
                (ActualAddState
                  (formState form)
                  (SelectingActualAccount target))
        put
          (AppWrapper context
            (InputForm (updateFormState (actualAddInput state) form)))
  VtyEvent vtyEvent ->
    zoom zoomList (L.handleListEventVi L.handleListEvent vtyEvent)
  _ -> pure ()

handlePreviewEvent
  :: AppContext
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handlePreviewEvent context form event = case event of
  VtyEvent (V.EvKey V.KEsc []) ->
    put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey (V.KChar 'b') []) ->
    put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey (V.KChar 'B') []) ->
    put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()

app :: App AppWrapper AppEvent Name
app = App
  { appDraw = drawUI
  , appChooseCursor = showFirstCursor
  , appHandleEvent = appEvent
  , appStartEvent = pure ()
  , appAttrMap = const
      (attrMap V.defAttr
        [ (L.listSelectedAttr, V.black `on` V.white)
        , (attrName "error", fg V.red)
        , (attrName "success", fg V.green)
        ])
  }

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [journalFile] -> do
      source <- TIO.readFile journalFile
      journal <- case parseActualJournal source of
        Left sourceErrors ->
          die
            ("Failed to parse journal:\n"
              <> unlines (map show (NonEmpty.toList sourceErrors)))
        Right admittedJournal -> pure admittedJournal
      let declarations =
            accountDeclarations
              (journalAccountRegistry (actualJournalValue journal))
          accounts = map (accountName . declaredAccount) declarations
          context = AppContext accounts source
          initialState =
            AppWrapper context (InputForm (mkForm emptyActualAddInput))
          buildVty = mkVty V.defaultConfig
      initialVty <- buildVty
      _ <- customMain initialVty buildVty Nothing app initialState
      pure ()
    _ -> die "Usage: h-kernel-editor-tui <actual.journal>"
