{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

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

import Control.Exception (try)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day, addDays)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import qualified Data.Vector as Vec
import System.Directory (doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeDirectory)
import System.IO.Error (tryIOError)
import Text.Read (readMaybe)

import HKernel.Account
  ( Account
  , AccountDeclaration
  , accountDeclarations
  , accountName
  , declaredAccount
  , declaredAccountDefaultCommodity
  , declaredAccountType
  )
import HKernel.Actual.Journal (actualJournalValue)
import HKernel.Application.Config (HouseholdSourcePaths(..), mkHouseholdRoot)
import HKernel.Budget.Policy (EnvelopeDefinition, budgetPolicyEnvelopeDefinitions, envelopeDefinitionExpenseAccounts, envelopeDefinitionId)
import HKernel.Engine (mkDateRange)
import HKernel.Editor.ActualAppend
  ( ActualAddInput(..)
  , ActualAddPreview(..)
  , ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , classifyActualAddWriteResult
  , prepareActualAddPreviewFromResolvedJournal
  )
import HKernel.Editor.ActualWorkspace (transactionsForAccount)
import HKernel.Editor.ActualWriter (publishActualBlockFromResolvedJournal)
import HKernel.Editor.Interaction.ActualAdd
  ( AccountSelectionTarget(..)
  , ActualAddAction(..)
  , ActualAddMode(..)
  , ActualAddState(..)
  , dailyAccountCandidates
  , enterActualAddPreview
  , initialActualAddStateForDay
  , setActualAddDate
  , transitionActualAdd
  )
import HKernel.Household.Application
  ( HouseholdState(..)
  , buildHouseholdReportSurfaceFromHousehold
  , loadCanonicalHousehold
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.Policy (householdAllocationEnvelopes, householdCycleIncomeAccount, householdPolicyCycle, householdUnassignedBudgetAccounts)
import HKernel.HouseholdIssue (HouseholdIssue(..))
import HKernel.Journal (journalTransactions)
import HKernel.Ledger
  ( Posting
  , Transaction
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
import HKernel.Plan
  ( CommittedOutgoingPlan
  , committedPlanAmount
  , committedPlanDate
  , committedPlanDirection
  , committedPlanId
  , committedPlanMemo
  , declaredOutgoingPaymentDirection
  , declaredPaymentDestination
  , declaredPaymentSource
  , planIdText
  , positiveAmountValue
  )
import HKernel.Render
  ( renderBalanceSheetWithPresentation
  , renderDailyFlowWithPresentation
  , renderMonthlyAccountsWithPresentation
  , renderProfitAndLossWithPresentation
  , renderRecentTransactionsWithPresentation
  , renderTrialBalanceWithPresentation
  )
import HKernel.Report (balanceSheetAsOf, dailyFlow, defaultRecentCount, monthlyAccounts, profitAndLoss, recentTransactions, reportBook, trialBalanceAsOf)
import HKernel.Report.Config (reportConfigurationPlan, reportConfigurationPresentation)
import HKernel.Spike.HouseholdReport (HouseholdReportSurface(..))
import HKernel.Spike.HouseholdReport.Render (renderReportBookWithHouseholdPresentation)

data Name
  = DateField
  | DescriptionField
  | FromAccountField
  | ToAccountField
  | AmountField
  | AccountList
  | WorkspaceAccountList
  | WorkspaceTransactionList
  | PlansViewport
  | BudgetViewport
  | AccountsViewport
  | IssuesViewport
  | ReportsViewport
  | SettingsViewport
  deriving (Eq, Ord, Show)

data WorkspaceFocus
  = AccountsFocus
  | TransactionsFocus
  deriving (Eq, Show)

data HouseholdSection
  = ActualSection
  | PlansSection
  | BudgetSection
  | AccountsSection
  | IssuesSection
  | ReportsSection
  | SettingsSection
  deriving (Eq, Ord, Show, Enum, Bounded)

data ReportChoice
  = ReportTrialBalance
  | ReportBalanceSheet
  | ReportProfitAndLoss
  | ReportDailyFlow
  | ReportMonthlyAccounts
  | ReportCycleAccounts
  | ReportRecentTransactions
  | ReportCombinedBook
  deriving (Eq, Ord, Show, Enum, Bounded)

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
  = Workspace
  | InputForm (Form ActualAddInput event Name)
  | SelectAccount
      AccountSelectionTarget
      (L.List Name Account)
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
  | ShowWorkspaceReloadFailure

data AppContext = AppContext
  { contextHouseholdState       :: HouseholdState
  , contextCurrentSection       :: HouseholdSection
  , contextSelectedReport       :: ReportChoice
  , contextObservationDay       :: Day
  , contextEntryDay             :: Day
  , contextAccounts             :: [Account]
  , contextWorkspaceAccounts    :: L.List Name (Maybe Account)
  , contextAllTransactions      :: [Transaction]
  , contextWorkspaceList        :: L.List Name Transaction
  , contextWorkspaceFocus       :: WorkspaceFocus
  , contextSourcePath           :: FilePath
  , contextSource               :: Text
  }

data AppWrapper = AppWrapper AppContext (UIState AppEvent)

type AppEvent = ()

mkForm :: ActualAddInput -> Form ActualAddInput event Name
mkForm =
  let label labelText widget =
        padBottom (Pad 1)
          ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)
  in newForm
      [ label "Amount:"
          @@= editTextField addAmountTextL AmountField (Just 1)
      , label "Description:"
          @@= editTextField addDescriptionTextL DescriptionField (Just 1)
      , label "Category:"
          @@= editTextField addToAccountTextL ToAccountField (Just 1)
      , label "Pay from:"
          @@= editTextField addFromAccountTextL FromAccountField (Just 1)
      , label "Date (other):"
          @@= editTextField addDateTextL DateField (Just 1)
      ]

mkDailyForm :: Day -> Form ActualAddInput event Name
mkDailyForm day =
  setFormFocus AmountField
    (mkForm (actualAddInput (initialActualAddStateForDay day)))

zoomForm :: Traversal' AppWrapper (Form ActualAddInput AppEvent Name)
zoomForm f (AppWrapper context (InputForm form)) =
  (\updated -> AppWrapper context (InputForm updated)) <$> f form
zoomForm _ wrapper = pure wrapper

zoomList :: Traversal' AppWrapper (L.List Name Account)
zoomList f (AppWrapper context (SelectAccount target accountList form)) =
  (\updated -> AppWrapper context (SelectAccount target updated form))
    <$> f accountList
zoomList _ wrapper = pure wrapper

zoomWorkspaceAccounts :: Traversal' AppWrapper (L.List Name (Maybe Account))
zoomWorkspaceAccounts f (AppWrapper context Workspace) =
  (\updated ->
      AppWrapper
        (context { contextWorkspaceAccounts = updated })
        Workspace)
    <$> f (contextWorkspaceAccounts context)
zoomWorkspaceAccounts _ wrapper = pure wrapper

zoomWorkspaceList :: Traversal' AppWrapper (L.List Name Transaction)
zoomWorkspaceList f (AppWrapper context Workspace) =
  (\updated ->
      AppWrapper
        (context { contextWorkspaceList = updated })
        Workspace)
    <$> f (contextWorkspaceList context)
zoomWorkspaceList _ wrapper = pure wrapper

drawUI :: AppWrapper -> [Widget Name]
drawUI (AppWrapper context Workspace) =
  [ drawHouseholdShell context ]
drawUI (AppWrapper context (InputForm form)) =
  [ center
      (borderWithLabel (str "Daily Actual")
        (padAll 1
          (vBox
            [ txt ("Date: " <> entryDateSummary context (formState form))
            , str "Amount accepts a quantity only when Account defaults determine the commodity."
            , str " "
            , renderForm form
            , str " "
            , str "[Ctrl-T] Today | [Ctrl-Y] Yesterday | [Ctrl-D] Other date"
            , str "[F2/Ctrl-F] Payment account | [F3/Ctrl-E] Expense category"
            , str "[Esc] Workspace | [Enter] Preview"
            ])))
  ]
drawUI (AppWrapper _ (SelectAccount target accountList _)) =
  [ center
      (borderWithLabel (str (selectionLabel target))
        (hLimit 56
          (vLimit 15
            (L.renderList renderAccount True accountList
              <=> str " "
              <=> str "Recent matching Accounts are shown first."
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
drawUI (AppWrapper _ ShowWorkspaceReloadFailure) =
  [ center
      (borderWithLabel (str "Actual workspace reload")
        (padAll 1
          (withAttr (attrName "error")
            (vBox
              [ str "The Actual write succeeded, but the workspace could not reload the source."
              , str "No source-local error detail is retained in the TUI state."
              , str "Restart the TUI before continuing."
              , str " "
              , str "[Esc/Q] Quit"
              ]))))
  ]

entryDateSummary :: AppContext -> ActualAddInput -> Text
entryDateSummary context input
  | addDateText input == T.pack (show today) =
      "Today  " <> addDateText input
  | addDateText input == T.pack (show yesterday) =
      "Yesterday  " <> addDateText input
  | otherwise = "Other  " <> addDateText input
  where
    today = contextObservationDay context
    yesterday = addDays (-1) today

drawHouseholdShell :: AppContext -> Widget Name
drawHouseholdShell context =
  vBox
    [ drawSectionTabBar (contextCurrentSection context)
    , drawSectionBody context
    ]

drawSectionTabBar :: HouseholdSection -> Widget Name
drawSectionTabBar currentSection =
  borderWithLabel (str "h-kernel Household")
    (hBox (map renderTab [minBound .. maxBound]))
  where
    renderTab section
      | section == currentSection =
          withAttr (attrName "activeTab") (str (" [" <> sectionNum section <> ": " <> sectionName section <> "] "))
      | otherwise =
          str ("  " <> sectionNum section <> ": " <> sectionName section <> "  ")

    sectionNum ActualSection   = "1"
    sectionNum PlansSection    = "2"
    sectionNum BudgetSection   = "3"
    sectionNum AccountsSection = "4"
    sectionNum IssuesSection   = "5"
    sectionNum ReportsSection  = "6"
    sectionNum SettingsSection = "7"

    sectionName ActualSection   = "Actual"
    sectionName PlansSection    = "Plans"
    sectionName BudgetSection   = "Budget"
    sectionName AccountsSection = "Accounts"
    sectionName IssuesSection   = "Issues"
    sectionName ReportsSection  = "Reports"
    sectionName SettingsSection = "Settings"

drawSectionBody :: AppContext -> Widget Name
drawSectionBody context = case contextCurrentSection context of
  ActualSection   -> drawWorkspace context
  PlansSection    -> drawPlansView context
  BudgetSection   -> drawBudgetView context
  AccountsSection -> drawAccountsView context
  IssuesSection   -> drawIssuesView context
  ReportsSection  -> drawReportsView context
  SettingsSection -> drawSettingsView context

drawWorkspace :: AppContext -> Widget Name
drawWorkspace context =
  vBox
    [ hBox
        [ hLimit 30
            (borderWithLabel
              (workspacePaneLabel context AccountsFocus "Accounts")
              (vLimit 16
                (L.renderList
                  renderWorkspaceAccount
                  (contextWorkspaceFocus context == AccountsFocus)
                  (contextWorkspaceAccounts context))))
        , padLeft (Pad 1)
            (padRight Max
              (borderWithLabel
                (workspacePaneLabel context TransactionsFocus "Transactions")
                (vLimit 16
                  (L.renderList
                    renderWorkspaceTransaction
                    (contextWorkspaceFocus context == TransactionsFocus)
                    (contextWorkspaceList context)))))
        ]
    , borderWithLabel (str "Selected transaction")
        (padAll 1 (renderWorkspaceSelection context))
    , txt ("Filter: " <> workspaceFilterText context)
    , str "[1-7] Sections   [Tab/Left/Right] Focus   [j/k/Arrows] Move   [a] Daily Actual   [q] Quit"
    ]

drawPlansView :: AppContext -> Widget Name
drawPlansView context =
  vBox
    [ borderWithLabel (str "Planned Transactions (plan.journal)")
        (vLimit 18
          (viewport PlansViewport Vertical
            (vBox (map renderPlan plans))))
    , str "[1-7] Switch section   [q] Quit"
    ]
  where
    plans = case buildHouseholdReportSurfaceFromHousehold (contextObservationDay context) (contextHouseholdState context) of
      Right surface -> householdPlannedTransactions surface
      Left _ -> []

renderPlan :: CommittedOutgoingPlan -> Widget Name
renderPlan plan =
  padBottom (Pad 1)
    (vBox
      [ txt (T.pack (show (committedPlanDate plan)) <> "  [" <> planIdText (committedPlanId plan) <> "]  " <> committedPlanMemo plan)
      , txt ("  From: " <> accountName (declaredAccount (declaredPaymentSource dir)) <> "  To: " <> accountName (declaredAccount (declaredPaymentDestination dir)) <> "  " <> renderQuantity (amountQuantity amount) <> " " <> commodityCode (amountCommodity amount))
      ])
  where
    dir = declaredOutgoingPaymentDirection (committedPlanDirection plan)
    amount = positiveAmountValue (committedPlanAmount plan)

drawBudgetView :: AppContext -> Widget Name
drawBudgetView context =
  vBox
    [ borderWithLabel (str "Budget Movements & Policy (budget.journal)")
        (vLimit 18
          (viewport BudgetViewport Vertical
            (vBox
              [ str "--- Budget Movements ---"
              , vBox (map renderBudgetMovement (householdStateBudgetMovements state))
              , str " "
              , str "--- Spendable Envelopes ---"
              , vBox (map renderEnvelopeDef (budgetPolicyEnvelopeDefinitions (householdStateBudgetPolicy state)))
              ])))
    , str "[1-7] Switch section   [q] Quit"
    ]
  where
    state = contextHouseholdState context

renderBudgetMovement :: HouseholdBudgetMovement -> Widget Name
renderBudgetMovement m =
  txt (T.pack (show (householdBudgetMovementDate m)) <> "  " <> householdBudgetMovementMemo m
        <> "  " <> accountName (householdBudgetMovementFrom m) <> " -> " <> accountName (householdBudgetMovementTo m)
        <> "  " <> renderQuantity (amountQuantity (householdBudgetMovementAmount m)) <> " " <> commodityCode (amountCommodity (householdBudgetMovementAmount m)))

renderEnvelopeDef :: EnvelopeDefinition -> Widget Name
renderEnvelopeDef ed =
  txt ("Envelope: " <> T.pack (show (envelopeDefinitionId ed)) <> "  Expenses: " <> T.intercalate ", " (map accountName (envelopeDefinitionExpenseAccounts ed)))

drawAccountsView :: AppContext -> Widget Name
drawAccountsView context =
  vBox
    [ borderWithLabel (str "Canonical Account Declarations (accounts.journal)")
        (vLimit 18
          (viewport AccountsViewport Vertical
            (vBox (map renderAccountDecl (accountDeclarations (householdStateAccountsRegistry (contextHouseholdState context)))))))
    , str "[1-7] Switch section   [q] Quit"
    ]

renderAccountDecl :: AccountDeclaration -> Widget Name
renderAccountDecl decl =
  txt (accountName (declaredAccount decl) <> "  type: " <> T.pack (show (declaredAccountType decl))
        <> maybe "" (\c -> "  default commodity: " <> commodityCode c) (declaredAccountDefaultCommodity decl))

drawIssuesView :: AppContext -> Widget Name
drawIssuesView context =
  vBox
    [ borderWithLabel (str "Household Notebook (issues.tsv)")
        (vLimit 18
          (viewport IssuesViewport Vertical
            (if null issues
               then str "No issues recorded."
               else vBox (map renderIssue issues))))
    , str "[1-7] Switch section   [q] Quit"
    ]
  where
    issues = householdStateIssues (contextHouseholdState context)

renderIssue :: HouseholdIssue -> Widget Name
renderIssue issue =
  padBottom (Pad 1)
    (vBox
      [ txt ("[" <> T.pack (show (householdIssueStatus issue)) <> "]  " <> T.pack (show (householdIssueRecordedOn issue)) <> "  Due: " <> T.pack (show (householdIssueDue issue)))
      , txt ("  Text: " <> householdIssueText issue)
      , maybe emptyWidget (\amt -> txt ("  Amount: " <> renderQuantity (amountQuantity amt) <> " " <> commodityCode (amountCommodity amt))) (householdIssueAmount issue)
      , txt ("  Details: " <> householdIssueDetails issue)
      ])

drawReportsView :: AppContext -> Widget Name
drawReportsView context =
  vBox
    [ borderWithLabel (str ("Household Report: " <> show (contextSelectedReport context)))
        (vLimit 18
          (viewport ReportsViewport Vertical (renderSelectedReport context)))
    , txt ("Active report: " <> T.pack (show (contextSelectedReport context)) <> "  |  Press [r] to cycle reports")
    , str "[1-7] Switch section   [r] Cycle Report   [q] Quit"
    ]

renderSelectedReport :: AppContext -> Widget Name
renderSelectedReport context = case contextSelectedReport context of
  ReportTrialBalance ->
    txt (renderTrialBalanceWithPresentation pres (trialBalanceAsOf day journal))
  ReportBalanceSheet ->
    txt (renderBalanceSheetWithPresentation pres (balanceSheetAsOf day journal))
  ReportProfitAndLoss ->
    txt (renderProfitAndLossWithPresentation pres (profitAndLoss (defaultDateRange day) journal))
  ReportDailyFlow ->
    txt (renderDailyFlowWithPresentation pres (dailyFlow (defaultDateRange day) journal))
  ReportMonthlyAccounts ->
    txt (renderMonthlyAccountsWithPresentation pres (monthlyAccounts (defaultDateRange day) journal))
  ReportCycleAccounts ->
    case buildHouseholdReportSurfaceFromHousehold day state of
      Left err -> txt ("Report surface error: " <> T.pack (show err))
      Right surface -> txt (renderReportBookWithHouseholdPresentation pres (reportBook (defaultDateRange day) journal) surface)
  ReportRecentTransactions ->
    txt (renderRecentTransactionsWithPresentation pres (recentTransactions defaultRecentCount day journal))
  ReportCombinedBook ->
    case buildHouseholdReportSurfaceFromHousehold day state of
      Left err -> txt ("Report surface error: " <> T.pack (show err))
      Right surface ->
        txt (renderReportBookWithHouseholdPresentation pres (reportBook (defaultDateRange day) journal) surface)
  where
    state = contextHouseholdState context
    day = contextObservationDay context
    journal = actualJournalValue (householdStateActualJournal state)
    pres = reportConfigurationPresentation (householdStateReportConfig state)
    defaultDateRange d = case mkDateRange d d of
      Right r -> r
      Left _ -> error "unreachable date range"

drawSettingsView :: AppContext -> Widget Name
drawSettingsView context =
  vBox
    [ borderWithLabel (str "Household Settings & Policy")
        (vLimit 18
          (viewport SettingsViewport Vertical
            (vBox
              [ str "=== [budget.toml] Budget Policy ==="
              , str ("Envelopes count: " <> show (length (budgetPolicyEnvelopeDefinitions (householdStateBudgetPolicy state))))
              , str " "
              , str "=== [household.toml] Household Policy ==="
              , txt ("Income Cycle Account: " <> accountName (householdCycleIncomeAccount (householdPolicyCycle (householdStatePolicy state))))
              , txt ("Allocation Envelopes: " <> T.pack (show (householdAllocationEnvelopes (householdStatePolicy state))))
              , txt ("Unassigned Accounts: " <> T.intercalate ", " (map accountName (Set.toAscList (householdUnassignedBudgetAccounts (householdStatePolicy state)))))
              , str " "
              , str "=== [report.toml] Report Configuration ==="
              , txt ("Report Plan: " <> T.pack (show (reportConfigurationPlan (householdStateReportConfig state))))
              , txt ("Presentation: " <> T.pack (show (reportConfigurationPresentation (householdStateReportConfig state))))
              ])))
    , str "[1-7] Switch section   [q] Quit"
    ]
  where
    state = contextHouseholdState context

workspacePaneLabel
  :: AppContext
  -> WorkspaceFocus
  -> String
  -> Widget Name
workspacePaneLabel context pane labelText
  | contextWorkspaceFocus context == pane = str (labelText <> " *")
  | otherwise = str labelText

renderWorkspaceAccount :: Bool -> Maybe Account -> Widget Name
renderWorkspaceAccount selected maybeAccount
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    row = case maybeAccount of
      Nothing -> str "All accounts"
      Just account -> txt (accountName account)

workspaceFilterText :: AppContext -> Text
workspaceFilterText context =
  case selectedWorkspaceAccount context of
    Nothing -> "All accounts"
    Just account -> accountName account

selectedWorkspaceAccount :: AppContext -> Maybe Account
selectedWorkspaceAccount context =
  case L.listSelectedElement (contextWorkspaceAccounts context) of
    Nothing -> Nothing
    Just (_, maybeAccount) -> maybeAccount

renderWorkspaceTransaction :: Bool -> Transaction -> Widget Name
renderWorkspaceTransaction selected transaction
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    row = txt
      (T.pack (show (transactionDate transaction))
        <> "  "
        <> transactionDescription transaction)

renderWorkspaceSelection :: AppContext -> Widget Name
renderWorkspaceSelection context =
  case L.listSelectedElement (contextWorkspaceList context) of
    Nothing -> str "No Actual transactions for this account."
    Just (_, transaction) ->
      vBox
        ( txt
            (T.pack (show (transactionDate transaction))
              <> "  "
              <> transactionDescription transaction)
        : map renderWorkspacePosting
            (NonEmpty.toList (transactionPostings transaction))
        )

renderWorkspacePosting :: Posting -> Widget Name
renderWorkspacePosting posting =
  txt
    ("  "
      <> accountName (postingAccount posting)
      <> "  "
      <> renderQuantity (amountQuantity amount)
      <> " "
      <> commodityCode (amountCommodity amount))
  where
    amount = postingAmount posting

selectionLabel :: AccountSelectionTarget -> String
selectionLabel SelectFromAccount = "Select Payment Account"
selectionLabel SelectToAccount = "Select Expense Category"

renderAccount :: Bool -> Account -> Widget Name
renderAccount selected account
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    row = txt (accountName account)

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
    Workspace -> handleWorkspaceEvent context event
    InputForm form -> handleInputEvent context form event
    SelectAccount target accountList form ->
      handleAccountSelection context target accountList form event
    ShowPreview preview form ->
      handlePreviewEvent context preview form event
    ShowConfirmation block form ->
      handleConfirmationEvent context block form event
    ShowWriteOutcome outcome form ->
      handleWriteOutcomeEvent outcome form event
    ShowWorkspaceReloadFailure ->
      handleExitOnlyEvent event

handleWorkspaceEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleWorkspaceEvent context event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt

  VtyEvent (V.EvKey (V.KChar '1') []) -> put (AppWrapper (context { contextCurrentSection = ActualSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar '2') []) -> put (AppWrapper (context { contextCurrentSection = PlansSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar '3') []) -> put (AppWrapper (context { contextCurrentSection = BudgetSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar '4') []) -> put (AppWrapper (context { contextCurrentSection = AccountsSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar '5') []) -> put (AppWrapper (context { contextCurrentSection = IssuesSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar '6') []) -> put (AppWrapper (context { contextCurrentSection = ReportsSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar '7') []) -> put (AppWrapper (context { contextCurrentSection = SettingsSection }) Workspace)

  VtyEvent (V.EvKey (V.KChar 'r') []) | contextCurrentSection context == ReportsSection ->
    put (AppWrapper (context { contextSelectedReport = cycleReport (contextSelectedReport context) }) Workspace)

  VtyEvent (V.EvKey (V.KChar 'a') []) | contextCurrentSection context == ActualSection ->
    put (AppWrapper context (InputForm (mkDailyForm (contextEntryDay context))))
  VtyEvent (V.EvKey (V.KChar 'A') []) | contextCurrentSection context == ActualSection ->
    put (AppWrapper context (InputForm (mkDailyForm (contextEntryDay context))))
  VtyEvent (V.EvKey (V.KChar '\t') []) | contextCurrentSection context == ActualSection ->
    put (AppWrapper (toggleWorkspaceFocus context) Workspace)
  VtyEvent (V.EvKey V.KLeft []) | contextCurrentSection context == ActualSection ->
    put (AppWrapper (context { contextWorkspaceFocus = AccountsFocus }) Workspace)
  VtyEvent (V.EvKey V.KRight []) | contextCurrentSection context == ActualSection ->
    put (AppWrapper (context { contextWorkspaceFocus = TransactionsFocus }) Workspace)
  VtyEvent vtyEvent | contextCurrentSection context == ActualSection ->
    handleWorkspaceListEvent context vtyEvent
  _ -> pure ()

cycleReport :: ReportChoice -> ReportChoice
cycleReport choice
  | choice == maxBound = minBound
  | otherwise = succ choice

toggleWorkspaceFocus :: AppContext -> AppContext
toggleWorkspaceFocus context =
  context
    { contextWorkspaceFocus = case contextWorkspaceFocus context of
        AccountsFocus -> TransactionsFocus
        TransactionsFocus -> AccountsFocus
    }

handleWorkspaceListEvent
  :: AppContext
  -> V.Event
  -> EventM Name AppWrapper ()
handleWorkspaceListEvent context vtyEvent =
  case contextWorkspaceFocus context of
    AccountsFocus -> do
      zoom zoomWorkspaceAccounts
        (L.handleListEventVi L.handleListEvent vtyEvent)
      AppWrapper updatedContext _ <- get
      put (AppWrapper (applyWorkspaceAccountFilter updatedContext) Workspace)
    TransactionsFocus ->
      zoom zoomWorkspaceList
        (L.handleListEventVi L.handleListEvent vtyEvent)

applyWorkspaceAccountFilter :: AppContext -> AppContext
applyWorkspaceAccountFilter context =
  context
    { contextWorkspaceList =
        L.list
          WorkspaceTransactionList
          (Vec.fromList filteredTransactions)
          1
    }
  where
    filteredTransactions =
      transactionsForAccount
        (selectedWorkspaceAccount context)
        (contextAllTransactions context)

handleInputEvent
  :: AppContext
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleInputEvent context form event = case event of
  VtyEvent (V.EvKey V.KEsc []) ->
    put (AppWrapper context Workspace)
  VtyEvent (V.EvKey V.KEnter []) -> do
    let input = formState form
        resolvedJournal = actualJournalValue (householdStateActualJournal (contextHouseholdState context))
        preview = prepareActualAddPreviewFromResolvedJournal resolvedJournal (contextSource context) input
        pureState =
          enterActualAddPreview preview (ActualAddState input EditingActualAdd)
    case actualAddMode pureState of
      ShowingActualAddPreview shownPreview ->
        put (AppWrapper context (ShowPreview shownPreview form))
      _ -> put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey (V.KChar 't') [V.MCtrl]) ->
    setDailyFormDay context (contextObservationDay context) form
  VtyEvent (V.EvKey (V.KChar 'y') [V.MCtrl]) ->
    setDailyFormDay context (addDays (-1) (contextObservationDay context)) form
  VtyEvent (V.EvKey (V.KChar 'd') [V.MCtrl]) ->
    put (AppWrapper context (InputForm (setFormFocus DateField form)))
  VtyEvent (V.EvKey (V.KFun 2) []) ->
    openAccountSelection context SelectFromAccount form
  VtyEvent (V.EvKey (V.KChar 'f') [V.MCtrl]) ->
    openAccountSelection context SelectFromAccount form
  VtyEvent (V.EvKey (V.KFun 3) []) ->
    openAccountSelection context SelectToAccount form
  VtyEvent (V.EvKey (V.KChar 'e') [V.MCtrl]) ->
    openAccountSelection context SelectToAccount form
  _ -> zoom zoomForm (handleFormEvent event)

setDailyFormDay
  :: AppContext
  -> Day
  -> Form ActualAddInput AppEvent Name
  -> EventM Name AppWrapper ()
setDailyFormDay context day form = do
  let changed =
        setActualAddDate day
          (ActualAddState (formState form) EditingActualAdd)
  put
    (AppWrapper context
      (InputForm (updateFormState (actualAddInput changed) form)))

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
        (L.list
          AccountList
          (Vec.fromList
            (dailyAccountCandidates
              (householdStateAccountsRegistry (contextHouseholdState context))
              (contextAllTransactions context)
              target))
          1)
        form))

handleAccountSelection
  :: AppContext
  -> AccountSelectionTarget
  -> L.List Name Account
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleAccountSelection context target accountList form event = case event of
  VtyEvent (V.EvKey V.KEsc []) ->
    put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey V.KEnter []) ->
    case L.listSelectedElement accountList of
      Nothing -> put (AppWrapper context (InputForm form))
      Just (_, account) -> do
        let state =
              transitionActualAdd
                (ChooseAccount account)
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
          ConfirmActualAdd
          (ActualAddState (formState form) (ConfirmingActualAdd block))
      stickyDay =
        fromMaybe
          (contextEntryDay context)
          (readMaybe (T.unpack (addDateText (formState form))))
      stickyContext = context { contextEntryDay = stickyDay }
  case actualAddMode state of
    ActualAddConfirmed confirmedBlock -> do
      writeResult <-
        suspendAndResume'
          (publishActualBlockFromResolvedJournal
            (contextSourcePath context)
            (contextSource context)
            confirmedBlock)
      let writeOutcome = classifyActualAddWriteResult writeResult
      case writeOutcome of
        ActualAddWriteSucceeded -> do
          reloadedContext <-
            suspendAndResume' (reloadWorkspaceContext stickyContext)
          case reloadedContext of
            Nothing ->
              put (AppWrapper context ShowWorkspaceReloadFailure)
            Just freshContext ->
              put (AppWrapper freshContext Workspace)
        _ ->
          put (AppWrapper context (ShowWriteOutcome writeOutcome form))
    _ -> put (AppWrapper context (ShowConfirmation block form))

reloadWorkspaceContext :: AppContext -> IO (Maybe AppContext)
reloadWorkspaceContext context = do
  let root = householdStateRoot (contextHouseholdState context)
  loadResult <- loadCanonicalHousehold root
  case loadResult of
    Left _ -> pure Nothing
    Right freshState -> do
      readResult <- try (TIO.readFile (contextSourcePath context))
      case readResult of
        Left (_ :: IOError) -> pure Nothing
        Right freshSource ->
          pure
            (Just
              ((makeWorkspaceContext
                  True
                  (contextObservationDay context)
                  (contextSourcePath context)
                  freshSource
                  freshState)
                { contextEntryDay = contextEntryDay context }))

handleWriteOutcomeEvent
  :: ActualAddWriteOutcome
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleWriteOutcomeEvent _ _ = handleExitOnlyEvent

handleExitOnlyEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleExitOnlyEvent event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()

makeWorkspaceContext
  :: Bool
  -> Day
  -> FilePath
  -> Text
  -> HouseholdState
  -> AppContext
makeWorkspaceContext focusLatest today journalFile source state =
  AppContext
    state
    ActualSection
    ReportTrialBalance
    today
    today
    accounts
    workspaceAccounts
    transactions
    workspaceList
    TransactionsFocus
    journalFile
    source
  where
    actualJournal = actualJournalValue (householdStateActualJournal state)
    declarations =
      accountDeclarations (householdStateAccountsRegistry state)
    accounts = map declaredAccount declarations
    transactions = journalTransactions actualJournal
    workspaceAccounts =
      L.list
        WorkspaceAccountList
        (Vec.fromList (Nothing : map (Just . declaredAccount) declarations))
        1
    initialWorkspaceList =
      L.list WorkspaceTransactionList (Vec.fromList transactions) 1
    workspaceList
      | focusLatest && not (null transactions) =
          L.listMoveTo (length transactions - 1) initialWorkspaceList
      | otherwise = initialWorkspaceList

app :: App AppWrapper AppEvent Name
app = App
  { appDraw = drawUI
  , appChooseCursor = showFirstCursor
  , appHandleEvent = appEvent
  , appStartEvent = pure ()
  , appAttrMap = const
      (attrMap V.defAttr
        [ (L.listSelectedAttr, V.black `on` V.white)
        , (attrName "activeTab", V.black `on` V.cyan)
        , (attrName "error", fg V.red)
        , (attrName "success", fg V.green)
        , (attrName "warning", fg V.yellow)
        ])
  }

main :: IO ()
main = do
  today <- localDay . zonedTimeToLocalTime <$> getZonedTime
  arguments <- getArgs
  case arguments of
    [path] -> do
      pathIsDirectory <- doesDirectoryExist path
      let rootDir
            | pathIsDirectory = path
            | otherwise = takeDirectory path
          rootPath = if rootDir == "" then "." else rootDir
      root <- case mkHouseholdRoot rootPath of
        Left err -> die ("Invalid household root: " <> show err)
        Right r -> pure r
      householdResult <- loadCanonicalHousehold root
      state <- case householdResult of
        Left errs -> die ("Failed to load canonical Household:\n" <> unlines (map show (NonEmpty.toList errs)))
        Right s -> pure s
      let journalFile = householdActualJournalPath (householdStatePaths state)
      readResult <- tryIOError (TIO.readFile journalFile)
      source <- case readResult of
        Left err -> die ("Cannot read actual.journal: " <> show err)
        Right content -> pure content
      let context = makeWorkspaceContext False today journalFile source state
          initialState = AppWrapper context Workspace
          buildVty = mkVty V.defaultConfig
      initialVty <- buildVty
      _ <- customMain initialVty buildVty Nothing app initialState
      pure ()
    _ -> die "Usage: h-kernel-editor-tui <household-root-or-actual.journal>"