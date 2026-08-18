{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Actual.AccountSelector
  ( contextActualTransactions
  , flattenCandidateGroups
  , renderInlineAccountSelector
  ) where

import Brick
import Brick.Widgets.Border
import qualified Brick.Widgets.List as L

import Data.Maybe (fromMaybe)
import Data.Text (Text)

import qualified HKernel.Account
import HKernel.Actual.Journal
  ( actualJournalTransactionEntries
  , actualTransactionEntryTransaction
  )
import HKernel.Editor.Interaction.ActualAdd (groupAccountCandidates)
import HKernel.Editor.TUI.Model
  ( AppContext
  , Name(..)
  , contextHouseholdState
  )
import HKernel.Household.Application (HouseholdState(..))
import HKernel.Ledger (Transaction)

renderInlineAccountSelector
  :: AppContext
  -> String
  -> Maybe Int
  -> [HKernel.Account.Account]
  -> Widget Name
renderInlineAccountSelector context label cursor candidates =
  borderWithLabel (str label)
    (hLimit 82
      (padAll 1
        (vBox
          ( map renderCandidate visibleCandidates
            ++ [ str " "
               , strWrap "Existing Accounts are grouped by typed meaning; recent use ranks within each group."
               ]
          ))))
  where
    registry = householdStateAccountsRegistry (contextHouseholdState context)
    indexedCandidates = zip [0 ..] candidates
    visibleCandidates = candidateWindow 9 cursor indexedCandidates
    renderCandidate (index, account) =
      clickable (AccountCandidate index) highlighted
      where
        selected = cursor == Just index
        accountType = HKernel.Account.accountTypeFor account registry
        row = txtWrap
          (accountTypeLabel accountType <> "  " <> HKernel.Account.accountName account)
        highlighted = if selected then withAttr L.listSelectedAttr row else row

accountTypeLabel :: Maybe HKernel.Account.AccountType -> Text
accountTypeLabel maybeType = case maybeType of
  Just HKernel.Account.Asset -> "Assets     "
  Just HKernel.Account.Liability -> "Liabilities"
  Just HKernel.Account.Equity -> "Equity     "
  Just HKernel.Account.Income -> "Income     "
  Just HKernel.Account.Expense -> "Expenses   "
  Nothing -> "Unknown    "

candidateWindow :: Int -> Maybe Int -> [a] -> [a]
candidateWindow limit cursor candidates =
  take limit (drop start candidates)
  where
    selectedIndex = fromMaybe 0 cursor
    maximumStart = max 0 (length candidates - limit)
    centeredStart = max 0 (selectedIndex - limit `div` 2)
    start = min maximumStart centeredStart

flattenCandidateGroups
  :: AppContext
  -> [HKernel.Account.Account]
  -> [HKernel.Account.Account]
flattenCandidateGroups context candidates =
  concatMap snd (groupAccountCandidates registry candidates)
  where
    registry = householdStateAccountsRegistry (contextHouseholdState context)

contextActualTransactions :: AppContext -> [Transaction]
contextActualTransactions context =
  map actualTransactionEntryTransaction
    (actualJournalTransactionEntries
      (householdStateActualJournal (contextHouseholdState context)))
