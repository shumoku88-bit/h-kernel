{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Main (main) where

import Control.Monad.IO.Class (liftIO)

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
import Data.Time.Format (defaultTimeLocale, formatTime)
import qualified Data.Vector as Vec
import System.Environment (getArgs)
import System.Exit (die)

import HKernel.Actual.Journal (ActualJournal)
import HKernel.Editor.ActualIdentity
  ( ActualIdentityGenerationFailure(..)
  , actualIdentityGenerationFailureText
  , generateActualTransactionId
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
import HKernel.Editor.TUI.ActualBrowse
  ( ActualBrowseAction(..)
  , ActualBrowseRow(..)
  , ActualBrowseState(..)
  , ActualIdentityStatus(..)
  , browseRows
  , browseSelectedIndex
  , initialActualBrowseStateFromSnapshot
  , transitionActualBrowse
  )
import HKernel.Editor.TUI.ActualSourceSnapshot
  ( ActualSourceLoadFailure(..)
  , ActualSourceOperation(..)
  , ActualSourceSnapshot
  , actualSnapshotAccountNames
  , actualSnapshotJournal
  , actualSnapshotSource
  , actualSourceStartupFailureText
  , loadActualSourceSnapshot
  )
import HKernel.Editor.TUI.OperationHub
  ( DailyOperation(..)
  , OperationAvailability(..)
  , OperationHubAction(..)
  , OperationHubState(..)
  , allDailyOperations
  , disabledReasonText
  , initialOperationHubState
  , operationAvailability
  , operationTitle
  , transitionOperationHub
  )
import HKernel.Ledger
  ( transactionDate
  , transactionDescription
  , transactionPostings
  )
import HKernel.Plan (planIdText)
import HKernel.Plan.Completion (ActualTransactionId, actualTransactionIdText)


data Name
  = DateField
  | DescriptionField
  | FromAccountField
  | ToAccountField
  | AmountField
  | AccountList
  | HubOperationList
  | BrowseRowList
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
  = ShowOperationHub
      OperationHubState
      (L.List Name DailyOperation)
  | ShowActualBrowse
      ActualBrowseState
      (L.List Name ActualBrowseRow)
  | ShowActualSourceLoadFailure
      ActualSourceOperation
      ActualSourceLoadFailure
  | ShowActualIdentityGenerationFailure
      ActualIdentityGenerationFailure
  | InputForm
      ActualTransactionId
      (Form ActualAddInput event Name)
  | SelectAccount
      ActualTransactionId
      AccountSelectionTarget
      (L.List Name Text)
      (Form ActualAddInput event Name)
  | ShowPreview
      ActualTransactionId
      ActualAddPreview
      (Form ActualAddInput event Name)
  | ShowConfirmation
      ActualTransactionId
      Text
      (Form ActualAddInput event Name)
  | ShowWriteOutcome
      ActualTransactionId
      ActualAddWriteOutcome
      (Form ActualAddInput event Name)

data AppContext = AppContext
  { contextSourcePath     :: FilePath
  , contextActualSnapshot :: ActualSourceSnapshot
  }

contextAccounts :: AppContext -> [Text]
contextAccounts = actualSnapshotAccountNames . contextActualSnapshot

contextSource :: AppContext -> Text
contextSource = actualSnapshotSource . contextActualSnapshot

contextJournal :: AppContext -> ActualJournal
contextJournal = actualSnapshotJournal . contextActualSnapshot

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
zoomForm f (AppWrapper context (InputForm actualId form)) =
  (\updated -> AppWrapper context (InputForm actualId updated)) <$> f form
zoomForm _ wrapper = pure wrapper

zoomList :: Traversal' AppWrapper (L.List Name Text)
zoomList f (AppWrapper context (SelectAccount actualId target accountList form)) =
  (\updated -> AppWrapper context (SelectAccount actualId target updated form))
    <$> f accountList
zoomList _ wrapper = pure wrapper

zoomHubList :: Traversal' AppWrapper (L.List Name DailyOperation)
zoomHubList f (AppWrapper context (ShowOperationHub hubState hubList)) =
  (\updated -> AppWrapper context (ShowOperationHub hubState updated))
    <$> f hubList
zoomHubList _ wrapper = pure wrapper

zoomBrowseList :: Traversal' AppWrapper (L.List Name ActualBrowseRow)
zoomBrowseList f (AppWrapper context (ShowActualBrowse browseState browseList)) =
  (\updated -> AppWrapper context (ShowActualBrowse browseState updated))
    <$> f browseList
zoomBrowseList _ wrapper = pure wrapper

drawUI :: AppWrapper -> [Widget Name]
drawUI (AppWrapper _ (ShowOperationHub _ hubList)) =
  [ center
      (borderWithLabel (str "h-kernel Daily Operations")
        (hLimit 64
          (vLimit 18
            (L.renderList renderOperation True hubList
              <=> str " "
              <=> str "[Enter] Select | [Up/Down] Navigate | [Esc/Q] Quit"))))
  ]
drawUI (AppWrapper _ (ShowActualBrowse _ browseList)) =
  [ center
      (borderWithLabel (str "Actual Transactions (Read-Only)")
        (hLimit 82
          (vLimit 20
            (L.renderList renderBrowseRow True browseList
              <=> str " "
              <=> str "[Esc/Q] Back to Hub | [Up/Down] Navigate | [Enter] Select"))))
  ]
drawUI (AppWrapper _ (ShowActualSourceLoadFailure op failure)) =
  [ center
      (borderWithLabel (str (loadFailureTitle op))
        (padAll 1
          (renderSourceLoadFailure op failure
            <=> str " "
            <=> str "[Esc/Q] Back to Hub")))
  ]
drawUI (AppWrapper _ (ShowActualIdentityGenerationFailure failure)) =
  [ center
      (borderWithLabel (str "Actual Identity Generation Failure")
        (padAll 1
          (withAttr (attrName "error") (txt (actualIdentityGenerationFailureText failure))
            <=> str " "
            <=> str "A durable Actual identity could not be generated."
            <=> str "Return to the operation hub and retry."
            <=> str " "
            <=> str "[Esc/Q] Back to Hub")))
  ]
drawUI (AppWrapper _ (InputForm _ form)) =
  [ center
      (borderWithLabel (str "Actual Add Preview")
        (padAll 1
          (vBox
            [ renderForm form
            , str " "
            , str "[Esc] Back to Hub | [Enter] Preview | [Ctrl-F] From | [Ctrl-T] To"
            ])))
  ]
drawUI (AppWrapper _ (SelectAccount _ target accountList _)) =
  [ center
      (borderWithLabel (str (selectionLabel target))
        (hLimit 48
          (vLimit 15
            (L.renderList renderAccount True accountList
              <=> str " "
              <=> str "[Enter] Select | [Esc] Cancel"))))
  ]
drawUI (AppWrapper _ (ShowPreview _ preview _)) =
  [ center
      (borderWithLabel (str "Preview")
        (padAll 1
          (renderPreview preview
            <=> str " "
            <=> str (previewControls preview))))
  ]
drawUI (AppWrapper _ (ShowConfirmation _ block _)) =
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
drawUI (AppWrapper _ (ShowWriteOutcome _ outcome _)) =
  [ center
      (borderWithLabel (str "Actual Add Result")
        (padAll 1
          (renderWriteOutcome outcome
            <=> str " "
            <=> str "[Esc/Q] Back to Hub")))
  ]

renderOperation :: Bool -> DailyOperation -> Widget Name
renderOperation selected op =
  let title = operationTitle op
      avail = operationAvailability op
      badge = case avail of
        OperationEnabled -> withAttr (attrName "success") (txt "[Enabled]")
        OperationDisabled reason ->
          withAttr (attrName "disabled") (txt ("[" <> disabledReasonText reason <> "]"))
      content = badge <+> txt " " <+> txt title
  in if selected
       then withAttr L.listSelectedAttr content
       else content

renderBrowseRow :: Bool -> ActualBrowseRow -> Widget Name
renderBrowseRow selected row =
  let tx = rowTransaction row
      dateStr = formatTime defaultTimeLocale "%Y-%m-%d" (transactionDate tx)
      desc = transactionDescription tx
      postingsCount = T.pack (show (length (transactionPostings tx))) <> " p."
      idWidget = case rowIdentityStatus row of
        ActualHasExplicitDurableIdentity actualId ->
          withAttr (attrName "success") (txt ("[" <> actualTransactionIdText actualId <> "]"))
        ActualHasPlanDerivedRuntimeIdentity planId _actualId ->
          withAttr (attrName "warning") (txt ("[plan-derived: " <> planIdText planId <> "]"))
        ActualHasNoIdentity ->
          withAttr (attrName "disabled") (txt "[no identity]")
      revWidget = case rowReverses row of
        Just targetId ->
          withAttr (attrName "warning") (txt (" (reverses: " <> actualTransactionIdText targetId <> ")"))
        Nothing -> emptyWidget
      content = txt (T.pack dateStr <> "  ")
        <+> padRight (Pad 1) (hLimit 22 (txt desc <+> fill ' '))
        <+> padRight (Pad 1) (txt postingsCount)
        <+> idWidget
        <+> revWidget
  in if selected
       then withAttr L.listSelectedAttr content
       else content

loadFailureTitle :: ActualSourceOperation -> String
loadFailureTitle LoadForActualAdd = "Actual Add Load Failure"
loadFailureTitle LoadForActualBrowse = "Actual Browse Failure"

renderSourceLoadFailure :: ActualSourceOperation -> ActualSourceLoadFailure -> Widget Name
renderSourceLoadFailure op failure = case (op, failure) of
  (LoadForActualAdd, ActualSourceFileReadFailed) ->
    withAttr (attrName "error")
      (str "The current Actual Journal could not be read for Actual Add.")
  (LoadForActualAdd, ActualSourceAdmissionFailed) ->
    withAttr (attrName "error")
      (str "The current Actual Journal failed admission for Actual Add.")
  (LoadForActualBrowse, ActualSourceFileReadFailed) ->
    withAttr (attrName "error")
      (str "The current Actual Journal could not be read.")
  (LoadForActualBrowse, ActualSourceAdmissionFailed) ->
    withAttr (attrName "error")
      (str "The current Actual Journal failed admission.")

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
        , str "Return to the operation hub and reopen Actual Add to load the current source."
        ])
  ActualAddWriteRecovered failure ->
    withAttr (attrName "warning")
      (vBox
        [ str "Publication failed, and the backup was restored."
        , txt (writeFailureText failure)
        ])
  ActualAddWriteFileIOFailed ->
    withAttr (attrName "error")
      (vBox
        [ str "The writer could not complete because of a filesystem error."
        , str "No source-local error detail is retained in the TUI state."
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

appEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
appEvent event = do
  AppWrapper context state <- get
  case state of
    ShowOperationHub hubState hubList ->
      handleHubEvent context hubState hubList event
    ShowActualBrowse browseState browseList ->
      handleBrowseEvent context browseState browseList event
    ShowActualSourceLoadFailure op failure ->
      handleSourceLoadFailureEvent context op failure event
    ShowActualIdentityGenerationFailure failure ->
      handleIdentityGenerationFailureEvent context failure event
    InputForm actualId form -> handleInputEvent context actualId form event
    SelectAccount actualId target accountList form ->
      handleAccountSelection context actualId target accountList form event
    ShowPreview actualId preview form ->
      handlePreviewEvent context actualId preview form event
    ShowConfirmation actualId block form ->
      handleConfirmationEvent context actualId block form event
    ShowWriteOutcome actualId outcome form ->
      handleWriteOutcomeEvent context actualId outcome form event

handleHubEvent
  :: AppContext
  -> OperationHubState
  -> L.List Name DailyOperation
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleHubEvent context hubState hubList event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey V.KEnter []) ->
    case L.listSelectedElement hubList of
      Nothing -> pure ()
      Just (_, selectedOp) ->
        case operationAvailability selectedOp of
          OperationEnabled ->
            case selectedOp of
              OperationActualAdd -> do
                loadResult <- liftIO (loadActualSourceSnapshot (contextSourcePath context))
                case loadResult of
                  Left failure ->
                    put (AppWrapper context (ShowActualSourceLoadFailure LoadForActualAdd failure))
                  Right freshSnapshot -> do
                    genResult <- liftIO (generateActualTransactionId (actualSnapshotJournal freshSnapshot))
                    case genResult of
                      Left genFailure ->
                        put (AppWrapper context (ShowActualIdentityGenerationFailure genFailure))
                      Right actualId -> do
                        let freshContext = context { contextActualSnapshot = freshSnapshot }
                        put (AppWrapper freshContext (InputForm actualId (mkForm emptyActualAddInput)))
              OperationActualBrowse -> do
                loadResult <- liftIO (loadActualSourceSnapshot (contextSourcePath context))
                case loadResult of
                  Left failure ->
                    put (AppWrapper context (ShowActualSourceLoadFailure LoadForActualBrowse failure))
                  Right freshSnapshot -> do
                    let freshContext = context { contextActualSnapshot = freshSnapshot }
                        browseState = initialActualBrowseStateFromSnapshot freshSnapshot
                        browseList = L.list BrowseRowList (Vec.fromList (browseRows browseState)) 1
                    put (AppWrapper freshContext (ShowActualBrowse browseState browseList))
              _ -> pure ()
          OperationDisabled _ -> pure ()
  VtyEvent (V.EvKey V.KUp []) -> moveHub HubMoveUp
  VtyEvent (V.EvKey (V.KChar 'k') []) -> moveHub HubMoveUp
  VtyEvent (V.EvKey V.KDown []) -> moveHub HubMoveDown
  VtyEvent (V.EvKey (V.KChar 'j') []) -> moveHub HubMoveDown
  VtyEvent vtyEvent ->
    zoom zoomHubList (L.handleListEventVi L.handleListEvent vtyEvent)
  _ -> pure ()
  where
    moveHub :: OperationHubAction -> EventM Name AppWrapper ()
    moveHub action = do
      let nextState = transitionOperationHub action hubState
          nextList = L.listMoveTo (hubSelectedIndex nextState) hubList
      put (AppWrapper context (ShowOperationHub nextState nextList))

handleBrowseEvent
  :: AppContext
  -> ActualBrowseState
  -> L.List Name ActualBrowseRow
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleBrowseEvent context browseState browseList event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> returnToHub context
  VtyEvent (V.EvKey (V.KChar 'q') []) -> returnToHub context
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> returnToHub context
  VtyEvent (V.EvKey V.KEnter []) -> pure ()
  VtyEvent (V.EvKey V.KUp []) -> moveBrowse BrowseMoveUp
  VtyEvent (V.EvKey (V.KChar 'k') []) -> moveBrowse BrowseMoveUp
  VtyEvent (V.EvKey V.KDown []) -> moveBrowse BrowseMoveDown
  VtyEvent (V.EvKey (V.KChar 'j') []) -> moveBrowse BrowseMoveDown
  VtyEvent vtyEvent ->
    zoom zoomBrowseList (L.handleListEventVi L.handleListEvent vtyEvent)
  _ -> pure ()
  where
    moveBrowse :: ActualBrowseAction -> EventM Name AppWrapper ()
    moveBrowse action = do
      let nextState = transitionActualBrowse action browseState
          nextList = L.listMoveTo (browseSelectedIndex nextState) browseList
      put (AppWrapper context (ShowActualBrowse nextState nextList))

handleSourceLoadFailureEvent
  :: AppContext
  -> ActualSourceOperation
  -> ActualSourceLoadFailure
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleSourceLoadFailureEvent context _ _ event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> returnToHub context
  VtyEvent (V.EvKey (V.KChar 'q') []) -> returnToHub context
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> returnToHub context
  _ -> pure ()

handleIdentityGenerationFailureEvent
  :: AppContext
  -> ActualIdentityGenerationFailure
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleIdentityGenerationFailureEvent context _ event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> returnToHub context
  VtyEvent (V.EvKey (V.KChar 'q') []) -> returnToHub context
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> returnToHub context
  _ -> pure ()

returnToHub :: AppContext -> EventM Name AppWrapper ()
returnToHub context =
  put (AppWrapper context mkInitialHubUIState)

mkInitialHubUIState :: UIState AppEvent
mkInitialHubUIState =
  ShowOperationHub
    initialOperationHubState
    (L.list HubOperationList (Vec.fromList allDailyOperations) 1)

handleInputEvent
  :: AppContext
  -> ActualTransactionId
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleInputEvent context actualId form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> returnToHub context
  VtyEvent (V.EvKey V.KEnter []) -> do
    let pureState =
          transitionActualAdd
            (contextSource context)
            RequestActualAddPreview
            (ActualAddState actualId (formState form) EditingActualAdd)
    case actualAddMode pureState of
      ShowingActualAddPreview preview ->
        put (AppWrapper context (ShowPreview actualId preview form))
      _ -> put (AppWrapper context (InputForm actualId form))
  VtyEvent (V.EvKey (V.KFun 2) []) ->
    openAccountSelection context actualId SelectFromAccount form
  VtyEvent (V.EvKey (V.KChar 'f') [V.MCtrl]) ->
    openAccountSelection context actualId SelectFromAccount form
  VtyEvent (V.EvKey (V.KFun 3) []) ->
    openAccountSelection context actualId SelectToAccount form
  VtyEvent (V.EvKey (V.KChar 't') [V.MCtrl]) ->
    openAccountSelection context actualId SelectToAccount form
  _ -> zoom zoomForm (handleFormEvent event)

openAccountSelection
  :: AppContext
  -> ActualTransactionId
  -> AccountSelectionTarget
  -> Form ActualAddInput AppEvent Name
  -> EventM Name AppWrapper ()
openAccountSelection context actualId target form =
  put
    (AppWrapper context
      (SelectAccount
        actualId
        target
        (L.list AccountList (Vec.fromList (contextAccounts context)) 1)
        form))

handleAccountSelection
  :: AppContext
  -> ActualTransactionId
  -> AccountSelectionTarget
  -> L.List Name Text
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleAccountSelection context actualId target accountList form event = case event of
  VtyEvent (V.EvKey V.KEsc []) ->
    put (AppWrapper context (InputForm actualId form))
  VtyEvent (V.EvKey V.KEnter []) ->
    case L.listSelectedElement accountList of
      Nothing -> put (AppWrapper context (InputForm actualId form))
      Just (_, accountText) -> do
        let state =
              transitionActualAdd
                (contextSource context)
                (ChooseAccount accountText)
                (ActualAddState
                  actualId
                  (formState form)
                  (SelectingActualAccount target))
        put
          (AppWrapper context
            (InputForm actualId (updateFormState (actualAddInput state) form)))
  VtyEvent vtyEvent ->
    zoom zoomList (L.handleListEventVi L.handleListEvent vtyEvent)
  _ -> pure ()

handlePreviewEvent
  :: AppContext
  -> ActualTransactionId
  -> ActualAddPreview
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handlePreviewEvent context actualId preview form event = case event of
  VtyEvent (V.EvKey V.KEsc []) ->
    put (AppWrapper context (InputForm actualId form))
  VtyEvent (V.EvKey (V.KChar 'b') []) ->
    put (AppWrapper context (InputForm actualId form))
  VtyEvent (V.EvKey (V.KChar 'B') []) ->
    put (AppWrapper context (InputForm actualId form))
  VtyEvent (V.EvKey (V.KChar 'c') []) ->
    requestConfirmation context actualId preview form
  VtyEvent (V.EvKey (V.KChar 'C') []) ->
    requestConfirmation context actualId preview form
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()

requestConfirmation
  :: AppContext
  -> ActualTransactionId
  -> ActualAddPreview
  -> Form ActualAddInput AppEvent Name
  -> EventM Name AppWrapper ()
requestConfirmation context actualId preview form = do
  let state =
        transitionActualAdd
          (contextSource context)
          RequestActualAddConfirmation
          (ActualAddState
            actualId
            (formState form)
            (ShowingActualAddPreview preview))
  case actualAddMode state of
    ConfirmingActualAdd block ->
      put (AppWrapper context (ShowConfirmation actualId block form))
    _ -> put (AppWrapper context (ShowPreview actualId preview form))

handleConfirmationEvent
  :: AppContext
  -> ActualTransactionId
  -> Text
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleConfirmationEvent context actualId block form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> cancelConfirmation context actualId block form
  VtyEvent (V.EvKey (V.KChar 'n') []) -> cancelConfirmation context actualId block form
  VtyEvent (V.EvKey (V.KChar 'N') []) -> cancelConfirmation context actualId block form
  VtyEvent (V.EvKey (V.KChar 'y') []) -> acceptConfirmation context actualId block form
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> acceptConfirmation context actualId block form
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()

cancelConfirmation
  :: AppContext
  -> ActualTransactionId
  -> Text
  -> Form ActualAddInput AppEvent Name
  -> EventM Name AppWrapper ()
cancelConfirmation context actualId block form = do
  let state =
        transitionActualAdd
          (contextSource context)
          CancelActualAddConfirmation
          (ActualAddState actualId (formState form) (ConfirmingActualAdd block))
  case actualAddMode state of
    ShowingActualAddPreview preview ->
      put (AppWrapper context (ShowPreview actualId preview form))
    _ -> put (AppWrapper context (ShowConfirmation actualId block form))

acceptConfirmation
  :: AppContext
  -> ActualTransactionId
  -> Text
  -> Form ActualAddInput AppEvent Name
  -> EventM Name AppWrapper ()
acceptConfirmation context actualId block form = do
  let state =
        transitionActualAdd
          (contextSource context)
          ConfirmActualAdd
          (ActualAddState actualId (formState form) (ConfirmingActualAdd block))
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
            actualId
            (classifyActualAddWriteResult writeResult)
            form))
    _ -> put (AppWrapper context (ShowConfirmation actualId block form))

handleWriteOutcomeEvent
  :: AppContext
  -> ActualTransactionId
  -> ActualAddWriteOutcome
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleWriteOutcomeEvent context _ _ _ event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> returnToHub context
  VtyEvent (V.EvKey (V.KChar 'q') []) -> returnToHub context
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> returnToHub context
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
        , (attrName "disabled", fg V.yellow)
        ])
  }

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [journalFile] -> do
      snapshotResult <- loadActualSourceSnapshot journalFile
      snapshot <- case snapshotResult of
        Left failure -> die (T.unpack (actualSourceStartupFailureText failure))
        Right snap -> pure snap
      let context = AppContext journalFile snapshot
          initialState = AppWrapper context mkInitialHubUIState
          buildVty = mkVty V.defaultConfig
      initialVty <- buildVty
      _ <- customMain initialVty buildVty Nothing app initialState
      pure ()
    _ -> die "Usage: h-kernel-editor-tui <actual.journal>"
