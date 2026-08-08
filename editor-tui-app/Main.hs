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

import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
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
import HKernel.Actual.Journal
  ( ActualTransactionEntry
  , actualJournalCompletionDeclarations
  , actualJournalReversalDeclarations
  , actualJournalTransactionEntries
  , actualJournalValue
  , actualTransactionEntryIdentity
  , actualTransactionEntryTransaction
  , reversedTransactionId
  , reversalTransactionId
  )
import HKernel.Application.Config (HouseholdSourcePaths(..), mkHouseholdRoot)
import HKernel.Budget.Policy
  ( EnvelopeDefinition
  , budgetPolicyEnvelopeDefinitions
  , envelopeDefinitionExpenseAccounts
  , envelopeDefinitionId
  )
import HKernel.Engine (mkDateRange)
import HKernel.Editor.ActualAppend
  ( ActualAddInput(..)
  , ActualAddPreview(..)
  , ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , ActualMultiAddInput(..)
  , ActualMultiAddPreview(..)
  , ActualPostingInput(..)
  , classifyActualAddWriteResult
  , prepareActualAddPreviewFromResolvedJournal
  , prepareActualMultiAddPreviewFromResolvedJournal
  )
import HKernel.Editor.ActualReverse
  ( ActualReverseInput(..)
  , ActualReverseInputPreview(..)
  , prepareActualReverseInputFromResolvedJournal
  , suggestActualReverseEventIdText
  )
import HKernel.Editor.ActualWorkspace (transactionEntriesForAccount)
import HKernel.Editor.ActualWriter (publishActualBlockFromResolvedJournal)
import HKernel.Editor.Interaction.ActualAdd
  ( ActualAddMode(..)
  , ActualAddState(..)
  , ActualMultiAddState(..)
  , enterActualAddPreview
  , initialActualAddStateForDay
  , initialActualMultiAddStateForDay
  , resizeActualMultiPostings
  , selectActualMultiPosting
  , selectedActualMultiPosting
  , setActualMultiDateText
  , setActualMultiDescription
  , setSelectedActualMultiAccountText
  , setSelectedActualMultiAmount
  )
import HKernel.Editor.Interaction.PlanCompleteAdvance
  ( PlanCompleteAdvanceInput(..)
  , initialPlanCompleteAdvanceInput
  , parsePlanCompleteAdvanceInput
  )
import HKernel.Editor.PlanCompleteAdvance
  ( PlanAdvanceProposal(..)
  , PlanCompleteAdvancePreview(..)
  , PlanCompleteAdvanceWriteError(..)
  , PlanCompleteAdvanceWriteIntent(..)
  , PlanRecurrence(..)
  , preparePlanCompleteAdvance
  , proposePlanAdvance
  , publishPlanCompleteAdvance
  )
import HKernel.Household.Application
  ( HouseholdState(..)
  , buildHouseholdReportSurfaceFromHousehold
  , loadCanonicalHousehold
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.Policy
  ( householdAllocationEnvelopes
  , householdCycleIncomeAccount
  , householdPolicyCycle
  , householdUnassignedBudgetAccounts
  )
import HKernel.HouseholdIssue (HouseholdIssue(..))
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
import HKernel.Plan (planIdText)
import HKernel.Plan.Completion
  ( ActualTransactionId
  , actualTransactionIdText
  , declaredCompletionPlanId
  )
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalTransactions
  )
import HKernel.Render
  ( renderBalanceSheetWithPresentation
  , renderDailyFlowWithPresentation
  , renderMonthlyAccountsWithPresentation
  , renderProfitAndLossWithPresentation
  , renderRecentTransactionsWithPresentation
  , renderTrialBalanceWithPresentation
  )
import HKernel.Report
  ( balanceSheetAsOf
  , dailyFlow
  , defaultRecentCount
  , monthlyAccounts
  , profitAndLoss
  , recentTransactions
  , reportBook
  , trialBalanceAsOf
  )
import HKernel.Report.Config
  ( reportConfigurationPlan
  , reportConfigurationPresentation
  )
import HKernel.Spike.HouseholdReport.Render
  ( HouseholdReportSection(..)
  , renderHouseholdReportSection
  , renderReportBookWithHouseholdPresentation
  )

data Name
  = DateField
  | DescriptionField
  | FromAccountField
  | ToAccountField
  | AmountField
  | MultiDateField
  | MultiDescriptionField
  | MultiPostingCountField
  | MultiAccountField
  | MultiAmountField
  | ReverseDateField
  | ReverseDescriptionField
  | WorkspaceAccountList
  | WorkspaceTransactionList
  | PlanList
  | PlanActualDateField
  | PlanActualAmountField
  | PlanSuccessorDateField
  | PlanSuccessorAmountField
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
  | ReportHousehold HouseholdReportSection
  | ReportRecentTransactions
  | ReportCombinedBook
  deriving (Eq, Show)

data PlanPreviewResult
  = PlanPreviewRejected Text
  | PlanPreviewReady PlanCompleteAdvancePreview

data MultiEditInput = MultiEditInput
  { multiEditDateText         :: Text
  , multiEditDescriptionText  :: Text
  , multiEditPostingCountText :: Text
  , multiEditAccountText      :: Text
  , multiEditAmountText       :: Text
  } deriving (Eq, Show)

data UIState event
  = Workspace
  | InputForm (Form ActualAddInput event Name)
  | ShowPreview
      ActualAddPreview
      (Form ActualAddInput event Name)
  | MultiInput
      ActualMultiAddState
      (Form MultiEditInput event Name)
  | MultiShowPreview
      ActualMultiAddPreview
      ActualMultiAddState
      (Form MultiEditInput event Name)
  | ReverseInputForm
      ActualTransactionId
      Transaction
      (Form ActualReverseInput event Name)
  | ReverseShowPreview
      ActualTransactionId
      Transaction
      ActualReverseInputPreview
      (Form ActualReverseInput event Name)
  | ReverseUnavailable Text
  | ShowWriteOutcome ActualAddWriteOutcome
  | PlanInputForm
      PlanAdvanceProposal
      (Form PlanCompleteAdvanceInput event Name)
  | PlanShowPreview
      PlanAdvanceProposal
      PlanPreviewResult
      (Form PlanCompleteAdvanceInput event Name)
  | PlanShowConfirmation
      PlanAdvanceProposal
      PlanCompleteAdvancePreview
      (Form PlanCompleteAdvanceInput event Name)
  | PlanShowWriteOutcome Text
  | ShowWorkspaceReloadFailure

data AppContext = AppContext
  { contextHouseholdState       :: HouseholdState
  , contextCurrentSection       :: HouseholdSection
  , contextSelectedReport       :: ReportChoice
  , contextObservationDay       :: Day
  , contextEntryDay             :: Day
  , contextWorkspaceAccounts    :: L.List Name (Maybe Account)
  , contextWorkspaceList        :: L.List Name Transaction
  , contextWorkspaceFocus       :: WorkspaceFocus
  , contextPlanList             :: L.List Name IdentifiedPlanTransaction
  , contextSourcePath           :: FilePath
  , contextSource               :: Text
  , contextPlanSource           :: Text
  }

data AppWrapper = AppWrapper AppContext (UIState AppEvent)

type AppEvent = ()

addDateTextL :: Lens' ActualAddInput Text
addDateTextL f input =
  (\value -> input { addDateText = value }) <$> f (addDateText input)

addDescriptionTextL :: Lens' ActualAddInput Text
addDescriptionTextL f input =
  (\value -> input { addDescriptionText = value }) <$> f (addDescriptionText input)

addFromAccountTextL :: Lens' ActualAddInput Text
addFromAccountTextL f input =
  (\value -> input { addFromAccountText = value }) <$> f (addFromAccountText input)

addToAccountTextL :: Lens' ActualAddInput Text
addToAccountTextL f input =
  (\value -> input { addToAccountText = value }) <$> f (addToAccountText input)

addAmountTextL :: Lens' ActualAddInput Text
addAmountTextL f input =
  (\value -> input { addAmountText = value }) <$> f (addAmountText input)

multiEditDateTextL :: Lens' MultiEditInput Text
multiEditDateTextL f input =
  (\value -> input { multiEditDateText = value }) <$> f (multiEditDateText input)

multiEditDescriptionTextL :: Lens' MultiEditInput Text
multiEditDescriptionTextL f input =
  (\value -> input { multiEditDescriptionText = value })
    <$> f (multiEditDescriptionText input)

multiEditPostingCountTextL :: Lens' MultiEditInput Text
multiEditPostingCountTextL f input =
  (\value -> input { multiEditPostingCountText = value })
    <$> f (multiEditPostingCountText input)

multiEditAccountTextL :: Lens' MultiEditInput Text
multiEditAccountTextL f input =
  (\value -> input { multiEditAccountText = value })
    <$> f (multiEditAccountText input)

multiEditAmountTextL :: Lens' MultiEditInput Text
multiEditAmountTextL f input =
  (\value -> input { multiEditAmountText = value })
    <$> f (multiEditAmountText input)

reverseInputDateTextL :: Lens' ActualReverseInput Text
reverseInputDateTextL f input =
  (\value -> input { reverseInputDateText = value })
    <$> f (reverseInputDateText input)

reverseInputDescriptionTextL :: Lens' ActualReverseInput Text
reverseInputDescriptionTextL f input =
  (\value -> input { reverseInputDescriptionText = value })
    <$> f (reverseInputDescriptionText input)

planActualDateTextL :: Lens' PlanCompleteAdvanceInput Text
planActualDateTextL f input =
  (\value -> input { planActualDateText = value }) <$> f (planActualDateText input)

planActualAmountTextL :: Lens' PlanCompleteAdvanceInput Text
planActualAmountTextL f input =
  (\value -> input { planActualAmountText = value }) <$> f (planActualAmountText input)

planSuccessorDateTextL :: Lens' PlanCompleteAdvanceInput Text
planSuccessorDateTextL f input =
  (\value -> input { planSuccessorDateText = value }) <$> f (planSuccessorDateText input)

planSuccessorAmountTextL :: Lens' PlanCompleteAdvanceInput Text
planSuccessorAmountTextL f input =
  (\value -> input { planSuccessorAmountText = value }) <$> f (planSuccessorAmountText input)

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
      , label "Date:"
          @@= editTextField addDateTextL DateField (Just 1)
      ]

mkDailyForm :: Day -> Form ActualAddInput event Name
mkDailyForm day =
  setFormFocus AmountField
    (mkForm (actualAddInput (initialActualAddStateForDay day)))

multiEditInputFor :: ActualMultiAddState -> MultiEditInput
multiEditInputFor state = MultiEditInput
  { multiEditDateText = multiAddDateText input
  , multiEditDescriptionText = multiAddDescriptionText input
  , multiEditPostingCountText = T.pack (show (NonEmpty.length (multiAddPostings input)))
  , multiEditAccountText = multiPostingAccountText selected
  , multiEditAmountText = multiPostingAmountText selected
  }
  where
    input = actualMultiAddInput state
    selected = selectedActualMultiPosting state

mkMultiForm :: ActualMultiAddState -> Form MultiEditInput event Name
mkMultiForm state =
  let label labelText widget =
        padBottom (Pad 1)
          ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)
      form = newForm
        [ label "Date:"
            @@= editTextField multiEditDateTextL MultiDateField (Just 1)
        , label "Description:"
            @@= editTextField multiEditDescriptionTextL MultiDescriptionField (Just 1)
        , label "Posting count:"
            @@= editTextField multiEditPostingCountTextL MultiPostingCountField (Just 1)
        , label "Selected account:"
            @@= editTextField multiEditAccountTextL MultiAccountField (Just 1)
        , label "Selected amount:"
            @@= editTextField multiEditAmountTextL MultiAmountField (Just 1)
        ]
  in setFormFocus MultiDescriptionField (form (multiEditInputFor state))

commitMultiForm
  :: ActualMultiAddState
  -> Form MultiEditInput event Name
  -> ActualMultiAddState
commitMultiForm state form =
  let editInput = formState form
      currentInput = actualMultiAddInput state
      currentCount = NonEmpty.length (multiAddPostings currentInput)
      requestedCount = fromMaybe currentCount
        (readMaybe (T.unpack (T.strip (multiEditPostingCountText editInput))))
      resized = resizeActualMultiPostings requestedCount state
      withDate = setActualMultiDateText (multiEditDateText editInput) resized
      withDescription = setActualMultiDescription
        (multiEditDescriptionText editInput) withDate
      withAccount = setSelectedActualMultiAccountText
        (multiEditAccountText editInput) withDescription
  in setSelectedActualMultiAmount (multiEditAmountText editInput) withAccount

syncMultiForm
  :: ActualMultiAddState
  -> Form MultiEditInput event Name
  -> Form MultiEditInput event Name
syncMultiForm state = updateFormState (multiEditInputFor state)

initialReverseInput
  :: Day
  -> Text
  -> Transaction
  -> ActualReverseInput
initialReverseInput day eventIdText transaction = ActualReverseInput
  { reverseInputEventIdText = eventIdText
  , reverseInputDateText = T.pack (show day)
  , reverseInputDescriptionText = "Reverse: " <> transactionDescription transaction
  }

mkReverseForm
  :: Day
  -> Text
  -> Transaction
  -> Form ActualReverseInput event Name
mkReverseForm day eventIdText transaction =
  let label labelText widget =
        padBottom (Pad 1)
          ((vLimit 1 (hLimit 20 (str labelText <+> fill ' '))) <+> widget)
      form = newForm
        [ label "Date:"
            @@= editTextField reverseInputDateTextL ReverseDateField (Just 1)
        , label "Description:"
            @@= editTextField reverseInputDescriptionTextL ReverseDescriptionField (Just 1)
        ]
  in setFormFocus ReverseDescriptionField
      (form (initialReverseInput day eventIdText transaction))

mkPlanCompleteForm
  :: Day
  -> PlanAdvanceProposal
  -> Form PlanCompleteAdvanceInput event Name
mkPlanCompleteForm today proposal =
  let label labelText widget =
        padBottom (Pad 1)
          ((vLimit 1 (hLimit 23 (str labelText <+> fill ' '))) <+> widget)
      form = newForm
        [ label "Actual date:"
            @@= editTextField planActualDateTextL PlanActualDateField (Just 1)
        , label "Actual amount override:"
            @@= editTextField planActualAmountTextL PlanActualAmountField (Just 1)
        , label "Next nominal date:"
            @@= editTextField planSuccessorDateTextL PlanSuccessorDateField (Just 1)
        , label "Next amount override:"
            @@= editTextField planSuccessorAmountTextL PlanSuccessorAmountField (Just 1)
        ]
  in setFormFocus PlanActualDateField
      (form (initialPlanCompleteAdvanceInput today proposal))

zoomForm :: Traversal' AppWrapper (Form ActualAddInput AppEvent Name)
zoomForm f (AppWrapper context (InputForm form)) =
  (\updated -> AppWrapper context (InputForm updated)) <$> f form
zoomForm _ wrapper = pure wrapper

zoomMultiForm :: Traversal' AppWrapper (Form MultiEditInput AppEvent Name)
zoomMultiForm f (AppWrapper context (MultiInput state form)) =
  (\updated -> AppWrapper context (MultiInput state updated)) <$> f form
zoomMultiForm _ wrapper = pure wrapper

zoomReverseForm :: Traversal' AppWrapper (Form ActualReverseInput AppEvent Name)
zoomReverseForm f (AppWrapper context (ReverseInputForm target transaction form)) =
  (\updated -> AppWrapper context (ReverseInputForm target transaction updated))
    <$> f form
zoomReverseForm _ wrapper = pure wrapper

zoomPlanForm :: Traversal' AppWrapper (Form PlanCompleteAdvanceInput AppEvent Name)
zoomPlanForm f (AppWrapper context (PlanInputForm proposal form)) =
  (\updated -> AppWrapper context (PlanInputForm proposal updated)) <$> f form
zoomPlanForm _ wrapper = pure wrapper

zoomWorkspaceAccounts :: Traversal' AppWrapper (L.List Name (Maybe Account))
zoomWorkspaceAccounts f (AppWrapper context Workspace) =
  (\updated -> AppWrapper (context { contextWorkspaceAccounts = updated }) Workspace)
    <$> f (contextWorkspaceAccounts context)
zoomWorkspaceAccounts _ wrapper = pure wrapper

zoomWorkspaceList :: Traversal' AppWrapper (L.List Name Transaction)
zoomWorkspaceList f (AppWrapper context Workspace) =
  (\updated -> AppWrapper (context { contextWorkspaceList = updated }) Workspace)
    <$> f (contextWorkspaceList context)
zoomWorkspaceList _ wrapper = pure wrapper

zoomPlanList :: Traversal' AppWrapper (L.List Name IdentifiedPlanTransaction)
zoomPlanList f (AppWrapper context Workspace) =
  (\updated -> AppWrapper (context { contextPlanList = updated }) Workspace)
    <$> f (contextPlanList context)
zoomPlanList _ wrapper = pure wrapper

drawUI :: AppWrapper -> [Widget Name]
drawUI (AppWrapper context Workspace) = [drawHouseholdShell context]
drawUI (AppWrapper context (InputForm form)) =
  [ center
      (borderWithLabel (str "Daily Actual")
        (padAll 1
          (vBox
            [ txt ("Date: " <> entryDateSummary context (formState form))
            , str "Amount accepts a quantity only when Account defaults determine the commodity."
            , str "Type canonical Account names directly; no modified or function keys are required."
            , str " "
            , renderForm form
            , str " "
            , str "[Tab] Next field | edit Date directly for another day"
            , str "[Esc] Workspace | [Enter] Preview"
            ])))
  ]
drawUI (AppWrapper _ (ShowPreview preview _)) =
  [ center
      (borderWithLabel (str "Actual Preview")
        (padAll 1 (renderPreview preview <=> str " " <=> str (previewControls preview))))
  ]
drawUI (AppWrapper context (MultiInput state form)) =
  [ center
      (borderWithLabel (str "Multi-posting Actual")
        (hLimit 86
          (padAll 1
            ( vBox
                [ txt ("Date: " <> dateSummary context
                    (multiAddDateText (actualMultiAddInput state)))
                , str "Each posting owns its sign. The complete transaction must balance to zero."
                , str " "
                , renderMultiPostingRows state
                , str " "
                , txt ("Editing posting "
                    <> T.pack (show (actualMultiSelectedPosting state + 1))
                    <> " of "
                    <> T.pack (show (NonEmpty.length
                      (multiAddPostings (actualMultiAddInput state)))))
                , renderForm form
                , str " "
                , str "[Tab] Next field | [Up/Down] Previous/next posting row"
                , str "Edit Posting count to add/remove rows; type Account directly."
                , str "[Esc] Actual | [Enter] Preview"
                ]))))
  ]
drawUI (AppWrapper _ (MultiShowPreview preview _ _)) =
  [ center
      (borderWithLabel (str "Multi-posting Preview")
        (hLimit 86
          (padAll 1
            (renderMultiPreview preview <=> str " " <=> str (multiPreviewControls preview)))))
  ]
drawUI (AppWrapper _ (ReverseInputForm targetId transaction form)) =
  [ center
      (borderWithLabel (str "Reverse Actual")
        (hLimit 86
          (padAll 1
            ( vBox
                [ renderReverseTarget targetId transaction
                , str " "
                , str "The original transaction stays immutable; Reverse appends its exact inverse."
                , str "Reversal identity is generated automatically."
                , str " "
                , renderForm form
                , str " "
                , str "[Tab] Next field | [Esc] Actual | [Enter] Preview"
                ]))))
  ]
drawUI (AppWrapper _ (ReverseShowPreview targetId transaction preview _)) =
  [ center
      (borderWithLabel (str "Reverse Preview")
        (hLimit 86
          (padAll 1
            ( renderReverseTarget targetId transaction
              <=> str " "
              <=> renderReversePreview preview
              <=> str " "
              <=> str (reversePreviewControls preview)))))
  ]
drawUI (AppWrapper _ (ReverseUnavailable message)) =
  [ center
      (borderWithLabel (str "Reverse unavailable")
        (hLimit 80
          (padAll 1
            ( withAttr (attrName "warning") (txt message)
              <=> str " "
              <=> str "[Enter/Esc] Back to Actual | [Q] Quit"))))
  ]
drawUI (AppWrapper _ (ShowWriteOutcome outcome)) =
  [ center
      (borderWithLabel (str "Actual Write Result")
        (padAll 1 (renderWriteOutcome outcome <=> str " " <=> str "[Esc/Q] Quit")))
  ]
drawUI (AppWrapper _ (PlanInputForm proposal form)) =
  [ center
      (borderWithLabel (str "Complete & Advance Plan")
        (hLimit 82
          (padAll 1
            ( renderPlanProposal proposal
              <=> str " "
              <=> renderForm form
              <=> str " "
              <=> str "Blank Actual amount uses the planned amount."
              <=> str "Blank Next amount keeps the original planned amount."
              <=> str "Clear Next nominal date to complete without a successor."
              <=> str "Edit Actual date directly; no modified or function keys are required."
              <=> str "[Tab] Next field | [Esc] Plans | [Enter] Preview"))))
  ]
drawUI (AppWrapper _ (PlanShowPreview _ result _)) =
  [ center
      (borderWithLabel (str "Complete & Advance Preview")
        (hLimit 86
          (vLimit 30
            (padAll 1
              (renderPlanPreviewResult result
                <=> str " "
                <=> str (planPreviewControls result))))))
  ]
drawUI (AppWrapper _ (PlanShowConfirmation _ preview _)) =
  [ center
      (borderWithLabel (str "Confirm Complete & Advance")
        (hLimit 86
          (vLimit 30
            (padAll 1
              ( str "This will update Actual and, when present, append the successor Plan as one operation."
                <=> str "Both complete candidates have already been validated."
                <=> str " "
                <=> renderPlanCompletePreview preview
                <=> str " "
                <=> str "[Y] Publish both | [N/Esc] Back | [Q] Quit")))))
  ]
drawUI (AppWrapper _ (PlanShowWriteOutcome message)) =
  [ center
      (borderWithLabel (str "Plan Complete & Advance Result")
        (padAll 1 (txt message <=> str " " <=> str "[Esc] Plans | [Q] Quit")))
  ]
drawUI (AppWrapper _ ShowWorkspaceReloadFailure) =
  [ center
      (borderWithLabel (str "Household reload")
        (padAll 1
          (withAttr (attrName "error")
            (vBox
              [ str "The source write succeeded, but the Household could not reload."
              , str "Restart the TUI before continuing."
              , str " "
              , str "[Esc/Q] Quit"
              ]))))
  ]

entryDateSummary :: AppContext -> ActualAddInput -> Text
entryDateSummary context = dateSummary context . addDateText

dateSummary :: AppContext -> Text -> Text
dateSummary context value
  | value == T.pack (show today) = "Today  " <> value
  | otherwise = "Other  " <> value
  where
    today = contextObservationDay context

renderMultiPostingRows :: ActualMultiAddState -> Widget Name
renderMultiPostingRows state =
  vBox
    [ renderRow index posting
    | (index, posting) <- zip [0 ..]
        (NonEmpty.toList (multiAddPostings (actualMultiAddInput state)))
    ]
  where
    selected = actualMultiSelectedPosting state
    renderRow index posting =
      let accountText
            | T.null (multiPostingAccountText posting) = "(enter account)"
            | otherwise = multiPostingAccountText posting
          amountText
            | T.null (multiPostingAmountText posting) = "(amount)"
            | otherwise = multiPostingAmountText posting
          row = txt
            (T.pack (show (index + 1)) <> ".  " <> accountText <> "  " <> amountText)
      in if index == selected then withAttr L.listSelectedAttr row else row

renderMultiPreview :: ActualMultiAddPreview -> Widget Name
renderMultiPreview preview = case preview of
  ActualMultiAddInputRejected inputError ->
    withAttr (attrName "error") (txt ("Input rejected: " <> T.pack (show inputError)))
  ActualMultiAddCandidateRejected sourceErrors ->
    withAttr (attrName "error")
      (txt (T.intercalate "\n" (map (T.pack . show) (NonEmpty.toList sourceErrors))))
  ActualMultiAddCandidateReady block ->
    withAttr (attrName "success") (str "Validation successful. Source unmodified.")
      <=> str " " <=> txt block

multiPreviewControls :: ActualMultiAddPreview -> String
multiPreviewControls preview = case preview of
  ActualMultiAddCandidateReady _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  _ -> "[Esc/B] Back | [Q] Quit"

renderReverseTarget :: ActualTransactionId -> Transaction -> Widget Name
renderReverseTarget targetId transaction =
  vBox
    ( txt (T.pack (show (transactionDate transaction))
        <> "  [" <> actualTransactionIdText targetId <> "]  "
        <> transactionDescription transaction)
      : map renderWorkspacePosting
          (NonEmpty.toList (transactionPostings transaction))
    )

renderReversePreview :: ActualReverseInputPreview -> Widget Name
renderReversePreview preview = case preview of
  ActualReverseInputRejected inputError ->
    withAttr (attrName "error")
      (txt ("Input rejected: " <> T.pack (show inputError)))
  ActualReverseCandidateRejected sourceErrors ->
    withAttr (attrName "error")
      (txt (T.intercalate "\n" (map (T.pack . show) (NonEmpty.toList sourceErrors))))
  ActualReverseCandidateReady block ->
    withAttr (attrName "success")
      (str "Validation successful. Source unmodified.")
      <=> str " " <=> txt block

reversePreviewControls :: ActualReverseInputPreview -> String
reversePreviewControls preview = case preview of
  ActualReverseCandidateReady _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  _ -> "[Esc/B] Back | [Q] Quit"

renderPlanProposal :: PlanAdvanceProposal -> Widget Name
renderPlanProposal proposal =
  vBox
    [ txt ("Plan: " <> T.pack (show (proposalNominalDate proposal))
        <> "  [" <> planIdText (proposalPlanId proposal) <> "]  "
        <> proposalDescription proposal)
    , txt ("Recurrence: " <> recurrenceLabel (proposalRecurrence proposal))
    , str "Planned postings:"
    , vBox (map renderWorkspacePosting
        (NonEmpty.toList (transactionPostings (proposalOriginalTransaction proposal))))
    ]

recurrenceLabel :: PlanRecurrence -> Text
recurrenceLabel recurrence = case recurrence of
  PlanRecursOnce -> "once"
  PlanRecursMonthly -> "monthly (next date is based on the nominal Plan date)"
  PlanRecursByHouseholdCycle -> "cycle (next nominal date is explicit)"
  PlanRecurrenceUnspecified -> "unspecified (next nominal date is explicit)"

renderPlanPreviewResult :: PlanPreviewResult -> Widget Name
renderPlanPreviewResult result = case result of
  PlanPreviewRejected message -> withAttr (attrName "error") (txt message)
  PlanPreviewReady preview -> renderPlanCompletePreview preview

renderPlanCompletePreview :: PlanCompleteAdvancePreview -> Widget Name
renderPlanCompletePreview preview =
  vBox
    [ withAttr (attrName "success") (str "Actual completion")
    , txt (completeAdvanceActualBlock preview)
    , str " "
    , withAttr (attrName "success") (str "Next Plan")
    , case completeAdvanceSuccessorBlock preview of
        Nothing -> str "No successor will be added."
        Just block -> txt block
    ]

planPreviewControls :: PlanPreviewResult -> String
planPreviewControls result = case result of
  PlanPreviewReady _ -> "[Esc/B] Back | [C] Continue to confirmation | [Q] Quit"
  PlanPreviewRejected _ -> "[Esc/B] Back | [Q] Quit"

drawHouseholdShell :: AppContext -> Widget Name
drawHouseholdShell context =
  vBox [drawSectionTabBar (contextCurrentSection context), drawSectionBody context]

drawSectionTabBar :: HouseholdSection -> Widget Name
drawSectionTabBar currentSection =
  borderWithLabel (str "h-kernel Household")
    (hBox (map renderTab [minBound .. maxBound]))
  where
    renderTab section
      | section == currentSection = withAttr (attrName "activeTab")
          (str (" [" <> sectionNum section <> ": " <> sectionName section <> "] "))
      | otherwise = str ("  " <> sectionNum section <> ": " <> sectionName section <> "  ")
    sectionNum ActualSection = "1"
    sectionNum PlansSection = "2"
    sectionNum BudgetSection = "3"
    sectionNum AccountsSection = "4"
    sectionNum IssuesSection = "5"
    sectionNum ReportsSection = "6"
    sectionNum SettingsSection = "7"
    sectionName ActualSection = "Actual"
    sectionName PlansSection = "Plans"
    sectionName BudgetSection = "Budget"
    sectionName AccountsSection = "Accounts"
    sectionName IssuesSection = "Issues"
    sectionName ReportsSection = "Reports"
    sectionName SettingsSection = "Settings"

drawSectionBody :: AppContext -> Widget Name
drawSectionBody context = case contextCurrentSection context of
  ActualSection -> drawWorkspace context
  PlansSection -> drawPlansView context
  BudgetSection -> drawBudgetView context
  AccountsSection -> drawAccountsView context
  IssuesSection -> drawIssuesView context
  ReportsSection -> drawReportsView context
  SettingsSection -> drawSettingsView context

drawWorkspace :: AppContext -> Widget Name
drawWorkspace context =
  vBox
    [ hBox
        [ hLimit 30
            (borderWithLabel (workspacePaneLabel context AccountsFocus "Accounts")
              (vLimit 16
                (L.renderList renderWorkspaceAccount
                  (contextWorkspaceFocus context == AccountsFocus)
                  (contextWorkspaceAccounts context))))
        , padLeft (Pad 1)
            (padRight Max
              (borderWithLabel (workspacePaneLabel context TransactionsFocus "Transactions")
                (vLimit 16
                  (L.renderList renderWorkspaceTransaction
                    (contextWorkspaceFocus context == TransactionsFocus)
                    (contextWorkspaceList context)))))
        ]
    , borderWithLabel (str "Selected transaction")
        (padAll 1 (renderWorkspaceSelection context))
    , txt ("Filter: " <> workspaceFilterText context)
    , str "[1-7] Sections   [Tab/Left/Right] Focus   [j/k/Arrows] Move   [Enter] Reverse selected   [a] Daily Actual   [m] Multi Actual   [q] Quit"
    ]

drawPlansView :: AppContext -> Widget Name
drawPlansView context =
  vBox
    [ borderWithLabel (str "Open Plans (plan.journal)")
        (vLimit 18
          (L.renderList renderPlanItem True (contextPlanList context)))
    , borderWithLabel (str "Selected Plan")
        (padAll 1 (renderSelectedPlan context))
    , str "[j/k/Arrows] Move   [Enter/C] Complete & Advance   [1-7] Sections   [q] Quit"
    ]

renderPlanItem :: Bool -> IdentifiedPlanTransaction -> Widget Name
renderPlanItem selected identified
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    transaction = identifiedPlanTransaction identified
    row = txt
      (T.pack (show (transactionDate transaction))
        <> "  [" <> planIdText (identifiedPlanId identified) <> "]  "
        <> transactionDescription transaction)

renderSelectedPlan :: AppContext -> Widget Name
renderSelectedPlan context = case L.listSelectedElement (contextPlanList context) of
  Nothing -> str "No open Plans."
  Just (_, identified) ->
    let transaction = identifiedPlanTransaction identified
    in vBox
      ( txt (T.pack (show (transactionDate transaction))
          <> "  [" <> planIdText (identifiedPlanId identified) <> "]  "
          <> transactionDescription transaction)
        : map renderWorkspacePosting (NonEmpty.toList (transactionPostings transaction))
      )

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
              , vBox (map renderEnvelopeDef
                  (budgetPolicyEnvelopeDefinitions (householdStateBudgetPolicy state)))
              ])))
    , str "[1-7] Switch section   [q] Quit"
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
  txt ("Envelope: " <> T.pack (show (envelopeDefinitionId definition))
    <> "  Expenses: "
    <> T.intercalate ", " (map accountName (envelopeDefinitionExpenseAccounts definition)))

drawAccountsView :: AppContext -> Widget Name
drawAccountsView context =
  vBox
    [ borderWithLabel (str "Canonical Account Declarations (accounts.journal)")
        (vLimit 18
          (viewport AccountsViewport Vertical
            (vBox (map renderAccountDecl
              (accountDeclarations
                (householdStateAccountsRegistry (contextHouseholdState context)))))))
    , str "[1-7] Switch section   [q] Quit"
    ]

renderAccountDecl :: AccountDeclaration -> Widget Name
renderAccountDecl declaration =
  txt (accountName (declaredAccount declaration) <> "  type: "
    <> T.pack (show (declaredAccountType declaration))
    <> maybe "" (\commodity -> "  default commodity: " <> commodityCode commodity)
      (declaredAccountDefaultCommodity declaration))

drawIssuesView :: AppContext -> Widget Name
drawIssuesView context =
  vBox
    [ borderWithLabel (str "Household Notebook (issues.tsv)")
        (vLimit 18
          (viewport IssuesViewport Vertical
            (if null issues then str "No issues recorded." else vBox (map renderIssue issues))))
    , str "[1-7] Switch section   [q] Quit"
    ]
  where
    issues = householdStateIssues (contextHouseholdState context)

renderIssue :: HouseholdIssue -> Widget Name
renderIssue issue =
  padBottom (Pad 1)
    (vBox
      [ txt ("[" <> T.pack (show (householdIssueStatus issue)) <> "]  "
          <> T.pack (show (householdIssueRecordedOn issue)) <> "  Due: "
          <> T.pack (show (householdIssueDue issue)))
      , txt ("  Text: " <> householdIssueText issue)
      , maybe emptyWidget
          (\amount -> txt ("  Amount: " <> renderQuantity (amountQuantity amount)
            <> " " <> commodityCode (amountCommodity amount)))
          (householdIssueAmount issue)
      , txt ("  Details: " <> householdIssueDetails issue)
      ])

drawReportsView :: AppContext -> Widget Name
drawReportsView context =
  vBox
    [ borderWithLabel (txt ("Household Report: " <> reportChoiceLabel selected))
        (vLimit 18 (viewport ReportsViewport Vertical (renderSelectedReport context)))
    , txt ("Active report: " <> reportChoiceLabel selected)
    , str "[t] Trial   [b] Balance Sheet   [p] P&L   [d] Daily   [m] Monthly   [a] Recent"
    , str "[c] Cycle   [T] Target   [P] Planned   [E] Envelope   [h] Household   [r] Next"
    , str "[1-7] Switch section   [q] Quit"
    ]
  where
    selected = contextSelectedReport context

reportChoiceLabel :: ReportChoice -> Text
reportChoiceLabel choice = case choice of
  ReportTrialBalance -> "Trial Balance"
  ReportBalanceSheet -> "Balance Sheet"
  ReportProfitAndLoss -> "Profit & Loss"
  ReportDailyFlow -> "Daily Flow"
  ReportMonthlyAccounts -> "Monthly Accounts"
  ReportHousehold section -> case section of
    HouseholdCycleAccounts -> "Current Cycle"
    HouseholdDailyTarget -> "Daily Target"
    HouseholdPlannedTransactions -> "Planned Transactions"
    HouseholdIssues _ -> "Household Issues"
    HouseholdEnvelopeBacking -> "Envelope & Backing"
  ReportRecentTransactions -> "Recent Actual"
  ReportCombinedBook -> "Household"

reportChoices :: [ReportChoice]
reportChoices =
  [ ReportTrialBalance
  , ReportBalanceSheet
  , ReportProfitAndLoss
  , ReportDailyFlow
  , ReportMonthlyAccounts
  , ReportHousehold HouseholdCycleAccounts
  , ReportHousehold HouseholdDailyTarget
  , ReportHousehold HouseholdPlannedTransactions
  , ReportHousehold HouseholdEnvelopeBacking
  , ReportRecentTransactions
  , ReportCombinedBook
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
  ReportHousehold section -> case buildHouseholdReportSurfaceFromHousehold day state of
    Left err -> txt ("Report surface error: " <> T.pack (show err))
    Right surface -> txt (renderHouseholdReportSection pres section surface)
  ReportRecentTransactions ->
    txt (renderRecentTransactionsWithPresentation pres
      (recentTransactions defaultRecentCount day journal))
  ReportCombinedBook -> case buildHouseholdReportSurfaceFromHousehold day state of
    Left err -> txt ("Report surface error: " <> T.pack (show err))
    Right surface -> txt
      (renderReportBookWithHouseholdPresentation pres (reportBook (defaultDateRange day) journal) surface)
  where
    state = contextHouseholdState context
    day = contextObservationDay context
    journal = actualJournalValue (householdStateActualJournal state)
    pres = reportConfigurationPresentation (householdStateReportConfig state)
    defaultDateRange value = case mkDateRange value value of
      Right range -> range
      Left _ -> error "unreachable date range"

drawSettingsView :: AppContext -> Widget Name
drawSettingsView context =
  vBox
    [ borderWithLabel (str "Household Settings & Policy")
        (vLimit 18
          (viewport SettingsViewport Vertical
            (vBox
              [ str "=== [budget.toml] Budget Policy ==="
              , str ("Envelopes count: "
                  <> show (length (budgetPolicyEnvelopeDefinitions
                    (householdStateBudgetPolicy state))))
              , str " "
              , str "=== [household.toml] Household Policy ==="
              , txt ("Income Cycle Account: "
                  <> accountName (householdCycleIncomeAccount
                    (householdPolicyCycle (householdStatePolicy state))))
              , txt ("Allocation Envelopes: "
                  <> T.pack (show (householdAllocationEnvelopes
                    (householdStatePolicy state))))
              , txt ("Unassigned Accounts: "
                  <> T.intercalate ", "
                    (map accountName
                      (Set.toAscList (householdUnassignedBudgetAccounts
                        (householdStatePolicy state)))))
              , str " "
              , str "=== [report.toml] Report Configuration ==="
              , txt ("Report Plan: "
                  <> T.pack (show (reportConfigurationPlan
                    (householdStateReportConfig state))))
              , txt ("Presentation: "
                  <> T.pack (show (reportConfigurationPresentation
                    (householdStateReportConfig state))))
              ])))
    , str "[1-7] Switch section   [q] Quit"
    ]
  where
    state = contextHouseholdState context

workspacePaneLabel :: AppContext -> WorkspaceFocus -> String -> Widget Name
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
workspaceFilterText context = case selectedWorkspaceAccount context of
  Nothing -> "All accounts"
  Just account -> accountName account

selectedWorkspaceAccount :: AppContext -> Maybe Account
selectedWorkspaceAccount context = case L.listSelectedElement (contextWorkspaceAccounts context) of
  Nothing -> Nothing
  Just (_, maybeAccount) -> maybeAccount

filteredWorkspaceEntries :: AppContext -> [ActualTransactionEntry]
filteredWorkspaceEntries context =
  transactionEntriesForAccount
    (selectedWorkspaceAccount context)
    (actualJournalTransactionEntries
      (householdStateActualJournal (contextHouseholdState context)))

selectedWorkspaceEntry :: AppContext -> Maybe ActualTransactionEntry
selectedWorkspaceEntry context = do
  (selectedIndex, _) <- L.listSelectedElement (contextWorkspaceList context)
  listToMaybe (drop selectedIndex (filteredWorkspaceEntries context))

selectedWorkspaceReverseTarget
  :: AppContext
  -> Either Text (ActualTransactionId, Transaction)
selectedWorkspaceReverseTarget context = case selectedWorkspaceEntry context of
  Nothing -> Left "No Actual transaction is selected."
  Just entry -> case actualTransactionEntryIdentity entry of
    Nothing -> Left
      "Reverse unavailable: this transaction has no durable Actual identity."
    Just targetId -> case directReversalFor context targetId of
      Nothing -> Right (targetId, actualTransactionEntryTransaction entry)
      Just reversalId -> Left
        ("Already reversed by " <> actualTransactionIdText reversalId
          <> ". Select that reversal if you need to restore the original effect.")

directReversalFor :: AppContext -> ActualTransactionId -> Maybe ActualTransactionId
directReversalFor context targetId = listToMaybe
  [ reversalTransactionId declaration
  | declaration <- actualJournalReversalDeclarations
      (householdStateActualJournal (contextHouseholdState context))
  , reversedTransactionId declaration == targetId
  ]

renderWorkspaceTransaction :: Bool -> Transaction -> Widget Name
renderWorkspaceTransaction selected transaction
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    row = txt (T.pack (show (transactionDate transaction)) <> "  "
      <> transactionDescription transaction)

renderWorkspaceSelection :: AppContext -> Widget Name
renderWorkspaceSelection context = case selectedWorkspaceEntry context of
  Nothing -> str "No Actual transactions for this account."
  Just entry ->
    let transaction = actualTransactionEntryTransaction entry
    in vBox
      ( [ txt (T.pack (show (transactionDate transaction)) <> "  "
            <> transactionDescription transaction)
        ]
        ++ map renderWorkspacePosting
            (NonEmpty.toList (transactionPostings transaction))
        ++ [str " ", renderReverseAvailability context entry]
      )

renderReverseAvailability :: AppContext -> ActualTransactionEntry -> Widget Name
renderReverseAvailability context entry = case actualTransactionEntryIdentity entry of
  Nothing -> withAttr (attrName "warning")
    (str "Reverse unavailable: no durable Actual identity.")
  Just targetId -> case directReversalFor context targetId of
    Just reversalId -> withAttr (attrName "warning")
      (txt ("Already reversed by " <> actualTransactionIdText reversalId
        <> ". Select that reversal to reverse it."))
    Nothing -> withAttr (attrName "success")
      (txt ("[Enter] Reverse  event-id: " <> actualTransactionIdText targetId))

renderWorkspacePosting :: Posting -> Widget Name
renderWorkspacePosting posting =
  txt ("  " <> accountName (postingAccount posting) <> "  "
    <> renderQuantity (amountQuantity amount) <> " "
    <> commodityCode (amountCommodity amount))
  where
    amount = postingAmount posting

renderPreview :: ActualAddPreview -> Widget Name
renderPreview preview = case preview of
  ActualAddInputRejected inputError ->
    withAttr (attrName "error") (txt ("Input rejected: " <> T.pack (show inputError)))
  ActualAddCandidateRejected sourceErrors ->
    withAttr (attrName "error")
      (txt (T.intercalate "\n" (map (T.pack . show) (NonEmpty.toList sourceErrors))))
  ActualAddCandidateReady block ->
    withAttr (attrName "success") (str "Validation successful. Source unmodified.")
      <=> str " " <=> txt block

previewControls :: ActualAddPreview -> String
previewControls preview = case preview of
  ActualAddCandidateReady _ -> "[Esc/B] Back | [Enter/Y] Publish | [Q] Quit"
  _ -> "[Esc/B] Back | [Q] Quit"

renderWriteOutcome :: ActualAddWriteOutcome -> Widget Name
renderWriteOutcome outcome = case outcome of
  ActualAddWriteSucceeded -> withAttr (attrName "success")
    (str "Published and post-admitted successfully.")
  ActualAddWriteStale -> withAttr (attrName "error")
    (vBox
      [ str "Source changed after preview. Nothing was written."
      , str "Restart the TUI and preview the current source before retrying."
      ])
  ActualAddWriteRecovered failure -> withAttr (attrName "warning")
    (vBox [str "Publication failed, and the backup was restored.", txt (writeFailureText failure)])
  ActualAddWriteFileIOFailed -> withAttr (attrName "error")
    (vBox
      [ str "The writer could not complete because of a filesystem error."
      , str "No source-local error detail is retained in the TUI state."
      ])
  ActualAddWriteFailed failure -> withAttr (attrName "error")
    (vBox [str "Publication failed and automatic recovery did not complete.", txt (writeFailureText failure)])

writeFailureText :: ActualAddWriteFailure -> Text
writeFailureText failure = case failure of
  ActualAddPostAdmissionFailure -> "The published candidate failed complete-source admission."
  ActualAddPostPublishReadFailure -> "The published source could not be read for post-admission."

appEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
appEvent event = do
  AppWrapper context state <- get
  case state of
    Workspace -> handleWorkspaceEvent context event
    InputForm form -> handleInputEvent context form event
    ShowPreview preview form -> handlePreviewEvent context preview form event
    MultiInput multiState form -> handleMultiInputEvent context multiState form event
    MultiShowPreview preview multiState form ->
      handleMultiPreviewEvent context preview multiState form event
    ReverseInputForm targetId transaction form ->
      handleReverseInputEvent context targetId transaction form event
    ReverseShowPreview targetId transaction preview form ->
      handleReversePreviewEvent context targetId transaction preview form event
    ReverseUnavailable _ -> handleReverseUnavailableEvent context event
    ShowWriteOutcome _ -> handleWriteOutcomeEvent event
    PlanInputForm proposal form -> handlePlanInputEvent context proposal form event
    PlanShowPreview proposal result form ->
      handlePlanPreviewEvent context proposal result form event
    PlanShowConfirmation proposal preview form ->
      handlePlanConfirmationEvent context proposal preview form event
    PlanShowWriteOutcome _ -> handlePlanOutcomeEvent context event
    ShowWorkspaceReloadFailure -> handleExitOnlyEvent event

handleWorkspaceEvent :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleWorkspaceEvent context event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey (V.KChar '1') []) ->
    put (AppWrapper (context { contextCurrentSection = ActualSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar '2') []) ->
    put (AppWrapper (context { contextCurrentSection = PlansSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar '3') []) ->
    put (AppWrapper (context { contextCurrentSection = BudgetSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar '4') []) ->
    put (AppWrapper (context { contextCurrentSection = AccountsSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar '5') []) ->
    put (AppWrapper (context { contextCurrentSection = IssuesSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar '6') []) ->
    put (AppWrapper (context { contextCurrentSection = ReportsSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar '7') []) ->
    put (AppWrapper (context { contextCurrentSection = SettingsSection }) Workspace)
  VtyEvent (V.EvKey (V.KChar 't') [])
    | contextCurrentSection context == ReportsSection -> selectReport context ReportTrialBalance
  VtyEvent (V.EvKey (V.KChar 'b') [])
    | contextCurrentSection context == ReportsSection -> selectReport context ReportBalanceSheet
  VtyEvent (V.EvKey (V.KChar 'p') [])
    | contextCurrentSection context == ReportsSection -> selectReport context ReportProfitAndLoss
  VtyEvent (V.EvKey (V.KChar 'd') [])
    | contextCurrentSection context == ReportsSection -> selectReport context ReportDailyFlow
  VtyEvent (V.EvKey (V.KChar 'm') [])
    | contextCurrentSection context == ReportsSection -> selectReport context ReportMonthlyAccounts
  VtyEvent (V.EvKey (V.KChar 'c') [])
    | contextCurrentSection context == ReportsSection ->
        selectReport context (ReportHousehold HouseholdCycleAccounts)
  VtyEvent (V.EvKey (V.KChar 'T') [])
    | contextCurrentSection context == ReportsSection ->
        selectReport context (ReportHousehold HouseholdDailyTarget)
  VtyEvent (V.EvKey (V.KChar 'P') [])
    | contextCurrentSection context == ReportsSection ->
        selectReport context (ReportHousehold HouseholdPlannedTransactions)
  VtyEvent (V.EvKey (V.KChar 'E') [])
    | contextCurrentSection context == ReportsSection ->
        selectReport context (ReportHousehold HouseholdEnvelopeBacking)
  VtyEvent (V.EvKey (V.KChar 'a') [])
    | contextCurrentSection context == ReportsSection -> selectReport context ReportRecentTransactions
  VtyEvent (V.EvKey (V.KChar 'h') [])
    | contextCurrentSection context == ReportsSection -> selectReport context ReportCombinedBook
  VtyEvent (V.EvKey (V.KChar 'r') [])
    | contextCurrentSection context == ReportsSection ->
        put (AppWrapper (context { contextSelectedReport = cycleReport (contextSelectedReport context) }) Workspace)
  VtyEvent (V.EvKey (V.KChar 'a') [])
    | contextCurrentSection context == ActualSection ->
        put (AppWrapper context (InputForm (mkDailyForm (contextEntryDay context))))
  VtyEvent (V.EvKey (V.KChar 'A') [])
    | contextCurrentSection context == ActualSection ->
        put (AppWrapper context (InputForm (mkDailyForm (contextEntryDay context))))
  VtyEvent (V.EvKey (V.KChar 'm') [])
    | contextCurrentSection context == ActualSection -> openMultiInput context
  VtyEvent (V.EvKey (V.KChar 'M') [])
    | contextCurrentSection context == ActualSection -> openMultiInput context
  VtyEvent (V.EvKey V.KEnter [])
    | contextCurrentSection context == ActualSection
    , contextWorkspaceFocus context == AccountsFocus ->
        put (AppWrapper (context { contextWorkspaceFocus = TransactionsFocus }) Workspace)
  VtyEvent (V.EvKey V.KEnter [])
    | contextCurrentSection context == ActualSection -> openSelectedActualReverse context
  VtyEvent (V.EvKey V.KEnter [])
    | contextCurrentSection context == PlansSection -> openSelectedPlanCompletion context
  VtyEvent (V.EvKey (V.KChar 'c') [])
    | contextCurrentSection context == PlansSection -> openSelectedPlanCompletion context
  VtyEvent (V.EvKey (V.KChar 'C') [])
    | contextCurrentSection context == PlansSection -> openSelectedPlanCompletion context
  VtyEvent (V.EvKey (V.KChar '\t') [])
    | contextCurrentSection context == ActualSection ->
        put (AppWrapper (toggleWorkspaceFocus context) Workspace)
  VtyEvent (V.EvKey V.KLeft [])
    | contextCurrentSection context == ActualSection ->
        put (AppWrapper (context { contextWorkspaceFocus = AccountsFocus }) Workspace)
  VtyEvent (V.EvKey V.KRight [])
    | contextCurrentSection context == ActualSection ->
        put (AppWrapper (context { contextWorkspaceFocus = TransactionsFocus }) Workspace)
  VtyEvent vtyEvent
    | contextCurrentSection context == ActualSection -> handleWorkspaceListEvent context vtyEvent
  VtyEvent vtyEvent
    | contextCurrentSection context == PlansSection ->
        zoom zoomPlanList (L.handleListEventVi L.handleListEvent vtyEvent)
  _ -> pure ()

selectReport :: AppContext -> ReportChoice -> EventM Name AppWrapper ()
selectReport context report =
  put (AppWrapper (context { contextSelectedReport = report }) Workspace)

openMultiInput :: AppContext -> EventM Name AppWrapper ()
openMultiInput context = do
  let state = initialActualMultiAddStateForDay (contextEntryDay context)
  put (AppWrapper context (MultiInput state (mkMultiForm state)))

openSelectedActualReverse :: AppContext -> EventM Name AppWrapper ()
openSelectedActualReverse context = case selectedWorkspaceReverseTarget context of
  Left message -> put (AppWrapper context (ReverseUnavailable message))
  Right (targetId, transaction) ->
    let existingIds =
          [ identity
          | entry <- actualJournalTransactionEntries
              (householdStateActualJournal (contextHouseholdState context))
          , Just identity <- [actualTransactionEntryIdentity entry]
          ]
        eventIdText = suggestActualReverseEventIdText existingIds targetId
    in put (AppWrapper context
      (ReverseInputForm targetId transaction
        (mkReverseForm (contextObservationDay context) eventIdText transaction)))

openSelectedPlanCompletion :: AppContext -> EventM Name AppWrapper ()
openSelectedPlanCompletion context =
  case L.listSelectedElement (contextPlanList context) of
    Nothing -> pure ()
    Just (_, identified) ->
      case proposePlanAdvance
          (householdStatePlanJournal (contextHouseholdState context))
          (contextPlanSource context)
          (identifiedPlanId identified) of
        Left errors -> put (AppWrapper context
          (PlanShowWriteOutcome
            ("Cannot prepare selected Plan: " <> T.pack (show (NonEmpty.toList errors)))))
        Right proposal -> put (AppWrapper context
          (PlanInputForm proposal (mkPlanCompleteForm (contextObservationDay context) proposal)))

cycleReport :: ReportChoice -> ReportChoice
cycleReport choice = go reportChoices
  where
    go [] = ReportTrialBalance
    go [_] = ReportTrialBalance
    go (current : next : rest)
      | current == choice = next
      | otherwise = go (next : rest)

toggleWorkspaceFocus :: AppContext -> AppContext
toggleWorkspaceFocus context = context
  { contextWorkspaceFocus = case contextWorkspaceFocus context of
      AccountsFocus -> TransactionsFocus
      TransactionsFocus -> AccountsFocus
  }

handleWorkspaceListEvent :: AppContext -> V.Event -> EventM Name AppWrapper ()
handleWorkspaceListEvent context vtyEvent = case contextWorkspaceFocus context of
  AccountsFocus -> do
    zoom zoomWorkspaceAccounts (L.handleListEventVi L.handleListEvent vtyEvent)
    AppWrapper updatedContext _ <- get
    put (AppWrapper (applyWorkspaceAccountFilter updatedContext) Workspace)
  TransactionsFocus ->
    zoom zoomWorkspaceList (L.handleListEventVi L.handleListEvent vtyEvent)

applyWorkspaceAccountFilter :: AppContext -> AppContext
applyWorkspaceAccountFilter context = context
  { contextWorkspaceList =
      L.list WorkspaceTransactionList (Vec.fromList filteredTransactions) 1
  }
  where
    filteredTransactions =
      map actualTransactionEntryTransaction (filteredWorkspaceEntries context)

handleInputEvent
  :: AppContext
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleInputEvent context form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put (AppWrapper context Workspace)
  VtyEvent (V.EvKey V.KEnter []) -> do
    let input = formState form
        resolvedJournal = actualJournalValue
          (householdStateActualJournal (contextHouseholdState context))
        preview = prepareActualAddPreviewFromResolvedJournal
          resolvedJournal (contextSource context) input
        pureState = enterActualAddPreview preview (ActualAddState input EditingActualAdd)
    case actualAddMode pureState of
      ShowingActualAddPreview shownPreview ->
        put (AppWrapper context (ShowPreview shownPreview form))
      _ -> put (AppWrapper context (InputForm form))
  _ -> zoom zoomForm (handleFormEvent event)

handlePreviewEvent
  :: AppContext
  -> ActualAddPreview
  -> Form ActualAddInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handlePreviewEvent context preview form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey (V.KChar 'b') []) -> put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey (V.KChar 'B') []) -> put (AppWrapper context (InputForm form))
  VtyEvent (V.EvKey V.KEnter []) -> publishReadyActualPreview context preview form
  VtyEvent (V.EvKey (V.KChar 'y') []) -> publishReadyActualPreview context preview form
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> publishReadyActualPreview context preview form
  VtyEvent (V.EvKey (V.KChar 'c') []) -> publishReadyActualPreview context preview form
  VtyEvent (V.EvKey (V.KChar 'C') []) -> publishReadyActualPreview context preview form
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()

publishReadyActualPreview
  :: AppContext
  -> ActualAddPreview
  -> Form ActualAddInput AppEvent Name
  -> EventM Name AppWrapper ()
publishReadyActualPreview context preview form = case preview of
  ActualAddCandidateReady block ->
    let stickyDay = fromMaybe (contextEntryDay context)
          (readMaybe (T.unpack (addDateText (formState form))))
    in publishActualCandidate context stickyDay block
  _ -> pure ()

handleMultiInputEvent
  :: AppContext
  -> ActualMultiAddState
  -> Form MultiEditInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleMultiInputEvent context state form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put (AppWrapper context Workspace)
  VtyEvent (V.EvKey V.KEnter []) -> prepareMultiPreview context state form
  VtyEvent (V.EvKey V.KUp []) -> moveMultiSelection context (-1) state form
  VtyEvent (V.EvKey V.KDown []) -> moveMultiSelection context 1 state form
  _ -> zoom zoomMultiForm (handleFormEvent event)

replaceMultiState
  :: AppContext
  -> ActualMultiAddState
  -> Form MultiEditInput AppEvent Name
  -> EventM Name AppWrapper ()
replaceMultiState context state form =
  put (AppWrapper context (MultiInput state (syncMultiForm state form)))

moveMultiSelection
  :: AppContext
  -> Int
  -> ActualMultiAddState
  -> Form MultiEditInput AppEvent Name
  -> EventM Name AppWrapper ()
moveMultiSelection context offset state form =
  let committed = commitMultiForm state form
      selected = actualMultiSelectedPosting committed + offset
      moved = selectActualMultiPosting selected committed
  in replaceMultiState context moved form

prepareMultiPreview
  :: AppContext
  -> ActualMultiAddState
  -> Form MultiEditInput AppEvent Name
  -> EventM Name AppWrapper ()
prepareMultiPreview context state form = do
  let committed = commitMultiForm state form
      resolvedJournal = actualJournalValue
        (householdStateActualJournal (contextHouseholdState context))
      preview = prepareActualMultiAddPreviewFromResolvedJournal
        resolvedJournal (contextSource context) (actualMultiAddInput committed)
  put (AppWrapper context (MultiShowPreview preview committed (syncMultiForm committed form)))

handleMultiPreviewEvent
  :: AppContext
  -> ActualMultiAddPreview
  -> ActualMultiAddState
  -> Form MultiEditInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleMultiPreviewEvent context preview state form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put (AppWrapper context (MultiInput state form))
  VtyEvent (V.EvKey (V.KChar 'b') []) -> put (AppWrapper context (MultiInput state form))
  VtyEvent (V.EvKey (V.KChar 'B') []) -> put (AppWrapper context (MultiInput state form))
  VtyEvent (V.EvKey V.KEnter []) -> publishReadyMultiPreview context preview state
  VtyEvent (V.EvKey (V.KChar 'y') []) -> publishReadyMultiPreview context preview state
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> publishReadyMultiPreview context preview state
  VtyEvent (V.EvKey (V.KChar 'c') []) -> publishReadyMultiPreview context preview state
  VtyEvent (V.EvKey (V.KChar 'C') []) -> publishReadyMultiPreview context preview state
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()

publishReadyMultiPreview
  :: AppContext
  -> ActualMultiAddPreview
  -> ActualMultiAddState
  -> EventM Name AppWrapper ()
publishReadyMultiPreview context preview state = case preview of
  ActualMultiAddCandidateReady block ->
    let stickyDay = fromMaybe (contextEntryDay context)
          (readMaybe (T.unpack (multiAddDateText (actualMultiAddInput state))))
    in publishActualCandidate context stickyDay block
  _ -> pure ()

publishActualCandidate
  :: AppContext
  -> Day
  -> Text
  -> EventM Name AppWrapper ()
publishActualCandidate context stickyDay block = do
  let stickyContext = context { contextEntryDay = stickyDay }
  writeResult <- suspendAndResume'
    (publishActualBlockFromResolvedJournal
      (contextSourcePath context) (contextSource context) block)
  let writeOutcome = classifyActualAddWriteResult writeResult
  case writeOutcome of
    ActualAddWriteSucceeded -> do
      reloadedContext <- suspendAndResume' (reloadWorkspaceContext stickyContext)
      case reloadedContext of
        Nothing -> put (AppWrapper context ShowWorkspaceReloadFailure)
        Just freshContext -> put (AppWrapper freshContext Workspace)
    _ -> put (AppWrapper context (ShowWriteOutcome writeOutcome))

handleReverseInputEvent
  :: AppContext
  -> ActualTransactionId
  -> Transaction
  -> Form ActualReverseInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleReverseInputEvent context targetId transaction form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put (AppWrapper context Workspace)
  VtyEvent (V.EvKey V.KEnter []) -> do
    let resolvedJournal = actualJournalValue
          (householdStateActualJournal (contextHouseholdState context))
        preview = prepareActualReverseInputFromResolvedJournal
          resolvedJournal (contextSource context) targetId (formState form)
    put (AppWrapper context
      (ReverseShowPreview targetId transaction preview form))
  _ -> zoom zoomReverseForm (handleFormEvent event)

handleReversePreviewEvent
  :: AppContext
  -> ActualTransactionId
  -> Transaction
  -> ActualReverseInputPreview
  -> Form ActualReverseInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleReversePreviewEvent context targetId transaction preview form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey (V.KChar 'b') []) -> back
  VtyEvent (V.EvKey (V.KChar 'B') []) -> back
  VtyEvent (V.EvKey V.KEnter []) -> publish
  VtyEvent (V.EvKey (V.KChar 'y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()
  where
    back = put (AppWrapper context (ReverseInputForm targetId transaction form))
    publish = publishReadyReversePreview context preview

publishReadyReversePreview
  :: AppContext
  -> ActualReverseInputPreview
  -> EventM Name AppWrapper ()
publishReadyReversePreview context preview = case preview of
  ActualReverseCandidateReady block ->
    publishActualCandidate context (contextEntryDay context) block
  _ -> pure ()

handleReverseUnavailableEvent
  :: AppContext
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handleReverseUnavailableEvent context event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey V.KEnter []) -> back
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()
  where
    back = put (AppWrapper context Workspace)

handlePlanInputEvent
  :: AppContext
  -> PlanAdvanceProposal
  -> Form PlanCompleteAdvanceInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handlePlanInputEvent context proposal form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put (AppWrapper context Workspace)
  VtyEvent (V.EvKey V.KEnter []) -> preparePlanPreview context proposal form
  _ -> zoom zoomPlanForm (handleFormEvent event)

preparePlanPreview
  :: AppContext
  -> PlanAdvanceProposal
  -> Form PlanCompleteAdvanceInput AppEvent Name
  -> EventM Name AppWrapper ()
preparePlanPreview context proposal form =
  case parsePlanCompleteAdvanceInput proposal (formState form) of
    Left inputError ->
      put (AppWrapper context
        (PlanShowPreview proposal
          (PlanPreviewRejected ("Input rejected: " <> T.pack (show inputError))) form))
    Right intent -> case preparePlanCompleteAdvance
        (householdStatePlanJournal state)
        (householdStateActualJournal state)
        (contextPlanSource context)
        (contextSource context)
        intent of
      Left errors -> put (AppWrapper context
        (PlanShowPreview proposal
          (PlanPreviewRejected
            ("Plan completion rejected: " <> T.pack (show (NonEmpty.toList errors)))) form))
      Right preview -> put (AppWrapper context
        (PlanShowPreview proposal (PlanPreviewReady preview) form))
  where
    state = contextHouseholdState context

handlePlanPreviewEvent
  :: AppContext
  -> PlanAdvanceProposal
  -> PlanPreviewResult
  -> Form PlanCompleteAdvanceInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handlePlanPreviewEvent context proposal result form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put (AppWrapper context (PlanInputForm proposal form))
  VtyEvent (V.EvKey (V.KChar 'b') []) -> put (AppWrapper context (PlanInputForm proposal form))
  VtyEvent (V.EvKey (V.KChar 'B') []) -> put (AppWrapper context (PlanInputForm proposal form))
  VtyEvent (V.EvKey (V.KChar 'c') []) -> continuePlanPreview
  VtyEvent (V.EvKey (V.KChar 'C') []) -> continuePlanPreview
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()
  where
    continuePlanPreview = case result of
      PlanPreviewRejected _ -> pure ()
      PlanPreviewReady preview ->
        put (AppWrapper context (PlanShowConfirmation proposal preview form))

handlePlanConfirmationEvent
  :: AppContext
  -> PlanAdvanceProposal
  -> PlanCompleteAdvancePreview
  -> Form PlanCompleteAdvanceInput AppEvent Name
  -> BrickEvent Name AppEvent
  -> EventM Name AppWrapper ()
handlePlanConfirmationEvent context proposal preview form event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> back
  VtyEvent (V.EvKey (V.KChar 'n') []) -> back
  VtyEvent (V.EvKey (V.KChar 'N') []) -> back
  VtyEvent (V.EvKey (V.KChar 'y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'Y') []) -> publish
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()
  where
    back = put (AppWrapper context
      (PlanShowPreview proposal (PlanPreviewReady preview) form))
    publish = acceptPlanConfirmation context preview

acceptPlanConfirmation
  :: AppContext
  -> PlanCompleteAdvancePreview
  -> EventM Name AppWrapper ()
acceptPlanConfirmation context preview = do
  let state = contextHouseholdState context
      paths = householdStatePaths state
      root = householdStateRoot state
      planPath = householdPlanJournalPath paths
      intent = PlanCompleteAdvanceWriteIntent
        { writeActualPath = contextSourcePath context
        , writeExpectedActual = contextSource context
        , writeCandidateActual = completeAdvanceActualSource preview
        , writePlanPath = planPath
        , writeExpectedPlan = contextPlanSource context
        , writeCandidatePlan = completeAdvancePlanSource preview
        }
      postAdmission = loadCanonicalHousehold root
  writeResult <- suspendAndResume' (publishPlanCompleteAdvance postAdmission intent)
  case writeResult of
    Right () -> do
      reloaded <- suspendAndResume'
        (reloadWorkspaceContext (context { contextCurrentSection = PlansSection }))
      case reloaded of
        Nothing -> put (AppWrapper context ShowWorkspaceReloadFailure)
        Just freshContext -> put (AppWrapper
          (freshContext { contextCurrentSection = PlansSection }) Workspace)
    Left writeError -> put (AppWrapper context
      (PlanShowWriteOutcome (renderPlanWriteError writeError)))

renderPlanWriteError
  :: PlanCompleteAdvanceWriteError admissionError
  -> Text
renderPlanWriteError writeError = case writeError of
  PlanCompleteAdvanceActualStale ->
    "actual.journal changed after preview. Nothing was published."
  PlanCompleteAdvancePlanStale ->
    "plan.journal changed after preview. Nothing was published."
  PlanCompleteAdvancePostAdmissionFailed _ actualRestored planRestored ->
    "Whole-Household post-admission failed. Actual restored: "
      <> yesNo actualRestored <> "; Plan restored: " <> yesNo planRestored
  PlanCompleteAdvanceFileIOError _ actualRestored planRestored ->
    "Filesystem publication failed. Actual restored: "
      <> yesNo actualRestored <> "; Plan restored: " <> yesNo planRestored
  where
    yesNo True = "YES"
    yesNo False = "NO"

handlePlanOutcomeEvent :: AppContext -> BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handlePlanOutcomeEvent context event = case event of
  VtyEvent (V.EvKey V.KEsc []) -> put (AppWrapper context Workspace)
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  _ -> pure ()

reloadWorkspaceContext :: AppContext -> IO (Maybe AppContext)
reloadWorkspaceContext context = do
  let root = householdStateRoot (contextHouseholdState context)
  loadResult <- loadCanonicalHousehold root
  case loadResult of
    Left _ -> pure Nothing
    Right freshState -> do
      let freshPaths = householdStatePaths freshState
          actualPath = householdActualJournalPath freshPaths
          planPath = householdPlanJournalPath freshPaths
      actualResult <- tryIOError (TIO.readFile actualPath)
      planResult <- tryIOError (TIO.readFile planPath)
      case (actualResult, planResult) of
        (Right freshActual, Right freshPlan) ->
          pure (Just
            ((makeWorkspaceContext True
                (contextObservationDay context)
                actualPath freshActual freshPlan freshState)
              { contextEntryDay = contextEntryDay context
              , contextCurrentSection = contextCurrentSection context
              }))
        _ -> pure Nothing

handleWriteOutcomeEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
handleWriteOutcomeEvent = handleExitOnlyEvent

handleExitOnlyEvent :: BrickEvent Name AppEvent -> EventM Name AppWrapper ()
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
  -> Text
  -> HouseholdState
  -> AppContext
makeWorkspaceContext focusLatest today journalFile source planSource state =
  AppContext
    { contextHouseholdState = state
    , contextCurrentSection = ActualSection
    , contextSelectedReport = ReportTrialBalance
    , contextObservationDay = today
    , contextEntryDay = today
    , contextWorkspaceAccounts = workspaceAccounts
    , contextWorkspaceList = workspaceList
    , contextWorkspaceFocus = TransactionsFocus
    , contextPlanList = planList
    , contextSourcePath = journalFile
    , contextSource = source
    , contextPlanSource = planSource
    }
  where
    declarations = accountDeclarations (householdStateAccountsRegistry state)
    transactions =
      map actualTransactionEntryTransaction
        (actualJournalTransactionEntries (householdStateActualJournal state))
    workspaceAccounts = L.list WorkspaceAccountList
      (Vec.fromList (Nothing : map (Just . declaredAccount) declarations)) 1
    initialWorkspaceList = L.list WorkspaceTransactionList (Vec.fromList transactions) 1
    workspaceList
      | focusLatest && not (null transactions) =
          L.listMoveTo (length transactions - 1) initialWorkspaceList
      | otherwise = initialWorkspaceList
    closedPlanIds = map declaredCompletionPlanId
      (actualJournalCompletionDeclarations (householdStateActualJournal state))
    openPlans = filter
      (\identified -> identifiedPlanId identified `notElem` closedPlanIds)
      (planJournalTransactions (householdStatePlanJournal state))
    planList = L.list PlanList (Vec.fromList openPlans) 1

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
        Right value -> pure value
      householdResult <- loadCanonicalHousehold root
      state <- case householdResult of
        Left errs -> die
          ("Failed to load canonical Household:\n"
            <> unlines (map show (NonEmpty.toList errs)))
        Right value -> pure value
      let paths = householdStatePaths state
          journalFile = householdActualJournalPath paths
          planFile = householdPlanJournalPath paths
      actualRead <- tryIOError (TIO.readFile journalFile)
      source <- case actualRead of
        Left err -> die ("Cannot read actual.journal: " <> show err)
        Right content -> pure content
      planRead <- tryIOError (TIO.readFile planFile)
      planSource <- case planRead of
        Left err -> die ("Cannot read plan.journal: " <> show err)
        Right content -> pure content
      let context = makeWorkspaceContext False today journalFile source planSource state
          initialState = AppWrapper context Workspace
          buildVty = mkVty V.defaultConfig
      initialVty <- buildVty
      _ <- customMain initialVty buildVty Nothing app initialState
      pure ()
    _ -> die "Usage: h-kernel-editor-tui <household-root-or-actual.journal>"
