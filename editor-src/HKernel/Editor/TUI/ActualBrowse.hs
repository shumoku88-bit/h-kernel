{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.ActualBrowse
  ( ActualIdentityStatus(..)
  , ActualBrowseRow(..)
  , ActualBrowseState(..)
  , ActualBrowseAction(..)
  , buildActualBrowseRows
  , initialActualBrowseState
  , initialActualBrowseStateFromSnapshot
  , selectedBrowseRow
  , transitionActualBrowse
  ) where

import HKernel.Actual.Journal
  ( ActualJournal
  , ActualTransactionIdentity(..)
  , ActualTransactionRecord(..)
  , actualJournalRecords
  )
import HKernel.Editor.TUI.ActualSourceSnapshot
  ( ActualSourceSnapshot
  , actualSnapshotJournal
  )
import HKernel.Ledger (Transaction)
import HKernel.Plan (PlanId)
import HKernel.Plan.Completion (ActualTransactionId)

-- | Explicit distinction between durable event identities, rebuildable plan runtime identities, and ordinary un-identified transactions.
data ActualIdentityStatus
  = ActualHasExplicitDurableIdentity ActualTransactionId
  | ActualHasPlanDerivedRuntimeIdentity PlanId ActualTransactionId
  | ActualHasNoIdentity
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
          ActualWithExplicitEventIdentity actualId ->
            ActualHasExplicitDurableIdentity actualId
          ActualWithPlanDerivedRuntimeIdentity planId actualId ->
            ActualHasPlanDerivedRuntimeIdentity planId actualId
          ActualWithoutIdentity ->
            ActualHasNoIdentity
      , rowReverses = actualRecordReverses record
      }

initialActualBrowseState :: ActualJournal -> ActualBrowseState
initialActualBrowseState journal = ActualBrowseState
  { browseRows = buildActualBrowseRows journal
  , browseSelectedIndex = 0
  }

initialActualBrowseStateFromSnapshot :: ActualSourceSnapshot -> ActualBrowseState
initialActualBrowseStateFromSnapshot snapshot =
  initialActualBrowseState (actualSnapshotJournal snapshot)

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
