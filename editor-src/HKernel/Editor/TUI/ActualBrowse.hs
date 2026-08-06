{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.ActualBrowse
  ( ActualIdentityStatus(..)
  , ActualBrowseRow(..)
  , ActualBrowseState(..)
  , ActualBrowseAction(..)
  , ActualBrowseLoadFailure(..)
  , buildActualBrowseRows
  , initialActualBrowseState
  , selectedBrowseRow
  , transitionActualBrowse
  , classifyActualBrowseLoad
  ) where

import Data.Text (Text)

import HKernel.Actual.Journal
  ( ActualJournal
  , ActualTransactionIdentity(..)
  , ActualTransactionRecord(..)
  , actualJournalRecords
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

-- | Sanitized classification of browser load failures without raw source, exception, or path details.
data ActualBrowseLoadFailure
  = ActualBrowseFileReadFailed
  | ActualBrowseAdmissionFailed
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

-- | Purely classify file-read and journal-parsing outcomes into browser states or sanitized failure kinds.
classifyActualBrowseLoad
  :: Either e1 Text
  -> (Text -> Either e2 ActualJournal)
  -> Either ActualBrowseLoadFailure ActualBrowseState
classifyActualBrowseLoad readOutcome parseJournalFunc = case readOutcome of
  Left _ -> Left ActualBrowseFileReadFailed
  Right source -> case parseJournalFunc source of
    Left _ -> Left ActualBrowseAdmissionFailed
    Right journal -> Right (initialActualBrowseState journal)
