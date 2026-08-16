{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Maintenance
  ( AccountsWorkspaceAction(..)
  , BudgetWorkspaceAction(..)
  , IssuesWorkspaceAction(..)
  , PublishRequest(..)
  , PublishResult(..)
  , State(..)
  , drawAccountsWorkspace
  , drawBudgetWorkspace
  , drawIssuesWorkspace
  , drawFlow
  , handleAccountsWorkspaceEvent
  , handleBudgetWorkspaceEvent
  , handleFlowEvent
  , handleIssuesWorkspaceEvent
  , publishCandidate
  , startAccountAdd
  , startBudgetMovement
  , startIssueAdd
  , startSelectedIssueClose
  , startSelectedIssueDueUpdate
  ) where

import Brick
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V
import Lens.Micro (Lens', Traversal')

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)

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
import HKernel.Envelope.Policy
  ( EnvelopeDefinition
  , currentEnvelopePolicyDefinitions
  , envelopeDefinitionId
  )
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
import HKernel.Editor.BudgetMovementAppend
  ( BudgetJournalMovementAppendPreview(..)
  , prepareCurrentBudgetJournalMovementAppend
  )
import HKernel.Editor.IssueAppend
  ( IssueAppendIntent(..)
  , IssueAppendPreview(..)
  , IssueCloseDisposition(..)
  , IssueCloseIntent(..)
  , IssueClosePreview(..)
  , IssueDueUpdateIntent(..)
  , IssueDueUpdatePreview(..)
  , generateAvailableIssueId
  , prepareIssueAppendWithDue
  , prepareIssueClose
  , prepareIssueCloseOn
  , prepareIssueDueUpdate
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , contextAccountsSource
  , contextBudgetSource
  , contextHouseholdState
  , contextIssueListL
  , contextIssuesSource
  , reloadWorkspaceContext
  )
import HKernel.Household.Application
  ( HouseholdState(..)
  , householdStateBudgetMovements
  , loadCanonicalHousehold
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.Issue.TSV (householdIssueSourceUsesClosedColumn)
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueClosed(..)
  , IssueDue(..)
  , IssueStatus(..)
  , householdIssueAmount
  , householdIssueClosed
  , householdIssueDetails
  , householdIssueDue
  , householdIssueId
  , householdIssueRecordedOn
  , householdIssueStatus
  , householdIssueText
  , issueIdText
  )
import HKernel.Money
  ( Amount
  , amountCommodity
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

data AccountInput = AccountInput
  { accountNameText      :: Text
  , accountTypeText      :: Text
  , accountCommodityText :: Text
  } deriving (Eq, Show)

data IssueInput = IssueInput
  { issueRecordedDateText :: Text
  , issueCategoryText     :: Text
  , issueTitleText        :: Text
  , issueDueText          :: Text
  , issueAmountText       :: Text
  , issueCommodityText    :: Text
  , issueDetailsText      :: Text
  } deriving (Eq, Show)

data IssueDueInput = IssueDueInput
  { issueDueUpdateText :: Text
  } deriving (Eq, Show)

data IssueCloseInput = IssueCloseInput
  { issueClosedDateText   :: Text
  , issueDecisionMemoText :: Text
  } deriving (Eq, Show)

data State event
  = BudgetInputState (Form BudgetInput event Name)
  | BudgetPreviewState (PreviewResult BudgetJournalMovementAppendPreview) (Form BudgetInput event Name)
  | AccountInputState (Form AccountInput event Name)
  | AccountPreviewState (PreviewResult (Text, AccountJournalAppendPreview)) (Form AccountInput event Name)
  | IssueAddInputState (Form IssueInput event Name)
  | IssueAddPreviewState (PreviewResult IssueAppendPreview) (Form IssueInput event Name)
  | IssueDueInputState HouseholdIssue (Form IssueDueInput event Name)
  | IssueDuePreviewState HouseholdIssue (PreviewResult IssueDueUpdatePreview) (Form IssueDueInput event Name)
  | IssueCloseChoiceState HouseholdIssue
  | IssueCloseInputState HouseholdIssue IssueCloseDisposition (Form IssueCloseInput event Name)
  | IssueClosePreviewState HouseholdIssue IssueCloseDisposition (PreviewResult IssueClosePreview) (Form IssueCloseInput event Name)
  | WriteOutcome Text
  | ReturnToWorkspace
  | PublishRequested PublishRequest
  | QuitRequested

data PublishRequest
  = PublishBudget BudgetJournalMovementAppendPreview
  | PublishAccount Text AccountJournalAppendPreview
  | PublishIssueAdd IssueAppendPreview
  | PublishIssueDueUpdate IssueDueUpdatePreview
  | PublishIssueClose IssueClosePreview

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

accountNameL :: Lens' AccountInput Text
accountNameL f input = (\value -> input { accountNameText = value }) <$> f (accountNameText input)

accountTypeL :: Lens' AccountInput Text
accountTypeL f input = (\value -> input { accountTypeText = value }) <$> f (accountTypeText input)

accountCommodityL :: Lens' AccountInput Text
accountCommodityL f input = (\value -> input { accountCommodityText = value }) <$> f (accountCommodityText input)

issueRecordedDateL :: Lens' IssueInput Text
issueRecordedDateL f input =
  (\value -> input { issueRecordedDateText = value }) <$> f (issueRecordedDateText input)

issueCategoryL :: Lens' IssueInput Text
issueCategoryL f input = (\value -> input { issueCategoryText = value }) <$> f (issueCategoryText input)

issueTitleL :: Lens' IssueInput Text
issueTitleL f input = (\value -> input { issueTitleText = value }) <$> f (issueTitleText input)

issueDueL :: Lens' IssueInput Text
issueDueL f input = (\value -> input { issueDueText = value }) <$> f (issueDueText input)

issueAmountL :: Lens' IssueInput Text
issueAmountL f input = (\value -> input { issueAmountText = value }) <$> f (issueAmountText input)

issueCommodityL :: Lens' IssueInput Text
issueCommodityL f input = (\value -> input { issueCommodityText = value }) <$> f (issueCommodityText input)

issueDetailsL :: Lens' IssueInput Text
issueDetailsL f input = (\value -> input { issueDetailsText = value }) <$> f (issueDetailsText input)

issueDueUpdateL :: Lens' IssueDueInput Text
issueDueUpdateL f input =
  (\value -> input { issueDueUpdateText = value }) <$> f (issueDueUpdateText input)

issueClosedDateL :: Lens' IssueCloseInput Text
issueClosedDateL f input =
  (\value -> input { issueClosedDateText = value }) <$> f (issueClosedDateText input)

issueDecisionMemoL :: Lens' IssueCloseInput Text
issueDecisionMemoL f input =
  (\value -> input { issueDecisionMemoText = value }) <$> f (issueDecisionMemoText input)

labelField :: String -> Widget Name -> Widget Name
labelField labelText widget =
  padBottom (Pad 1) ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)

mkBudgetForm :: Form BudgetInput event Name
mkBudgetForm =
  newForm
    [ labelField "Memo:" @@= editTextField budgetMemoL BudgetMemoField (Just 1)
    , labelField "From Budget:" @@= editTextField budgetFromL BudgetFromField (Just 1)
    , labelField "To Budget:" @@= editTextField budgetToL BudgetToField (Just 1)
    , labelField "Amount:" @@= editTextField budgetAmountL BudgetAmountField (Just 1)
    , labelField "Commodity:" @@= editTextField budgetCommodityL BudgetCommodityField (Just 1)
    ]
    (BudgetInput "alloc" "" "" "" "JPY")

mkAccountForm :: Form AccountInput event Name
mkAccountForm =
  newForm
    [ labelField "Account:" @@= editTextField accountNameL AccountNameField (Just 1)
    , labelField "Type:" @@= editTextField accountTypeL AccountTypeField (Just 1)
    , labelField "Commodity:" @@= editTextField accountCommodityL AccountCommodityField (Just 1)
    ]
    (AccountInput "" "expense" "JPY")

mkIssueForm :: Form IssueInput event Name
mkIssueForm =
  newForm
    [ labelField "Recorded:" @@= editTextField issueRecordedDateL IssueRecordedDateField (Just 1)
    , labelField "Category:" @@= editTextField issueCategoryL IssueCategoryField (Just 1)
    , labelField "Title:" @@= editTextField issueTitleL IssueTitleField (Just 1)
    , labelField "Due:" @@= editTextField issueDueL IssueDueField (Just 1)
    , labelField "Amount:" @@= editTextField issueAmountL IssueAmountField (Just 1)
    , labelField "Commodity:" @@= editTextField issueCommodityL IssueCommodityField (Just 1)
    , labelField "Details:" @@= editTextField issueDetailsL IssueDetailsField (Just 1)
    ]
    (IssueInput "" "general" "" "?" "" "" "")

mkIssueDueForm :: HouseholdIssue -> Form IssueDueInput event Name
mkIssueDueForm issue =
  newForm
    [ labelField "Due:" @@= editTextField issueDueUpdateL IssueDueField (Just 1)
    ]
    (IssueDueInput (renderIssueDueInput (householdIssueDue issue)))

mkIssueCloseForm :: Form IssueCloseInput event Name
mkIssueCloseForm =
  newForm
    [ labelField "Closed:" @@= editTextField issueClosedDateL IssueClosedDateField (Just 1)
    , labelField "Decision memo:" @@= editTextField issueDecisionMemoL IssueDecisionMemoField (Just 1)
    ]
    (IssueCloseInput "" "")

startBudgetMovement :: State event
startBudgetMovement = BudgetInputState mkBudgetForm

startAccountAdd :: State event
startAccountAdd = AccountInputState mkAccountForm

startIssueAdd :: State event
startIssueAdd = IssueAddInputState mkIssueForm

startSelectedIssueClose :: AppContext -> Maybe (State event)
startSelectedIssueClose context = do
  (_, issue) <- L.listSelectedElement (contextIssueList context)
  pure $ case householdIssueStatus issue of
    Open -> IssueCloseChoiceState issue
    status -> WriteOutcome ("Selected Issue is already " <> T.pack (show status) <> ".")

startSelectedIssueDueUpdate :: AppContext -> Maybe (State event)
startSelectedIssueDueUpdate context = do
  (_, issue) <- L.listSelectedElement (contextIssueList context)
  pure $ case householdIssueStatus issue of
    Open -> IssueDueInputState issue (mkIssueDueForm issue)
    status -> WriteOutcome ("Selected Issue is already " <> T.pack (show status) <> ".")

zoomBudgetForm :: Traversal' (State AppEvent) (Form BudgetInput AppEvent Name)
zoomBudgetForm f (BudgetInputState form) = BudgetInputState <$> f form
zoomBudgetForm _ state = pure state

zoomAccountForm :: Traversal' (State AppEvent) (Form AccountInput AppEvent Name)
zoomAccountForm f (AccountInputState form) = AccountInputState <$> f form
zoomAccountForm _ state = pure state

zoomIssueForm :: Traversal' (State AppEvent) (Form IssueInput AppEvent Name)
zoomIssueForm f (IssueAddInputState form) = IssueAddInputState <$> f form
zoomIssueForm _ state = pure state

zoomIssueDueForm :: Traversal' (State AppEvent) (Form IssueDueInput AppEvent Name)
zoomIssueDueForm f (IssueDueInputState issue form) = IssueDueInputState issue <$> f form
zoomIssueDueForm _ state = pure state

zoomIssueCloseForm :: Traversal' (State AppEvent) (Form IssueCloseInput AppEvent Name)
zoomIssueCloseForm f (IssueCloseInputState issue disposition form) =
  IssueCloseInputState issue disposition <$> f form
zoomIssueCloseForm _ state = pure state

drawBudgetWorkspace :: AppContext -> Widget Name
drawBudgetWorkspace context =
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

drawAccountsWorkspace :: AppContext -> Widget Name
drawAccountsWorkspace context =
  vBox
    [ borderWithLabel (str "Canonical Account Declarations (accounts.journal)")
        (vLimit 18
          (viewport AccountsViewport Vertical
            (vBox (map renderAccountDecl
              (accountDeclarations
                (householdStateAccountsRegistry (contextHouseholdState context)))))))
    , str "[Enter/A] Add Account   [1-7] Sections   [q] Quit"
    ]

drawIssuesWorkspace :: AppContext -> Widget Name
drawIssuesWorkspace context =
  vBox
    [ borderWithLabel (str "Household Notebook (issues.tsv)")
        (vLimit 18 (L.renderList renderIssueItem True (contextIssueList context)))
    , borderWithLabel (str "Selected Issue")
        (padAll 1 (renderSelectedIssue context))
    , str "[j/k/Arrows] Move   [Enter] Resolve/Drop   [U] Due   [A] Add Issue   [1-7] Sections   [q] Quit"
    ]

drawFlow :: State AppEvent -> Widget Name
drawFlow state = case state of
  BudgetInputState form -> inputBox "New Budget Movement" form
    [ "Both Accounts must be canonical Budget Accounts."
    , "[Tab] Next field   [Enter] Preview   [Esc] Budget"
    ]
  BudgetPreviewState result _ -> previewBox "Budget Movement Preview"
    (renderPreviewResult (txt . budgetJournalCandidateBlock) result)
    (previewControls result)
  AccountInputState form -> inputBox "Add Account" form
    [ "Type: asset | liability | equity | income | expense | budget"
    , "Commodity may be blank when no default is required."
    , "[Tab] Next field   [Enter] Preview   [Esc] Accounts"
    ]
  AccountPreviewState result _ -> previewBox "Account Preview"
    (renderPreviewResult (txt . accountCandidateBlock . snd) result)
    (previewControls result)
  IssueAddInputState form -> inputBox "Add Household Issue" form
    [ "Recorded: YYYY-MM-DD; blank uses today's entry date."
    , "Due: YYYY-MM-DD | none | ? (undetermined)."
    , "Issue identity is generated from the recorded date."
    , "Leave both Amount and Commodity blank for a non-monetary Issue."
    , "[Tab] Next field   [Enter] Preview   [Esc] Issues"
    ]
  IssueAddPreviewState result _ -> previewBox "Issue Preview"
    (renderPreviewResult (txt . candidateBlock) result)
    (previewControls result)
  IssueDueInputState issue form -> inputBox "Update Issue Due" form
    [ "Selected: " <> T.unpack (issueIdText (householdIssueId issue))
    , "Due: YYYY-MM-DD | none | ? (undetermined)."
    , "Only the due coordinate will change."
    , "[Enter] Preview   [Esc] Issues"
    ]
  IssueDuePreviewState _ result _ ->
    previewBox "Issue Due Preview"
      (renderPreviewResult renderIssueDuePreview result)
      (previewControls result)
  IssueCloseChoiceState issue ->
    center (borderWithLabel (str "Close Selected Issue")
      (hLimit 78 (padAll 1
        (renderIssue issue
          <=> str " "
          <=> str "[R] Resolve   [D] Drop   [Esc] Issues"))))
  IssueCloseInputState issue disposition form -> inputBox
    (case disposition of ResolveIssue -> "Resolve Issue"; DropIssue -> "Drop Issue")
    form
    [ "Selected: " <> T.unpack (issueIdText (householdIssueId issue))
    , "Closed: YYYY-MM-DD; blank uses today's entry date on the current schema."
    , "Older 8/9-column sources may close only with this field blank."
    , "[Tab] Next field   [Enter] Preview   [Esc] Back"
    ]
  IssueClosePreviewState _ _ result _ ->
    previewBox "Issue Close Preview"
      (renderPreviewResult renderIssueClosePreview result)
      (previewControls result)
  WriteOutcome message ->
    center (borderWithLabel (str "Maintenance Result")
      (hLimit 84 (padAll 1 (txt message <=> str " " <=> str "[Esc] Workspace   [Q] Quit"))))
  ReturnToWorkspace -> emptyWidget
  PublishRequested _ -> emptyWidget
  QuitRequested -> emptyWidget

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

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleFlowEvent context event = do
  state <- get
  case state of
    BudgetInputState form -> handleBudgetInput context form event
    BudgetPreviewState result form ->
      handlePreview (BudgetInputState form) PublishBudget result event
    AccountInputState form -> handleAccountInput context form event
    AccountPreviewState result form ->
      handlePreview (AccountInputState form) (uncurry PublishAccount) result event
    IssueAddInputState form -> handleIssueAddInput context form event
    IssueAddPreviewState result form ->
      handlePreview (IssueAddInputState form) PublishIssueAdd result event
    IssueDueInputState issue form -> handleIssueDueInput context issue form event
    IssueDuePreviewState issue result form ->
      handlePreview (IssueDueInputState issue form) PublishIssueDueUpdate result event
    IssueCloseChoiceState issue -> handleIssueCloseChoice context issue event
    IssueCloseInputState issue disposition form -> handleIssueCloseInput context issue disposition form event
    IssueClosePreviewState issue disposition result form ->
      handlePreview (IssueCloseInputState issue disposition form) PublishIssueClose result event
    WriteOutcome _ -> case event of
      VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
      VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
      VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
      _ -> pure ()
    ReturnToWorkspace -> pure ()
    PublishRequested _ -> pure ()
    QuitRequested -> pure ()

handleBudgetInput :: AppContext -> Form BudgetInput AppEvent Name -> BrickEvent Name AppEvent -> EventM Name (State AppEvent) ()
handleBudgetInput context form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KEnter []) -> case prepareBudget context (formState form) of
    Left message -> put (BudgetPreviewState (PreviewRejected message) form)
    Right preview -> put (BudgetPreviewState (PreviewReady preview) form)
  _ -> zoom zoomBudgetForm (handleFormEvent event)

handleAccountInput :: AppContext -> Form AccountInput AppEvent Name -> BrickEvent Name AppEvent -> EventM Name (State AppEvent) ()
handleAccountInput context form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KEnter []) -> case prepareAccountDeclaration (formState form) of
    Left message -> put (AccountPreviewState (PreviewRejected message) form)
    Right declaration ->
      let source = contextAccountsSource context
      in case prepareAccountJournalAppend source declaration of
        Left errors -> put (AccountPreviewState
          (PreviewRejected ("Account rejected: " <> T.pack (show (NonEmpty.toList errors)))) form)
        Right preview -> put (AccountPreviewState (PreviewReady (source, preview)) form)
  _ -> zoom zoomAccountForm (handleFormEvent event)

handleIssueAddInput :: AppContext -> Form IssueInput AppEvent Name -> BrickEvent Name AppEvent -> EventM Name (State AppEvent) ()
handleIssueAddInput context form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KEnter []) -> case prepareIssueAdd context (formState form) of
    Left message -> put (IssueAddPreviewState (PreviewRejected message) form)
    Right preview -> put (IssueAddPreviewState (PreviewReady preview) form)
  _ -> zoom zoomIssueForm (handleFormEvent event)

handleIssueDueInput
  :: AppContext
  -> HouseholdIssue
  -> Form IssueDueInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleIssueDueInput context issue form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KEnter []) ->
    case prepareSelectedIssueDueUpdate context issue (formState form) of
      Left message -> put (IssueDuePreviewState issue (PreviewRejected message) form)
      Right preview -> put (IssueDuePreviewState issue (PreviewReady preview) form)
  _ -> zoom zoomIssueDueForm (handleFormEvent event)

handleIssueCloseChoice
  :: AppContext
  -> HouseholdIssue
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleIssueCloseChoice _ issue event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey (V.KChar 'r') []) -> put (IssueCloseInputState issue ResolveIssue mkIssueCloseForm)
  VtyEvent (V.EvKey (V.KChar 'R') []) -> put (IssueCloseInputState issue ResolveIssue mkIssueCloseForm)
  VtyEvent (V.EvKey (V.KChar 'd') []) -> put (IssueCloseInputState issue DropIssue mkIssueCloseForm)
  VtyEvent (V.EvKey (V.KChar 'D') []) -> put (IssueCloseInputState issue DropIssue mkIssueCloseForm)
  _ -> pure ()

handleIssueCloseInput :: AppContext -> HouseholdIssue -> IssueCloseDisposition -> Form IssueCloseInput AppEvent Name -> BrickEvent Name AppEvent -> EventM Name (State AppEvent) ()
handleIssueCloseInput context issue disposition form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put (IssueCloseChoiceState issue)
  VtyEvent (V.EvKey V.KEnter []) ->
    case prepareSelectedIssueClose context issue disposition (formState form) of
      Left message -> put (IssueClosePreviewState issue disposition
        (PreviewRejected message) form)
      Right preview -> put (IssueClosePreviewState issue disposition (PreviewReady preview) form)
  _ -> zoom zoomIssueCloseForm (handleFormEvent event)

handlePreview
  :: State AppEvent
  -> (preview -> PublishRequest)
  -> PreviewResult preview
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handlePreview back toRequest result event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put back
  VtyEvent (V.EvKey V.KEnter []) -> case result of
    PreviewRejected _ -> pure ()
    PreviewReady preview -> put (PublishRequested (toRequest preview))
  VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
  _ -> pure ()

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

renderIssueDuePreview :: IssueDueUpdatePreview -> Widget Name
renderIssueDuePreview preview =
  txt (dueUpdateOriginalRow preview) <=> str " -> " <=> txt (dueUpdateCandidateRow preview)

renderIssueClosePreview :: IssueClosePreview -> Widget Name
renderIssueClosePreview preview =
  txt (closeOriginalRow preview) <=> str " -> " <=> txt (closeCandidateRow preview)

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
  "budget" -> Right Budget
  _ -> Left "Unknown Account type."

prepareIssueAdd :: AppContext -> IssueInput -> Either Text IssueAppendPreview
prepareIssueAdd context input = do
  recordedOn <- parseIssueDayInput
    (contextEntryDay context) "Recorded" (issueRecordedDateText input)
  issueId <- either (Left . showText) Right
    (generateAvailableIssueId
      recordedOn
      (map householdIssueId
        (householdStateIssues (contextHouseholdState context))))
  due <- parseIssueDueInput (issueDueText input)
  amount <- prepareOptionalAmount (issueAmountText input) (issueCommodityText input)
  let intent = IssueAppendIntent
        { intentIssueId = issueId
        , intentStatus = Open
        , intentDate = recordedOn
        , intentCategory = T.strip (issueCategoryText input)
        , intentTitle = T.strip (issueTitleText input)
        , intentAmount = amount
        , intentDetails = T.strip (issueDetailsText input)
        }
  case prepareIssueAppendWithDue (contextIssuesSource context) due intent of
    Left errors -> Left ("Issue rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview

prepareSelectedIssueDueUpdate
  :: AppContext
  -> HouseholdIssue
  -> IssueDueInput
  -> Either Text IssueDueUpdatePreview
prepareSelectedIssueDueUpdate context issue input = do
  due <- parseIssueDueInput (issueDueUpdateText input)
  let intent = IssueDueUpdateIntent
        { dueUpdateIssueId = householdIssueId issue
        , dueUpdateValue = due
        }
  case prepareIssueDueUpdate (contextIssuesSource context) intent of
    Left errors -> Left ("Issue due update rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview

prepareSelectedIssueClose
  :: AppContext
  -> HouseholdIssue
  -> IssueCloseDisposition
  -> IssueCloseInput
  -> Either Text IssueClosePreview
prepareSelectedIssueClose context issue disposition input =
  if householdIssueSourceUsesClosedColumn source
    then do
      closedOn <- parseIssueDayInput
        (contextEntryDay context) "Closed" rawClosed
      finish (prepareIssueCloseOn source closedOn intent)
    else if T.null rawClosed
      then finish (prepareIssueClose source intent)
      else Left
        "Issue close rejected: the current issues.tsv has no closed column; migrate the source before storing a close date."
  where
    source = contextIssuesSource context
    rawClosed = T.strip (issueClosedDateText input)
    intent = IssueCloseIntent
      { closeIssueId = householdIssueId issue
      , closeDisposition = disposition
      , closeDecisionMemo = issueDecisionMemoText input
      }
    finish result = case result of
      Left errors -> Left ("Issue close rejected: " <> showText (NonEmpty.toList errors))
      Right preview -> Right preview

parseIssueDayInput :: Day -> Text -> Text -> Either Text Day
parseIssueDayInput fallback label input
  | T.null value = Right fallback
  | otherwise = case parseTimeM True defaultTimeLocale "%F" (T.unpack value) of
      Just day -> Right day
      Nothing -> Left (label <> " must be YYYY-MM-DD.")
  where
    value = T.strip input

parseIssueDueInput :: Text -> Either Text IssueDue
parseIssueDueInput input = case T.toCaseFold (T.strip input) of
  "none" -> Right NoDueDate
  "?" -> Right DueUndetermined
  "undetermined" -> Right DueUndetermined
  value -> case parseTimeM True defaultTimeLocale "%F" (T.unpack value) of
    Just day -> Right (DueOn day)
    Nothing -> Left "Due must be YYYY-MM-DD, none, or ?."

renderIssueDueInput :: IssueDue -> Text
renderIssueDueInput due = case due of
  DueOn day -> T.pack (show day)
  NoDueDate -> "none"
  DueUndetermined -> "?"

renderIssueDueDisplay :: IssueDue -> Text
renderIssueDueDisplay due = case due of
  DueOn day -> "due " <> T.pack (show day)
  NoDueDate -> "no due date"
  DueUndetermined -> "due undetermined"

renderIssueClosedDisplay :: IssueClosed -> Text
renderIssueClosedDisplay closed = case closed of
  ClosedOn day -> "closed " <> T.pack (show day)
  NotClosed -> "open"
  ClosedUndetermined -> "closed date undetermined"

prepareOptionalAmount :: Text -> Text -> Either Text (Maybe Amount)
prepareOptionalAmount quantityText commodityText
  | T.null quantity && T.null commodity = Right Nothing
  | T.null quantity || T.null commodity = Left "Issue Amount and Commodity must both be blank or both be present."
  | otherwise = do
      parsedQuantity <- either (Left . showText) Right (parseQuantity quantity)
      parsedCommodity <- either (Left . showText) Right (mkCommodity commodity)
      Right (Just (mkAmount parsedCommodity parsedQuantity))
  where
    quantity = T.strip quantityText
    commodity = T.strip commodityText

publishCandidate :: AppContext -> PublishRequest -> IO PublishResult
publishCandidate context request = case request of
  PublishBudget preview ->
    publishAndReload BudgetSection
      (householdBudgetJournalPath paths)
      (contextBudgetSource context)
      (budgetJournalCandidateCompleteSource preview)
  PublishAccount source preview ->
    publishAndReload AccountsSection
      (householdAccountsJournalPath paths)
      source
      (accountCandidateCompleteSource preview)
  PublishIssueAdd preview ->
    publishAndReload IssuesSection
      (householdIssuesPath paths)
      (contextIssuesSource context)
      (candidateCompleteSource preview)
  PublishIssueDueUpdate preview ->
    publishAndReload IssuesSection
      (householdIssuesPath paths)
      (contextIssuesSource context)
      (dueUpdateCandidateCompleteSource preview)
  PublishIssueClose preview ->
    publishAndReload IssuesSection
      (householdIssuesPath paths)
      (contextIssuesSource context)
      (closeCandidateCompleteSource preview)
  where
    state = contextHouseholdState context
    paths = householdStatePaths state
    root = householdStateRoot state
    publishAndReload section path expected candidate = do
      result <- publishWithPathAdmission
        (\_ -> loadCanonicalHousehold root)
        WriteIntent
          { targetFilePath = path
          , expectedOldBytes = ExpectedSource expected
          , candidateNewBytes = CandidateSource candidate
          }
      case result of
        Left err -> pure (PublicationFailed (T.pack (show err)))
        Right () -> do
          reloaded <- reloadWorkspaceContext (context { contextCurrentSection = section })
          pure $ case reloaded of
            Nothing -> ReloadFailed
            Just fresh -> Published (fresh { contextCurrentSection = section })

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

renderAccountDecl :: AccountDeclaration -> Widget Name
renderAccountDecl declaration =
  txt (accountName (declaredAccount declaration) <> "  type: "
    <> T.pack (show (declaredAccountType declaration))
    <> maybe "" (\commodity -> "  default commodity: " <> commodityCode commodity)
      (declaredAccountDefaultCommodity declaration))

renderIssueItem :: Bool -> HouseholdIssue -> Widget Name
renderIssueItem selected issue
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    lifecycle = case householdIssueStatus issue of
      Open -> ""
      _ -> "  " <> renderIssueClosedDisplay (householdIssueClosed issue)
    row = txt ("[" <> T.pack (show (householdIssueStatus issue)) <> "]  "
      <> renderIssueDueDisplay (householdIssueDue issue) <> "  "
      <> T.pack (show (householdIssueRecordedOn issue)) <> "  "
      <> issueIdText (householdIssueId issue) <> "  "
      <> householdIssueText issue <> lifecycle)

renderSelectedIssue :: AppContext -> Widget Name
renderSelectedIssue context = case L.listSelectedElement (contextIssueList context) of
  Nothing -> str "No issues recorded."
  Just (_, issue) -> renderIssue issue

renderIssue :: HouseholdIssue -> Widget Name
renderIssue issue =
  vBox
    [ txt ("[" <> T.pack (show (householdIssueStatus issue)) <> "]  "
        <> T.pack (show (householdIssueRecordedOn issue))
        <> "  " <> issueIdText (householdIssueId issue))
    , txt ("Due: " <> renderIssueDueDisplay (householdIssueDue issue))
    , txt ("Closed: " <> renderIssueClosedDisplay (householdIssueClosed issue))
    , txt ("Text: " <> householdIssueText issue)
    , maybe emptyWidget
        (\amount -> txt ("Amount: " <> renderQuantity (amountQuantity amount)
          <> " " <> commodityCode (amountCommodity amount)))
        (householdIssueAmount issue)
    , txt ("Details: " <> householdIssueDetails issue)
    ]

showText :: Show value => value -> Text
showText = T.pack . show

data BudgetWorkspaceAction
  = BudgetActionMaintain
  | BudgetActionStartMovement
  deriving (Eq, Show)

handleBudgetWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name s BudgetWorkspaceAction
handleBudgetWorkspaceEvent event = case event of
  MouseDown BudgetViewport V.BScrollUp _ _ -> do
    vScrollBy (viewportScroll BudgetViewport) (-3)
    pure BudgetActionMaintain
  MouseDown BudgetViewport V.BScrollDown _ _ -> do
    vScrollBy (viewportScroll BudgetViewport) 3
    pure BudgetActionMaintain
  VtyEvent (V.EvKey V.KEnter []) -> pure BudgetActionStartMovement
  VtyEvent (V.EvKey (V.KChar 'm') []) -> pure BudgetActionStartMovement
  VtyEvent (V.EvKey (V.KChar 'M') []) -> pure BudgetActionStartMovement
  _ -> pure BudgetActionMaintain

data AccountsWorkspaceAction
  = AccountsActionMaintain
  | AccountsActionStartAdd
  deriving (Eq, Show)

handleAccountsWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name s AccountsWorkspaceAction
handleAccountsWorkspaceEvent event = case event of
  MouseDown AccountsViewport V.BScrollUp _ _ -> do
    vScrollBy (viewportScroll AccountsViewport) (-3)
    pure AccountsActionMaintain
  MouseDown AccountsViewport V.BScrollDown _ _ -> do
    vScrollBy (viewportScroll AccountsViewport) 3
    pure AccountsActionMaintain
  VtyEvent (V.EvKey V.KEnter []) -> pure AccountsActionStartAdd
  VtyEvent (V.EvKey (V.KChar 'a') []) -> pure AccountsActionStartAdd
  VtyEvent (V.EvKey (V.KChar 'A') []) -> pure AccountsActionStartAdd
  _ -> pure AccountsActionMaintain

data IssuesWorkspaceAction
  = IssuesActionMaintain
  | IssuesActionStartAdd
  | IssuesActionStartDueUpdate (State AppEvent)
  | IssuesActionStartClose (State AppEvent)

handleIssuesWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppContext IssuesWorkspaceAction
handleIssuesWorkspaceEvent event = case event of
  MouseDown IssueList V.BScrollUp _ _ -> do
    zoom contextIssueListL (L.handleListEvent (V.EvKey V.KUp []))
    pure IssuesActionMaintain
  MouseDown IssueList V.BScrollDown _ _ -> do
    zoom contextIssueListL (L.handleListEvent (V.EvKey V.KDown []))
    pure IssuesActionMaintain
  MouseDown IssueList V.BLeft _ (Location (_, row)) -> do
    zoom contextIssueListL (modify (L.listMoveTo row))
    pure IssuesActionMaintain
  VtyEvent (V.EvKey (V.KChar 'a') []) -> pure IssuesActionStartAdd
  VtyEvent (V.EvKey (V.KChar 'A') []) -> pure IssuesActionStartAdd
  VtyEvent (V.EvKey (V.KChar 'u') []) -> openSelectedIssueDueUpdate
  VtyEvent (V.EvKey (V.KChar 'U') []) -> openSelectedIssueDueUpdate
  VtyEvent (V.EvKey V.KEnter []) -> openSelectedIssueClose
  VtyEvent (V.EvKey vtyKey vtyMods) -> do
    zoom contextIssueListL (L.handleListEventVi L.handleListEvent (V.EvKey vtyKey vtyMods))
    pure IssuesActionMaintain
  _ -> pure IssuesActionMaintain
  where
    openSelectedIssueClose = do
      context <- get
      case startSelectedIssueClose context of
        Nothing -> pure IssuesActionMaintain
        Just flow -> pure (IssuesActionStartClose flow)
    openSelectedIssueDueUpdate = do
      context <- get
      case startSelectedIssueDueUpdate context of
        Nothing -> pure IssuesActionMaintain
        Just flow -> pure (IssuesActionStartDueUpdate flow)
