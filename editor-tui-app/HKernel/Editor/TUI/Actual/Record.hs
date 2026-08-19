{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Actual.Record
  ( State
  , FlowAction(..)
  , drawFlow
  , handleFlowEvent
  , startIssueRealize
  , startRecord
  ) where

import Brick
import Brick.Focus (focusGetCurrent)
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import Control.Monad.IO.Class (liftIO)
import qualified Graphics.Vty as V
import Lens.Micro (Lens', Traversal')

import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import System.IO.Error (isDoesNotExistError, tryIOError)
import Text.Read (readMaybe)

import qualified HKernel.Account
import HKernel.Actual.Journal (actualJournalValue)
import HKernel.Application.Config (HouseholdSourcePaths(..))
import HKernel.Editor.ActualAppend
  ( ActualMultiAddInput(..)
  , ActualMultiAddPreview(..)
  , ActualPostingInput(..)
  , buildActualMultiAddIntentWithRegistry
  , prepareActualMultiAddPreviewFromResolvedJournal
  )
import HKernel.Editor.Interaction.ActualAdd
  ( actualMultiPostingAt
  , commitMultiAccountCandidate
  , filterMultiAccountCandidates
  , initialActualMultiAddInputForDay
  , initialActualMultiAddInputForDescription
  , moveMultiAccountCandidateCursor
  , multiAccountCandidates
  , resetMultiAccountCandidateCursor
  , resizeActualMultiPostings
  , setActualMultiPostingAccountText
  , setActualMultiPostingAmount
  )
import HKernel.Editor.IssueRealize
  ( IssueRealizeDisplayPreview(..)
  , IssueRealizeIntent(..)
  , prepareIssueRealizeDisplayPreview
  )
import HKernel.Editor.TUI.Actual.AccountSelector
  ( contextActualTransactions
  , flattenCandidateGroups
  , renderInlineAccountSelector
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , contextHouseholdState
  , contextIssuesSource
  , contextSource
  )
import HKernel.Household.Application (HouseholdState(..))
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueStatus(..)
  , householdIssueId
  , householdIssueStatus
  , householdIssueText
  , issueIdText
  )

data RecordPurpose
  = OrdinaryRecord
  | RealizeIssue HouseholdIssue
  deriving (Eq, Show)

-- | Brick-local coordinates around the one authoritative multi-posting draft.
-- Issue realization changes the final household operation, not the posting editor.
data MultiFormState = MultiFormState
  { multiFormInput                  :: ActualMultiAddInput
  , multiFormSelectedPosting        :: Int
  , multiFormPostingCountText       :: Text
  , multiFormAccountCandidateCursor :: Maybe Int
  , multiFormPurpose                :: RecordPurpose
  , multiFormDecisionMemoText       :: Text
  } deriving (Eq, Show)

data RecordPreview
  = RecordActualPreview ActualMultiAddPreview
  | RecordIssueRealizeRejected Text
  | RecordIssueRealizeReady IssueRealizeDisplayPreview IssueRealizeIntent
  deriving (Eq, Show)

data State event
  = Input (Form MultiFormState event Name)
  | Preview RecordPreview (Form MultiFormState event Name)

data FlowAction
  = FlowMaintain
  | FlowReturn
  | FlowQuit
  | FlowPublishActual Day Text
  | FlowPublishIssueRealize Day IssueRealizeIntent

startRecord :: Day -> State event
startRecord day =
  Input (mkMultiForm (initialMultiFormState OrdinaryRecord day))

startIssueRealize :: Day -> HouseholdIssue -> Maybe (State event)
startIssueRealize day issue
  | householdIssueStatus issue == Open =
      Just (Input (mkMultiForm (initialMultiFormState (RealizeIssue issue) day)))
  | otherwise = Nothing

multiDescriptionTextL :: Lens' MultiFormState Text
multiDescriptionTextL f state =
  (\value -> state
      { multiFormInput = input { multiAddDescriptionText = value } })
    <$> f (multiAddDescriptionText input)
  where
    input = multiFormInput state

multiPostingCountTextL :: Lens' MultiFormState Text
multiPostingCountTextL f state =
  (\value -> state { multiFormPostingCountText = value })
    <$> f (multiFormPostingCountText state)

multiAccountTextL :: Lens' MultiFormState Text
multiAccountTextL f state =
  (\value -> state
      { multiFormInput =
          setActualMultiPostingAccountText selected value input
      , multiFormAccountCandidateCursor = resetMultiAccountCandidateCursor
          current value (multiFormAccountCandidateCursor state)
      })
    <$> f current
  where
    input = multiFormInput state
    selected = multiFormSelectedPosting state
    posting = actualMultiPostingAt selected input
    current = multiPostingAccountText posting

multiAmountTextL :: Lens' MultiFormState Text
multiAmountTextL f state =
  (\value -> state
      { multiFormInput = setActualMultiPostingAmount selected value input })
    <$> f (multiPostingAmountText posting)
  where
    input = multiFormInput state
    selected = multiFormSelectedPosting state
    posting = actualMultiPostingAt selected input

multiDecisionMemoTextL :: Lens' MultiFormState Text
multiDecisionMemoTextL f state =
  (\value -> state { multiFormDecisionMemoText = value })
    <$> f (multiFormDecisionMemoText state)

initialMultiFormState :: RecordPurpose -> Day -> MultiFormState
initialMultiFormState purpose day = MultiFormState
  { multiFormInput = input
  , multiFormSelectedPosting = 0
  , multiFormPostingCountText =
      T.pack (show (NonEmpty.length (multiAddPostings input)))
  , multiFormAccountCandidateCursor = Nothing
  , multiFormPurpose = purpose
  , multiFormDecisionMemoText = ""
  }
  where
    input = case purpose of
      OrdinaryRecord -> initialActualMultiAddInputForDay day
      RealizeIssue issue -> initialActualMultiAddInputForDescription day
        (householdIssueText issue)

mkMultiForm :: MultiFormState -> Form MultiFormState event Name
mkMultiForm state =
  let label labelText widget =
        padBottom (Pad 1)
          ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)
      baseFields =
        [ label "Description:"
            @@= editTextField multiDescriptionTextL MultiDescriptionField (Just 1)
        , label "Posting count:"
            @@= editTextField multiPostingCountTextL MultiPostingCountField (Just 1)
        , label "Selected account:"
            @@= editTextField multiAccountTextL MultiAccountField (Just 1)
        , label "Selected amount:"
            @@= editTextField multiAmountTextL MultiAmountField (Just 1)
        ]
      realizationFields = case multiFormPurpose state of
        OrdinaryRecord -> []
        RealizeIssue _ ->
          [ label "Decision memo:"
              @@= editTextField multiDecisionMemoTextL IssueDecisionMemoField (Just 1)
          ]
      form = newForm (baseFields <> realizationFields) state
  in setFormFocus MultiDescriptionField form

applyMultiPostingCount :: MultiFormState -> MultiFormState
applyMultiPostingCount state = state
  { multiFormInput = resized
  , multiFormSelectedPosting = clampMultiPostingIndex selected resized
  , multiFormPostingCountText =
      T.pack (show (NonEmpty.length (multiAddPostings resized)))
  }
  where
    input = multiFormInput state
    currentCount = NonEmpty.length (multiAddPostings input)
    requestedCount = fromMaybe currentCount
      (readMaybe (T.unpack (T.strip (multiFormPostingCountText state))))
    resized = resizeActualMultiPostings requestedCount input
    selected = multiFormSelectedPosting state

selectMultiPosting :: Int -> MultiFormState -> MultiFormState
selectMultiPosting requested state = state
  { multiFormSelectedPosting = clampMultiPostingIndex requested input
  , multiFormAccountCandidateCursor = Nothing
  }
  where
    input = multiFormInput state

clampMultiPostingIndex :: Int -> ActualMultiAddInput -> Int
clampMultiPostingIndex requested input =
  max 0 (min requested (NonEmpty.length (multiAddPostings input) - 1))

zoomForm :: Traversal' (State AppEvent) (Form MultiFormState AppEvent Name)
zoomForm f (Input form) = Input <$> f form
zoomForm _ state = pure state

drawFlow :: AppContext -> State AppEvent -> Widget Name
drawFlow context state = case state of
  Input form ->
    let multiState = formState form
        input = multiFormInput multiState
    in center
      (borderWithLabel (str (recordInputTitle multiState))
        (hLimit 86
          (padAll 1
            (vBox
              ( recordPurposeHeader context multiState
                ++ [ txt ("Entry day: " <> T.pack (show (contextEntryDay context)))
                   , strWrap "The entry day is already fixed by the current TUI context."
                   , strWrap "Use two postings for an ordinary transaction, or increase the posting count when needed."
                   , strWrap "Each posting owns its sign. The complete transaction must balance to zero."
                   , str " "
                   , renderMultiPostingRows multiState
                   , str " "
                   , txt ("Editing posting "
                       <> T.pack (show (multiFormSelectedPosting multiState + 1))
                       <> " of "
                       <> T.pack (show (NonEmpty.length (multiAddPostings input))))
                   , renderForm form
                   , renderMultiInlineAccountSelector context form
                   , str " "
                   , strWrap "Validation: press Enter outside the Account field to check admission and balance."
                   , multiInputControls form
                   ])))))
  Preview preview form ->
    center
      (borderWithLabel (str (recordPreviewTitle (formState form)))
        (hLimit 86
          (padAll 1
            (renderRecordPreview preview <=> str " "
              <=> strWrap (recordPreviewControls preview)))))

recordInputTitle :: MultiFormState -> String
recordInputTitle state = case multiFormPurpose state of
  OrdinaryRecord -> "Record"
  RealizeIssue _ -> "Realize Issue as Actual"

recordPreviewTitle :: MultiFormState -> String
recordPreviewTitle state = case multiFormPurpose state of
  OrdinaryRecord -> "Record Preview"
  RealizeIssue _ -> "Issue Realize Preview"

recordPurposeHeader :: AppContext -> MultiFormState -> [Widget Name]
recordPurposeHeader context state = case multiFormPurpose state of
  OrdinaryRecord -> []
  RealizeIssue issue ->
    [ txtWrap ("Issue: " <> issueIdText (householdIssueId issue)
        <> "  " <> householdIssueText issue)
    , txt ("Effective day: " <> T.pack (show (contextEntryDay context)))
    , strWrap "Actual transaction, Issue close, and relation record use this same entry day."
    , strWrap "Issue amount is not copied into the transaction; postings remain explicit."
    , str " "
    ]

multiInputControls :: Form MultiFormState AppEvent Name -> Widget Name
multiInputControls form
  | multiAccountFocused form =
      strWrap "[Up/Down] Choose Account | [click] Select | [Enter] Accept | [Tab] Next field | text edits exact Account | [Esc] Back"
  | otherwise =
      strWrap "[Tab] Next field | [Up/Down] Previous/next posting row | [Enter] Preview | [Esc] Back"

renderMultiInlineAccountSelector
  :: AppContext
  -> Form MultiFormState AppEvent Name
  -> Widget Name
renderMultiInlineAccountSelector context form
  | multiAccountFocused form =
      renderInlineAccountSelector context "Posting Accounts"
        (multiFormAccountCandidateCursor state)
        (filterMultiAccountCandidates current (multiCandidates context))
  | otherwise = emptyWidget
  where
    state = formState form
    selectedPosting = actualMultiPostingAt
      (multiFormSelectedPosting state) (multiFormInput state)
    current = multiPostingAccountText selectedPosting

multiAccountFocused :: Form MultiFormState event Name -> Bool
multiAccountFocused form =
  focusGetCurrent (formFocus form) == Just MultiAccountField

multiCandidates :: AppContext -> [HKernel.Account.Account]
multiCandidates context =
  flattenCandidateGroups context
    (multiAccountCandidates registry (contextActualTransactions context))
  where
    registry = householdStateAccountsRegistry (contextHouseholdState context)

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleFlowEvent context event = do
  state <- get
  case state of
    Input form -> handleInput context form event
    Preview preview form -> handlePreview context preview form event

handleInput
  :: AppContext
  -> Form MultiFormState AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handleInput context form event = case event of
  MouseDown (AccountCandidate index) V.BLeft _ _
    | multiAccountFocused form ->
        selectMultiAccountCandidateAt context index form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEsc []) -> pure FlowReturn
  VtyEvent (V.EvKey V.KUp [])
    | multiAccountFocused form ->
        moveMultiAccountCandidate context (-1) form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KDown [])
    | multiAccountFocused form ->
        moveMultiAccountCandidate context 1 form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEnter [])
    | multiAccountFocused form ->
        acceptMultiAccount context form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KEnter []) -> prepareMultiPreview context form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KUp []) -> moveMultiSelection (-1) form >> pure FlowMaintain
  VtyEvent (V.EvKey V.KDown []) -> moveMultiSelection 1 form >> pure FlowMaintain
  _ -> zoom zoomForm (handleFormEvent event) >> pure FlowMaintain

moveMultiAccountCandidate
  :: AppContext
  -> Int
  -> Form MultiFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
moveMultiAccountCandidate context offset form =
  let nextCursor = moveMultiAccountCandidateCursor
        offset current (multiFormAccountCandidateCursor state) candidates
      updatedState = state { multiFormAccountCandidateCursor = nextCursor }
      updatedForm = setFormFocus MultiAccountField
        (updateFormState updatedState form)
  in put (Input updatedForm)
  where
    state = formState form
    input = multiFormInput state
    selected = multiFormSelectedPosting state
    current = multiPostingAccountText (actualMultiPostingAt selected input)
    candidates = multiCandidates context

selectMultiAccountCandidateAt
  :: AppContext
  -> Int
  -> Form MultiFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
selectMultiAccountCandidateAt context index form =
  case commitMultiAccountCandidate selected current index candidates input of
    Nothing -> pure ()
    Just updatedInput ->
      let updatedState = state
            { multiFormInput = updatedInput
            , multiFormAccountCandidateCursor = Nothing
            }
          updatedForm = setFormFocus MultiAmountField
            (updateFormState updatedState form)
      in put (Input updatedForm)
  where
    state = formState form
    input = multiFormInput state
    selected = multiFormSelectedPosting state
    current = multiPostingAccountText (actualMultiPostingAt selected input)
    candidates = filterMultiAccountCandidates current (multiCandidates context)

acceptMultiAccount
  :: AppContext
  -> Form MultiFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
acceptMultiAccount context form =
  case multiFormAccountCandidateCursor state >>= commitCandidate of
    Nothing -> pure ()
    Just updatedInput ->
      let updatedState = state
            { multiFormInput = updatedInput
            , multiFormAccountCandidateCursor = Nothing
            }
      in put (Input
          (setFormFocus MultiAmountField (updateFormState updatedState form)))
  where
    state = formState form
    input = multiFormInput state
    selected = multiFormSelectedPosting state
    current = multiPostingAccountText (actualMultiPostingAt selected input)
    candidates = multiCandidates context
    commitCandidate index =
      commitMultiAccountCandidate selected current index candidates input

moveMultiSelection
  :: Int
  -> Form MultiFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
moveMultiSelection offset form =
  let applied = applyMultiPostingCount (formState form)
      selected = multiFormSelectedPosting applied + offset
      moved = selectMultiPosting selected applied
  in put (Input (updateFormState moved form))

prepareMultiPreview
  :: AppContext
  -> Form MultiFormState AppEvent Name
  -> EventM Name (State AppEvent) ()
prepareMultiPreview context form = do
  let applied = applyMultiPostingCount (formState form)
      updatedForm = updateFormState applied form
      resolvedJournal = actualJournalValue
        (householdStateActualJournal (contextHouseholdState context))
  preview <- case multiFormPurpose applied of
    OrdinaryRecord -> pure
      (RecordActualPreview
        (prepareActualMultiAddPreviewFromResolvedJournal
          resolvedJournal (contextSource context) (multiFormInput applied)))
    RealizeIssue issue -> liftIO
      (prepareIssueRealizeRecordPreview context issue applied)
  put (Preview preview updatedForm)

prepareIssueRealizeRecordPreview
  :: AppContext
  -> HouseholdIssue
  -> MultiFormState
  -> IO RecordPreview
prepareIssueRealizeRecordPreview context issue formState = do
  let state = contextHouseholdState context
      paths = householdStatePaths state
      registry = householdStateAccountsRegistry state
      memo = T.strip (multiFormDecisionMemoText formState)
      entryDay = contextEntryDay context
  case buildActualMultiAddIntentWithRegistry registry (multiFormInput formState) of
    Left inputError -> pure
      (RecordIssueRealizeRejected
        ("Actual input rejected: " <> T.pack (show inputError)))
    Right actualIntent
      | T.null memo -> pure
          (RecordIssueRealizeRejected "Decision memo is required for Issue realization.")
      | otherwise -> do
          relationResult <- readOptionalRelationSource
            (householdIssueRelationsPath paths)
          case relationResult of
            Left message -> pure (RecordIssueRealizeRejected message)
            Right relationSource -> do
              let intent = IssueRealizeIntent
                    { realizeIssueId = householdIssueId issue
                    , realizeRecordedOn = entryDay
                    , realizeClosedOn = entryDay
                    , realizeActualIntent = actualIntent
                    , realizeDecisionMemo = memo
                    }
              pure $ case prepareIssueRealizeDisplayPreview
                  (householdStateActualJournal state)
                  (householdStatePlanJournal state)
                  (contextSource context)
                  relationSource
                  (contextIssuesSource context)
                  intent of
                Left errors -> RecordIssueRealizeRejected
                  ("Issue realization rejected: "
                    <> T.pack (show (NonEmpty.toList errors)))
                Right preview -> RecordIssueRealizeReady preview intent

readOptionalRelationSource :: FilePath -> IO (Either Text Text)
readOptionalRelationSource path = do
  result <- tryIOError (TIO.readFile path)
  pure $ case result of
    Right source -> Right source
    Left errorValue
      | isDoesNotExistError errorValue -> Right ""
      | otherwise -> Left ("Relation source read failed: " <> T.pack (show errorValue))

handlePreview
  :: AppContext
  -> RecordPreview
  -> Form MultiFormState AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) FlowAction
handlePreview context preview form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey (V.KChar 'b') []) -> back
  VtyEvent (V.EvKey (V.KChar 'B') []) -> back
  VtyEvent (V.EvKey V.KEnter []) -> publish
  VtyEvent (V.EvKey (V.KChar 'y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'c') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'C') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'q') []) -> pure FlowQuit
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> pure FlowQuit
  _ -> pure FlowMaintain
  where
    back = put (Input form) >> pure FlowMaintain
    publish = case preview of
      RecordActualPreview (ActualMultiAddCandidateReady block) ->
        pure (FlowPublishActual (contextEntryDay context) block)
      RecordIssueRealizeReady _ intent ->
        pure (FlowPublishIssueRealize (contextEntryDay context) intent)
      _ -> pure FlowMaintain

renderMultiPostingRows :: MultiFormState -> Widget Name
renderMultiPostingRows state =
  vBox
    [ renderRow index posting
    | (index, posting) <- zip [0 ..]
        (NonEmpty.toList (multiAddPostings (multiFormInput state)))
    ]
  where
    selected = multiFormSelectedPosting state
    renderRow index posting =
      let accountText
            | T.null (multiPostingAccountText posting) = "(enter account)"
            | otherwise = multiPostingAccountText posting
          amountText
            | T.null (multiPostingAmountText posting) = "(amount)"
            | otherwise = multiPostingAmountText posting
          row = txtWrap
            (T.pack (show (index + 1)) <> ".  " <> accountText <> "  " <> amountText)
      in if index == selected then withAttr L.listSelectedAttr row else row

renderRecordPreview :: RecordPreview -> Widget Name
renderRecordPreview preview = case preview of
  RecordActualPreview actualPreview -> renderMultiPreview actualPreview
  RecordIssueRealizeRejected message ->
    withAttr (attrName "error") (txtWrap message)
  RecordIssueRealizeReady displayPreview _ ->
    withAttr (attrName "success")
      (strWrap "All three candidates admitted. Sources unmodified.")
      <=> str " "
      <=> str "--- Actual ---"
      <=> txtWrap (displayActualBlock displayPreview)
      <=> str "--- Relation ---"
      <=> txtWrap (displayRelationBlock displayPreview)
      <=> str "--- Issue ---"
      <=> txtWrap (displayIssueBlock displayPreview)

recordPreviewControls :: RecordPreview -> String
recordPreviewControls preview = case preview of
  RecordActualPreview actualPreview -> multiPreviewControls actualPreview
  RecordIssueRealizeReady _ _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  RecordIssueRealizeRejected _ -> "[Esc/B] Back | [Q] Quit"

renderMultiPreview :: ActualMultiAddPreview -> Widget Name
renderMultiPreview preview = case preview of
  ActualMultiAddInputRejected inputError ->
    withAttr (attrName "error")
      (txtWrap ("Input rejected: " <> T.pack (show inputError)))
  ActualMultiAddCandidateRejected sourceErrors ->
    withAttr (attrName "error")
      (txtWrap (T.intercalate "\n" (map (T.pack . show) (NonEmpty.toList sourceErrors))))
  ActualMultiAddCandidateReady block ->
    withAttr (attrName "success")
      (strWrap "Validation successful. Source unmodified.")
      <=> str " " <=> txtWrap block

multiPreviewControls :: ActualMultiAddPreview -> String
multiPreviewControls preview = case preview of
  ActualMultiAddCandidateReady _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  _ -> "[Esc/B] Back | [Q] Quit"
