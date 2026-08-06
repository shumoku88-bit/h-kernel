{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.ActualSourceSnapshot
  ( ActualSourceSnapshot
  , ActualSourceLoadFailure(..)
  , ActualSourceOperation(..)
  , ActualSourceReader(..)
  , actualSnapshotSource
  , actualSnapshotJournal
  , actualSnapshotAccountNames
  , admitActualSourceSnapshot
  , loadActualSourceSnapshot
  , loadActualSourceSnapshotUsing
  ) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import qualified Data.Text.IO as TIO

import HKernel.Account
  ( accountDeclarations
  , accountName
  , declaredAccount
  )
import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalValue
  , parseActualJournal
  )
import HKernel.Journal (journalAccountRegistry)

-- | Sanitized classification of source snapshot loading or admission failures.
-- Must never include raw source text, filesystem paths, exception details, or full parser errors.
data ActualSourceLoadFailure
  = ActualSourceFileReadFailed
  | ActualSourceAdmissionFailed
  deriving (Eq, Show)

-- | Identifies which TUI operation requested the source snapshot.
data ActualSourceOperation
  = LoadForActualAdd
  | LoadForActualBrowse
  deriving (Eq, Show)

-- | An immutable, admitted snapshot of the current Actual source file.
-- Retains source text, admitted journal, and account names from a single admission pass.
-- Does not derive 'Show' to avoid accidental leakage of full source contents in error messages.
data ActualSourceSnapshot = ActualSourceSnapshot
  { actualSnapshotSource       :: Text
  , actualSnapshotJournal      :: ActualJournal
  , actualSnapshotAccountNames :: [Text]
  }

-- | Injectable text reader boundary for reading source files.
newtype ActualSourceReader = ActualSourceReader
  { readActualSourceText :: FilePath -> IO Text
  }

-- | Admits a raw source text into an 'ActualSourceSnapshot'.
-- Guarantees that source text, admitted journal, and account names are derived atomically from one admission.
admitActualSourceSnapshot
  :: Text
  -> Either ActualSourceLoadFailure ActualSourceSnapshot
admitActualSourceSnapshot source = case parseActualJournal source of
  Left _ -> Left ActualSourceAdmissionFailed
  Right journal ->
    let declarations =
          accountDeclarations
            (journalAccountRegistry (actualJournalValue journal))
        accounts = map (accountName . declaredAccount) declarations
    in Right ActualSourceSnapshot
        { actualSnapshotSource = source
        , actualSnapshotJournal = journal
        , actualSnapshotAccountNames = accounts
        }

-- | Reads source file using custom reader and admits it into an 'ActualSourceSnapshot'.
loadActualSourceSnapshotUsing
  :: ActualSourceReader
  -> FilePath
  -> IO (Either ActualSourceLoadFailure ActualSourceSnapshot)
loadActualSourceSnapshotUsing reader path = do
  readResult <- try (readActualSourceText reader path) :: IO (Either IOException Text)
  case readResult of
    Left _ -> pure (Left ActualSourceFileReadFailed)
    Right source -> pure (admitActualSourceSnapshot source)

-- | Default file-based loader reading directly from filesystem.
loadActualSourceSnapshot
  :: FilePath
  -> IO (Either ActualSourceLoadFailure ActualSourceSnapshot)
loadActualSourceSnapshot =
  loadActualSourceSnapshotUsing (ActualSourceReader TIO.readFile)
