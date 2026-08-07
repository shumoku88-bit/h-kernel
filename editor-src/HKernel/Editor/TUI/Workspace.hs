{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.Workspace
  ( ActualWorkspaceRow(..)
  , buildActualWorkspaceRows
  ) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T

import HKernel.Account (accountName)
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

-- | Read-only presentation data for one Actual transaction in the workspace.
--
-- The row retains the validated transaction so later TUI slices can act on the
-- selected domain value without asking the operator to re-enter hidden IDs or
-- source positions. It never retains complete source text or filesystem paths.
data ActualWorkspaceRow = ActualWorkspaceRow
  { workspaceRowTransaction  :: Transaction
  , workspaceRowSummary      :: Text
  , workspaceRowPostingLines :: [Text]
  } deriving (Eq, Show)

-- | Project admitted transactions into source-order workspace rows.
buildActualWorkspaceRows :: [Transaction] -> [ActualWorkspaceRow]
buildActualWorkspaceRows = map toWorkspaceRow

toWorkspaceRow :: Transaction -> ActualWorkspaceRow
toWorkspaceRow transaction = ActualWorkspaceRow
  { workspaceRowTransaction = transaction
  , workspaceRowSummary =
      T.pack (show (transactionDate transaction))
        <> "  "
        <> transactionDescription transaction
  , workspaceRowPostingLines =
      map renderPosting (NonEmpty.toList (transactionPostings transaction))
  }

renderPosting :: Posting -> Text
renderPosting posting =
  accountName (postingAccount posting)
    <> "  "
    <> renderQuantity (amountQuantity amount)
    <> " "
    <> commodityCode (amountCommodity amount)
  where
    amount = postingAmount posting
