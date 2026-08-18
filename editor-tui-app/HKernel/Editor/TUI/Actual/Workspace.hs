{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Actual.Workspace
  ( WorkspaceAction(..)
  , applyWorkspaceAccountFilter
  , drawWorkspace
  , handleWorkspaceEvent
  , selectedWorkspaceReverseTarget
  , toggleWorkspaceFocus
  ) where

import Brick
import Brick.Widgets.Border
import qualified Brick.Widgets.List as L
import qualified Graphics.Vty as V

import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as Vec

import qualified HKernel.Account
import HKernel.Actual.Journal
  ( ActualTransactionEntry
  , actualJournalTransactionEntries
  , actualTransactionEntryTransaction
  )
import HKernel.Editor.ActualWorkspace
  ( ActualReverseAvailability(..)
  , actualReverseAvailability
  , newestTransactionEntriesForAccount
  )
import HKernel.Editor.TUI.Model
  ( AppContext(..)
  , AppEvent
  , Name(..)
  , WorkspaceFocus(..)
  , contextHouseholdState
  , contextWorkspaceAccountsL
  , contextWorkspaceListL
  )
import HKernel.Household.Application (HouseholdState(..))
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
import HKernel.Plan.Completion
  ( ActualTransactionId
  , actualTransactionIdText
  )

data WorkspaceAction
  = MaintainContext
  | OpenDaily
  | OpenIncome
  | OpenRecord
  | OpenReconcile HKernel.Account.Account
  | OpenReverse

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
    , txtWrap ("Filter: " <> workspaceFilterText context)
    , vBox
        [ txtWrap "Navigate: [1-7] Sections  [Tab/Left/Right] Focus  [j/k/Arrows] Move"
        , txtWrap "Record:   [r] Record (2+ postings)  [a] Expense  [i] Income"
        , txtWrap ("Observe:  " <> workspaceReconcileHint context)
        , txtWrap "Action:   [Enter] Reverse selected  [q] Quit"
        ]
    ]

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name AppContext WorkspaceAction
handleWorkspaceEvent event = case event of
  MouseDown WorkspaceAccountList V.BScrollUp _ _ ->
    selectAccountEvent (V.EvKey V.KUp [])
  MouseDown WorkspaceAccountList V.BScrollDown _ _ ->
    selectAccountEvent (V.EvKey V.KDown [])
  MouseDown WorkspaceAccountList V.BLeft _ (Location (_, row)) -> do
    zoom contextWorkspaceAccountsL (modify (L.listMoveTo row))
    modify (\ctx -> applyWorkspaceAccountFilter
      (ctx { contextWorkspaceFocus = AccountsFocus }))
    pure MaintainContext
  MouseDown WorkspaceTransactionList V.BScrollUp _ _ ->
    selectTransactionEvent (V.EvKey V.KUp [])
  MouseDown WorkspaceTransactionList V.BScrollDown _ _ ->
    selectTransactionEvent (V.EvKey V.KDown [])
  MouseDown WorkspaceTransactionList V.BLeft _ (Location (_, row)) -> do
    zoom contextWorkspaceListL (modify (L.listMoveTo row))
    modify (\ctx -> ctx { contextWorkspaceFocus = TransactionsFocus })
    pure MaintainContext
  VtyEvent (V.EvKey (V.KChar 'a') []) -> pure OpenDaily
  VtyEvent (V.EvKey (V.KChar 'A') []) -> pure OpenDaily
  VtyEvent (V.EvKey (V.KChar 'i') []) -> pure OpenIncome
  VtyEvent (V.EvKey (V.KChar 'I') []) -> pure OpenIncome
  VtyEvent (V.EvKey (V.KChar 'r') []) -> pure OpenRecord
  VtyEvent (V.EvKey (V.KChar 'R') []) -> pure OpenRecord
  VtyEvent (V.EvKey (V.KChar 'c') []) -> selectedReconcileAction
  VtyEvent (V.EvKey (V.KChar 'C') []) -> selectedReconcileAction
  VtyEvent (V.EvKey V.KEnter []) -> do
    context <- get
    if contextWorkspaceFocus context == AccountsFocus
      then do
        modify (\ctx -> ctx { contextWorkspaceFocus = TransactionsFocus })
        pure MaintainContext
      else pure OpenReverse
  VtyEvent (V.EvKey (V.KChar '\t') []) -> do
    modify toggleWorkspaceFocus
    pure MaintainContext
  VtyEvent (V.EvKey V.KLeft []) -> do
    modify (\ctx -> ctx { contextWorkspaceFocus = AccountsFocus })
    pure MaintainContext
  VtyEvent (V.EvKey V.KRight []) -> do
    modify (\ctx -> ctx { contextWorkspaceFocus = TransactionsFocus })
    pure MaintainContext
  VtyEvent (V.EvKey vtyKey vtyMods) -> do
    context <- get
    case contextWorkspaceFocus context of
      AccountsFocus -> selectAccountEvent (V.EvKey vtyKey vtyMods)
      TransactionsFocus -> selectTransactionEvent (V.EvKey vtyKey vtyMods)
  _ -> pure MaintainContext
  where
    selectedReconcileAction = do
      context <- get
      pure (maybe MaintainContext OpenReconcile (selectedWorkspaceAccount context))
    selectAccountEvent ev = do
      zoom contextWorkspaceAccountsL (L.handleListEventVi L.handleListEvent ev)
      modify (\ctx -> applyWorkspaceAccountFilter
        (ctx { contextWorkspaceFocus = AccountsFocus }))
      pure MaintainContext
    selectTransactionEvent ev = do
      zoom contextWorkspaceListL (L.handleListEventVi L.handleListEvent ev)
      modify (\ctx -> ctx { contextWorkspaceFocus = TransactionsFocus })
      pure MaintainContext

toggleWorkspaceFocus :: AppContext -> AppContext
toggleWorkspaceFocus context = context
  { contextWorkspaceFocus = case contextWorkspaceFocus context of
      AccountsFocus -> TransactionsFocus
      TransactionsFocus -> AccountsFocus
  }

applyWorkspaceAccountFilter :: AppContext -> AppContext
applyWorkspaceAccountFilter context = context
  { contextWorkspaceList =
      L.list WorkspaceTransactionList (Vec.fromList filteredTransactions) 1
  }
  where
    filteredTransactions =
      map actualTransactionEntryTransaction (filteredWorkspaceEntries context)

workspacePaneLabel :: AppContext -> WorkspaceFocus -> String -> Widget Name
workspacePaneLabel context pane labelText
  | contextWorkspaceFocus context == pane = str (labelText <> " *")
  | otherwise = str labelText

renderWorkspaceAccount :: Bool -> Maybe HKernel.Account.Account -> Widget Name
renderWorkspaceAccount selected maybeAccount
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    row = case maybeAccount of
      Nothing -> str "All accounts"
      Just account -> txt (HKernel.Account.accountName account)

workspaceFilterText :: AppContext -> Text
workspaceFilterText context = case selectedWorkspaceAccount context of
  Nothing -> "All accounts"
  Just account -> HKernel.Account.accountName account

workspaceReconcileHint :: AppContext -> Text
workspaceReconcileHint context = case selectedWorkspaceAccount context of
  Nothing -> "[c] Compare balance (select one Account first)"
  Just _ -> "[c] Compare external balance"

selectedWorkspaceAccount :: AppContext -> Maybe HKernel.Account.Account
selectedWorkspaceAccount context = case L.listSelectedElement (contextWorkspaceAccounts context) of
  Nothing -> Nothing
  Just (_, maybeAccount) -> maybeAccount

filteredWorkspaceEntries :: AppContext -> [ActualTransactionEntry]
filteredWorkspaceEntries context =
  newestTransactionEntriesForAccount
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
  Just entry -> case actualReverseAvailability actualJournal entry of
    ActualReverseIdentityMissing -> Left
      "Reverse unavailable: this transaction has no durable Actual identity."
    ActualReverseAvailable targetId ->
      Right (targetId, actualTransactionEntryTransaction entry)
    ActualReverseAlreadyReversed _ reversalId -> Left
      ("Already reversed by " <> actualTransactionIdText reversalId
        <> ". Select that reversal if you need to restore the original effect.")
  where
    actualJournal =
      householdStateActualJournal (contextHouseholdState context)

renderWorkspaceTransaction :: Bool -> Transaction -> Widget Name
renderWorkspaceTransaction selected transaction
  | selected = withAttr L.listSelectedAttr row
  | otherwise = row
  where
    -- List rows intentionally remain one line because the list has item height 1.
    -- The complete transaction is preserved in the selected-detail pane below.
    row = txt (T.pack (show (transactionDate transaction)) <> "  "
      <> transactionDescription transaction)

renderWorkspaceSelection :: AppContext -> Widget Name
renderWorkspaceSelection context = case selectedWorkspaceEntry context of
  Nothing -> str "No Actual transactions for this account."
  Just entry ->
    let transaction = actualTransactionEntryTransaction entry
    in vBox
      ( [ txtWrap (T.pack (show (transactionDate transaction)) <> "  "
            <> transactionDescription transaction)
        ]
        ++ map renderPosting (NonEmpty.toList (transactionPostings transaction))
        ++ [str " ", renderReverseAvailability context entry]
      )

renderReverseAvailability :: AppContext -> ActualTransactionEntry -> Widget Name
renderReverseAvailability context entry =
  case actualReverseAvailability actualJournal entry of
    ActualReverseIdentityMissing -> withAttr (attrName "warning")
      (strWrap "Reverse unavailable: no durable Actual identity.")
    ActualReverseAlreadyReversed _ reversalId -> withAttr (attrName "warning")
      (txtWrap ("Already reversed by " <> actualTransactionIdText reversalId
        <> ". Select that reversal to reverse it."))
    ActualReverseAvailable targetId -> withAttr (attrName "success")
      (txtWrap ("[Enter] Reverse  event-id: " <> actualTransactionIdText targetId))
  where
    actualJournal =
      householdStateActualJournal (contextHouseholdState context)

renderPosting :: Posting -> Widget Name
renderPosting posting =
  txtWrap ("  " <> HKernel.Account.accountName (postingAccount posting) <> "  "
    <> renderQuantity (amountQuantity amount) <> " "
    <> commodityCode (amountCommodity amount))
  where
    amount = postingAmount posting
