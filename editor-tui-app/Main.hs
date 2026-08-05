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
import HKernel.Editor.ActualWriter (publishActualBlock)
import HKernel.Editor.TUI.ActualAdd
  ( AccountSelectionTarget(..)
  , ActualAddAction(..)
  , ActualAddInput(..)
  , ActualAddMode(..)
  , ActualAddPreview(..)
  , ActualAddState(..)
  , ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , classifyActualAddWriteResult
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
  | ShowConfirmation
      Text
      (Form ActualAddInput event Name)
  | ShowWriteOutcome
      ActualAddWriteOutcome
      (Form ActualAddInput event Name)

data AppContext = AppContext
  { contextAccounts   :: [Text]
  , contextSourcePath :: FilePath
  , contextSource     :: Text
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
            <=> str (previewControls preview))))
  ]
drawUI (AppWrapper _ (ShowConfirmation block _)) =
  [ center
      (borderWithLabel (str "Confirm Actual Add")
        (padAll 1
          (str "Confirm this validated transaction?"
            <=> str "No source write has occurred."
            <=> str " "
            <=> withAttr (attrName "success") (txt block)
            <=> str " "
            <=> str "[Y] Confirm | [N/Esc] Cancel | [Q] Quit")))
  ]
drawUI (AppWrapper _ (ShowWriteOutcome outcome _)) =
  [ center
      (borderWithLabel (str "Actual Add Result")
        (padAll 1
          (renderWriteOutcome outcome
            <=> str " "
            <=> str "[Esc/Q] Quit")))
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

previewControls :: ActualAddPreview -> String
previewControls preview = case preview of
  ActualAddCandidateReady _ ->
    "[Esc/B] Back | [C] Continue to confirmation | [Q] Quit"
  _ -> "[Esc/B] Back | [Q] Quit"

renderWriteOutcome :: ActualAddWriteOutcome -> Widget Name
renderWriteOutcome outcome = case outcome of
  ActualAddWriteSucceeded ->
    withAttr (attrName "success")
      (str "Published and post-admitted successfully.")
  ActualAddWriteStale ->
    withAttr (attrName "error")
      (vBox
        [ str "Source changed after preview. Nothing was written."
        , str "Restart the TUI and preview the current source before retrying."
        ])
  ActualAddWriteRecovered failure ->
    withAttr (attrName "warning")
      (vBox
        [ str "Publication failed, and the backup was restored."
        , txt (writeFailureText failure)
        ])
  ActualAddWriteFailed (ActualAddFileIOFailure message) ->
    withAttr (attrName "error")
      (vBox
        [ str "The writer could not complete because of a filesystem error."
        , txt (writeFailureText (ActualAddFileIOFailure message))
        , str "Verify the rehearsal source before continuing."
        ])
  ActualAddWriteFailed failure ->
    withAttr (attrName "error")
      (vBox
        [ str "Publication failed and automatic recovery did not complete."
        , txt (writeFailureText failure)
        , str "Verify the rehearsal source before continuing."
        ])

writeFailureText :: ActualAddWriteFailure -> Text
writeFailureText failure = case failure of
  ActualAddPostAdmissionFailure ->
    "The published candidate failed complete-source admission."
  ActualAddPostPublishReadFailure ->
    "The published source could not be read for post-admission."
  ActualAddFileIOFailure message ->
    "Filesystem error: " <> T.pack message

appEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
appEvent event = do
  AppWrapper context state <- get
  case state of
    InputForm form -> handleInputEvent context form event
    SelectAccount target accountList form ->
      handleAccountSelection context target accountList form event
    ShowPreview preview form ->
      handlePreviewEvent context preview form event
    ShowConfirmation block form ->
      handleConfirmationEvent context block form event
    ShowWriteOutcome outcome form ->
      handleWriteOutcomeEvent outcome form event

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
  -> ActualAddPreview
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handlePreviewEvent context preview form event = case event of
  VtyEvent (V.EvKey V.KEsc []) ->
    put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey (V.KChar 'b') []) ->
    put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey (V.KChar 'B') []) ->
    put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey (V.KChar 'c') []) ->
    requestConfirmation context preview form
  VtyEvent (V.EvKey (V.KChar 'C') []) ->
    requestConfirmation context preview form
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()

requestConfirmation
  :: AppContext
  -> ActualAddPreview
  -> Form ActualAddInput AppEvent Name
  -> EventM Name AppWrapper ()
requestConfirmation context preview form = do
  let state =
        transitionActualAdd
          (contextSource context)
          RequestActualAddConfirmation
          (ActualAddState
            (formState form)
            (ShowingActualAddPreview preview))
  case actualAddMode state of
    ConfirmingActualAdd block ->
      put (AppWrapper context (ShowConfirmation block form))
    _ -> put (AppWrapper context (ShowPreview preview form))

handleConfirmationEvent
  :: AppContext
  -> Text
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleConfirmationEvent context block form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> cancelConfirmation context block form
  VtyEvent (V.EvKey (V.KChar 'n') []) -> cancelConfirmation context block form
  VtyEvent (V.EvKey (V.KChar 'N') []) -> cancelConfirmation context block form
  VtyEvent (V.EvKey (V.KChar 'y') []) -> acceptConfirmation context block form
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> acceptConfirmation context block form
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()

cancelConfirmation
  :: AppContext
  -> Text
  -> Form ActualAddInput AppEvent Name
  -> EventM Name AppWrapper ()
cancelConfirmation context block form = do
  let state =
        transitionActualAdd
          (contextSource context)
          CancelActualAddConfirmation
          (ActualAddState (formState form) (ConfirmingActualAdd block))
  case actualAddMode state of
    ShowingActualAddPreview preview ->
      put (AppWrapper context (ShowPreview preview form))
    _ -> put (AppWrapper context (ShowConfirmation block form))

acceptConfirmation
  :: AppContext
  -> Text
  -> Form ActualAddInput AppEvent Name
  -> EventM Name AppWrapper ()
acceptConfirmation context block form = do
  let state =
        transitionActualAdd
          (contextSource context)
          ConfirmActualAdd
          (ActualAddState (formState form) (ConfirmingActualAdd block))
  case actualAddMode state of
    ActualAddConfirmed confirmedBlock -> do
      writeResult <-
        suspendAndResume'
          (publishActualBlock
            (contextSourcePath context)
            (contextSource context)
            confirmedBlock)
      put
        (AppWrapper context
          (ShowWriteOutcome
            (classifyActualAddWriteResult writeResult)
            form))
    _ -> put (AppWrapper context (ShowConfirmation block form))

handleWriteOutcomeEvent
  :: ActualAddWriteOutcome
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleWriteOutcomeEvent _ _ event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> halt
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
        , (attrName "warning", fg V.yellow)
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
          context = AppContext accounts journalFile source
          initialState =
            AppWrapper context (InputForm (mkForm emptyActualAddInput))
          buildVty = mkVty V.defaultConfig
      initialVty <- buildVty
      _ <- customMain initialVty buildVty Nothing app initialState
      pure ()
    _ -> die "Usage: h-kernel-editor-tui <actual.journal>"
