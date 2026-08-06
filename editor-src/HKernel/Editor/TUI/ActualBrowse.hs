{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.ActualBrowse
  ( ActualIdentityStatus(..)
  , ActualBrowseRow(..)
  , ActualBrowseState(..)
  , ActualBrowseAction(..)
  , buildActualBrowseRows
  , initialActualBrowseState
  , selectedBrowseRow
  , transitionActualBrowse
  ) where

import HKernel.Actual.Journal
  ( ActualJournal
  , ActualTransactionRecord(..)
  , actualJournalRecords
  )
import HKernel.Ledger (Transaction)
import HKernel.Plan.Completion (ActualTransactionId)

-- | Explicit distinction between transactions with durable identities and those without.
data ActualIdentityStatus
  = ActualHasDurableIdentity ActualTransactionId
  | ActualHasNoDurableIdentity
  deriving (Eq, Show)

-- | One read-only row projected from an admitted Actual transaction record.
data ActualBrowseRow = ActualBrowseRow
  { rowTransaction    :: Transaction
  , rowIdentityStatus :: ActualIdentityStatus
  , rowReverses       :: Maybe ActualTransactionId
  } deriving (Eq, Show)

-- | Pure state of the read-only Actual transaction browser.
-- Retains rows in source order, never complete source text or filesystem paths.
data ActualBrowseState = ActualBrowseState
  { browseRows          :: [ActualBrowseRow]
  , browseSelectedIndex :: Int
  } deriving (Eq, Show)

data ActualBrowseAction
  = BrowseMoveUp
  | BrowseMoveDown
  | BrowseSelectRow
  deriving (Eq, Show)

buildActualBrowseRows :: ActualJournal -> [ActualBrowseRow]
buildActualBrowseRows journal =
  map recordToRow (actualJournalRecords journal)
  where
    recordToRow record = ActualBrowseRow
      { rowTransaction = actualRecordTransaction record
      , rowIdentityStatus = case actualRecordIdentity record of
          Just actualId -> ActualHasDurableIdentity actualId
          Nothing       -> ActualHasNoDurableIdentity
      , rowReverses = actualRecordReverses record
      }

initialActualBrowseState :: ActualJournal -> ActualBrowseState
initialActualBrowseState journal = ActualBrowseState
  { browseRows = buildActualBrowseRows journal
  , browseSelectedIndex = 0
  }

selectedBrowseRow :: ActualBrowseState -> Maybe ActualBrowseRow
selectedBrowseRow state
  | null rows = Nothing
  | safeIdx >= 0 && safeIdx < length rows = Just (rows !! safeIdx)
  | otherwise = Nothing
  where
    rows = browseRows state
    safeIdx = browseSelectedIndex state

transitionActualBrowse
  :: ActualBrowseAction
  -> ActualBrowseState
  -> ActualBrowseState
transitionActualBrowse action state = case action of
  BrowseMoveUp ->
    let newIdx = max 0 (browseSelectedIndex state - 1)
    in state { browseSelectedIndex = newIdx }
  BrowseMoveDown ->
    let maxIdx = max 0 (length (browseRows state) - 1)
        newIdx = min maxIdx (browseSelectedIndex state + 1)
    in state { browseSelectedIndex = newIdx }
  BrowseSelectRow -> state
