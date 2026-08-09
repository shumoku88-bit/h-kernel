{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module HKernel.Editor.TUI.Maintenance
  ( PublishRequest(..)
  , PublishResult(..)
  , State(..)
  , drawAccountsWorkspace
  , drawBudgetWorkspace
  , drawIssuesWorkspace
  , drawFlow
  , handleFlowEvent
  , publishCandidate
  , startAccountAdd
  , startBudgetMovement
  , startIssueAdd
  , startSelectedIssueClose
  ) where

import Brick
import Brick.Forms
import Brick.Widgets.Border
import Brick.Widgets.Center
import qualified Brick.Widgets.List as L
import Control.Monad.IO.Class (liftIO)
import qualified Graphics.Vty as V
import Lens.Micro (Lens', Traversal')

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.IO.Error (tryIOError)

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
import HKernel.Budget.Policy
  ( EnvelopeDefinition
  , budgetPolicyEnvelopeDefinitions
  , envelopeDefinitionExpenseAccounts
  , envelopeDefinitionId
  )
import HKernel.Editor.ActualAccountAppend
  ( AccountJournalAppendPreview(..)
  , prepareAccountJournalAppend
  )
import HKernel.Editor.ActualWriter
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteIntent(..)
  , publishWithPathAdmission
  )
import HKernel.Editor.BudgetMovementAppend
  ( BudgetJournalMovementAppendPreview(..)
  , prepareBudgetJournalMovementAppend
  )
import HKernel.Editor.IssueAppend
  ( IssueAppendIntent(..)
  , IssueAppendPreview(..)
  , IssueCloseDisposition(..)
  , IssueCloseIntent(..)
  , IssueClosePreview(..)
  , prepareIssueAppend
  , prepareIssueClose
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , HouseholdSection(..)
  , Name(..)
  , reloadWorkspaceContext
  )
import HKernel.Household.Application
  ( HouseholdState(..)
  , loadCanonicalHousehold
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueId
  , IssueStatus(..)
  , householdIssueAmount
  , householdIssueDetails
  , householdIssueId
  , householdIssueRecordedOn
  , householdIssueStatus
  , householdIssueText
  , issueIdText
  , mkIssueId
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
  { issueCategoryText  :: Text
  , issueTitleText     :: Text
  , issueAmountText    :: Text
  , issueCommodityText :: Text
  , issueDetailsText   :: Text
  } deriving (Eq, Show)

data IssueCloseInput = IssueCloseInput
  { issueDecisionMemoText :: Text
  } deriving (Eq, Show)

data State event
  = BudgetInputState (Form BudgetInput event Name)
  | BudgetPreviewState BudgetJournalMovementAppendPreview (Form BudgetInput event Name)
  | AccountInputState (Form AccountInput event Name)
  | AccountPreviewState Text AccountJournalAppendPreview (Form AccountInput event Name)
  | IssueAddInputState (Form IssueInput event Name)
  | IssueAddPreviewState IssueAppendPreview (Form IssueInput event Name)
  | IssueCloseChoiceState HouseholdIssue
  | IssueCloseInputState HouseholdIssue IssueCloseDisposition (Form IssueCloseInput event Name)
  | IssueClosePreviewState HouseholdIssue IssueCloseDisposition IssueClosePreview (Form IssueCloseInput event Name)
  | WriteOutcome Text
  | ReturnToWorkspace
  | PublishRequested PublishRequest
  | QuitRequested

data PublishRequest
  = PublishBudget BudgetJournalMovementAppendPreview
  | PublishAccount Text AccountJournalAppendPreview
  | PublishIssueAdd IssueAppendPreview
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

issueCategoryL :: Lens' IssueInput Text
issueCategoryL f input = (\value -> input { issueCategoryText = value }) <$> f (issueCategoryText input)

issueTitleL :: Lens' IssueInput Text
issueTitleL f input = (\value -> input { issueTitleText = value }) <$> f (issueTitleText input)

issueAmountL :: Lens' IssueInput Text
issueAmountL f input = (\value -> input { issueAmountText = value }) <$> f (issueAmountText input)

issueCommodityL :: Lens' IssueInput Text
issueCommodityL f input = (\value -> input { issueCommodityText = value }) <$> f (issueCommodityText input)

issueDetailsL :: Lens' IssueInput Text
issueDetailsL f input = (\value -> input { issueDetailsText = value }) <$> f (issueDetailsText input)

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
    [ labelField "Category:" @@= editTextField issueCategoryL IssueCategoryField (Just 1)
    , labelField "Title:" @@= editTextField issueTitleL IssueTitleField (Just 1)
    , labelField "Amount:" @@= editTextField issueAmountL IssueAmountField (Just 1)
    , labelField "Commodity:" @@= editTextField issueCommodityL IssueCommodityField (Just 1)
    , labelField "Details:" @@= editTextField issueDetailsL IssueDetailsField (Just 1)
    ]
    (IssueInput "general" "" "" "" "")

mkIssueCloseForm :: Form IssueCloseInput event Name
mkIssueCloseForm =
  newForm
    [ labelField "Decision memo:" @@= editTextField issueDecisionMemoL IssueDecisionMemoField (Just 1)
    ]
    (IssueCloseInput "")

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

zoomBudgetForm :: Traversal' (State AppEvent) (Form BudgetInput AppEvent Name)
zoomBudgetForm f (BudgetInputState form) = BudgetInputState <$> f form
zoomBudgetForm _ state = pure state

zoomAccountForm :: Traversal' (State AppEvent) (Form AccountInput AppEvent Name)
zoomAccountForm f (AccountInputState form) = AccountInputState <$> f form
zoomAccountForm _ state = pure state

zoomIssueForm :: Traversal' (State AppEvent) (Form IssueInput AppEvent Name)
zoomIssueForm f (IssueAddInputState form) = IssueAddInputState <$> f form
zoomIssueForm _ state = pure state

zoomIssueCloseForm :: Traversal' (State AppEvent) (Form IssueCloseInput AppEvent Name)
zoomIssueCloseForm f (IssueCloseInputState issue disposition form) =
  IssueCloseInputState issue disposition <$> f form
zoomIssueCloseForm _ state = pure state

drawBudgetWorkspace :: AppContext -> Widget Name
drawBudgetWorkspace context =
  vBox
    [ borderWithLabel (str "Budget Movements & Policy (budget.journal)")
        (vLimit 18
          (viewport BudgetViewport Vertical
            (vBox
              [ str "--- Budget Movements ---"
              , vBox (map renderBudgetMovement (householdStateBudgetMovements state))
              , str " "
              , str "--- Spendable Envelopes ---"
              , vBox (map renderEnvelopeDef
                  (budgetPolicyEnvelopeDefinitions (householdStateBudgetPolicy state)))
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
    , str "[j/k/Arrows] Move   [Enter] Resolve/Drop   [A] Add Issue   [1-7] Sections   [q] Quit"
    ]

drawFlow :: State AppEvent -> Widget Name
drawFlow state = case state of
  BudgetInputState form -> inputBox "New Budget Movement" form
    [ "Both Accounts must be canonical Budget Accounts."
    , "[Tab] Next field   [Enter] Preview   [Esc] Budget"
    ]
  BudgetPreviewState preview _ -> previewBox "Budget Movement Preview"
    (txt (budgetJournalCandidateBlock preview))
  AccountInputState form -> inputBox "Add Account" form
    [ "Type: asset | liability | equity | income | expense | budget"
    , "Commodity may be blank when no default is required."
    , "[Tab] Next field   [Enter] Preview   [Esc] Accounts"
    ]
  AccountPreviewState _ preview _ -> previewBox "Account Preview"
    (txt (accountCandidateBlock preview))
  IssueAddInputState form -> inputBox "Add Household Issue" form
    [ "Issue identity is generated from the current Household observation."
    , "Leave both Amount and Commodity blank for a non-monetary Issue."
    , "[Tab] Next field   [Enter] Preview   [Esc] Issues"
    ]
  IssueAddPreviewState preview _ -> previewBox "Issue Preview"
    (txt (candidateBlock preview))
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
    , "[Tab] Next field   [Enter] Preview   [Esc] Back"
    ]
  IssueClosePreviewState _ _ preview _ ->
    previewBox "Issue Close Preview"
      (txt (closeOriginalRow preview) <=> str " -> " <=> txt (closeCandidateRow preview))
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

previewBox :: String -> Widget Name -> Widget Name
previewBox title body =
  center
    (borderWithLabel (str title)
      (hLimit 88
        (vLimit 32
          (padAll 1
            (body <=> str " " <=> str "[Enter] Publish   [Esc] Back   [Q] Quit")))))

handleFlowEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name (State AppEvent) ()
handleFlowEvent context event = do
  state <- get
  case state of
    BudgetInputState form -> handleBudgetInput context form event
    BudgetPreviewState preview form -> handlePreview (BudgetInputState form) (PublishBudget preview) event
    AccountInputState form -> handleAccountInput context form event
    AccountPreviewState source preview form -> handlePreview (AccountInputState form) (PublishAccount source preview) event
    IssueAddInputState form -> handleIssueAddInput context form event
    IssueAddPreviewState preview form -> handlePreview (IssueAddInputState form) (PublishIssueAdd preview) event
    IssueCloseChoiceState issue -> handleIssueCloseChoice issue event
    IssueCloseInputState issue disposition form -> handleIssueCloseInput context issue disposition form event
    IssueClosePreviewState issue disposition preview form ->
      handlePreview (IssueCloseInputState issue disposition form) (PublishIssueClose preview) event
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
    Left message -> put (WriteOutcome message)
    Right preview -> put (BudgetPreviewState preview form)
  _ -> zoom zoomBudgetForm (handleFormEvent event)

handleAccountInput :: AppContext -> Form AccountInput AppEvent Name -> BrickEvent Name AppEvent -> EventM Name (State AppEvent) ()
handleAccountInput context form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KEnter []) -> case prepareAccountDeclaration (formState form) of
    Left message -> put (WriteOutcome message)
    Right declaration -> do
      let paths = householdStatePaths (contextHouseholdState context)
      sourceResult <- liftIO (tryIOError (TIO.readFile (householdAccountsJournalPath paths)))
      case sourceResult of
        Left err -> put (WriteOutcome ("Cannot read accounts.journal: " <> T.pack (show err)))
        Right source -> case prepareAccountJournalAppend source declaration of
          Left errors -> put (WriteOutcome ("Account rejected: " <> T.pack (show (NonEmpty.toList errors))))
          Right preview -> put (AccountPreviewState source preview form)
  _ -> zoom zoomAccountForm (handleFormEvent event)

handleIssueAddInput :: AppContext -> Form IssueInput AppEvent Name -> BrickEvent Name AppEvent -> EventM Name (State AppEvent) ()
handleIssueAddInput context form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put ReturnToWorkspace
  VtyEvent (V.EvKey V.KEnter []) -> case prepareIssueAdd context (formState form) of
    Left message -> put (WriteOutcome message)
    Right preview -> put (IssueAddPreviewState preview form)
  _ -> zoom zoomIssueForm (handleFormEvent event)

handleIssueCloseChoice :: HouseholdIssue -> BrickEvent Name AppEvent -> EventM Name (State AppEvent) ()
handleIssueCloseChoice issue event = case event of
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
    let intent = IssueCloseIntent
          { closeIssueId = householdIssueId issue
          , closeDisposition = disposition
          , closeDecisionMemo = issueDecisionMemoText (formState form)
          }
    in case prepareIssueClose (contextIssuesSource context) intent of
      Left errors -> put (WriteOutcome ("Issue close rejected: " <> T.pack (show (NonEmpty.toList errors))))
      Right preview -> put (IssueClosePreviewState issue disposition preview form)
  _ -> zoom zoomIssueCloseForm (handleFormEvent event)

handlePreview :: State AppEvent -> PublishRequest -> BrickEvent Name AppEvent -> EventM Name (State AppEvent) ()
handlePreview back publishRequest event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put back
  VtyEvent (V.EvKey V.KEnter []) -> put (PublishRequested publishRequest)
  VtyEvent (V.EvKey (V.KChar 'q') []) -> put QuitRequested
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> put QuitRequested
  _ -> pure ()

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
      registry = householdStateAccountsRegistry (contextHouseholdState context)
  case prepareBudgetJournalMovementAppend registry (contextBudgetSource context) movement of
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
  issueId <- suggestIssueId context
  amount <- prepareOptionalAmount (issueAmountText input) (issueCommodityText input)
  let intent = IssueAppendIntent
        { intentIssueId = issueId
        , intentStatus = Open
        , intentDate = contextEntryDay context
        , intentCategory = T.strip (issueCategoryText input)
        , intentTitle = T.strip (issueTitleText input)
        , intentAmount = amount
        , intentDetails = T.strip (issueDetailsText input)
        }
  case prepareIssueAppend (contextIssuesSource context) intent of
    Left errors -> Left ("Issue rejected: " <> showText (NonEmpty.toList errors))
    Right preview -> Right preview

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

suggestIssueId :: AppContext -> Either Text IssueId
suggestIssueId context = go (1 :: Int)
  where
    dayText = T.filter (/= '-') (T.pack (show (contextEntryDay context)))
    existing = Set.fromList
      (map (issueIdText . householdIssueId)
        (householdStateIssues (contextHouseholdState context)))
    go index =
      let candidateText = "ISS" <> dayText <> "-" <> T.pack (show index)
      in if candidateText `Set.member` existing
          then go (index + 1)
          else case mkIssueId candidateText of
            Left err -> Left (showText err)
            Right value -> Right value

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
  txt ("Envelope: " <> T.pack (show (envelopeDefinitionId definition))
    <> "  Expenses: "
    <> T.intercalate ", " (map accountName (envelopeDefinitionExpenseAccounts definition)))

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
    row = txt ("[" <> T.pack (show (householdIssueStatus issue)) <> "]  "
      <> T.pack (show (householdIssueRecordedOn issue)) <> "  "
      <> issueIdText (householdIssueId issue) <> "  "
      <> householdIssueText issue)

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
    , txt ("Text: " <> householdIssueText issue)
    , maybe emptyWidget
        (\amount -> txt ("Amount: " <> renderQuantity (amountQuantity amount)
          <> " " <> commodityCode (amountCommodity amount)))
        (householdIssueAmount issue)
    , txt ("Details: " <> householdIssueDetails issue)
    ]

showText :: Show value => value -> Text
showText = T.pack . show
