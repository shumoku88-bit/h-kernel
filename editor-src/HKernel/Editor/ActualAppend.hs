{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.ActualAppend
  ( ActualEditIntent(..)
  , ActualEditError(..)
  , ActualAppendPreview(..)
  , prepareActualAppend
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Time.Calendar (Day)

import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , actualJournalValue
  , parseActualJournal
  )
import HKernel.Editor.SourceAppend (appendSourceBlock)
import HKernel.Editor.TransactionBlock
  ( IntentPosting
  , TransactionBlockError(..)
  , TransactionBlockIntent(..)
  , prepareTransactionBlock
  )
import HKernel.Journal (journalAccountRegistry)

-- | A request to append a new transaction to the Actual journal.
data ActualEditIntent = ActualEditIntent
  { intentDate        :: Day
  , intentDescription :: Text
  , intentPostings    :: NonEmpty IntentPosting
  , intentMetadata    :: [(Text, Text)]
  } deriving (Eq, Show)

data ActualEditError
  = SourceParseError (NonEmpty ActualJournalError)
  | CandidateSourceParseError (NonEmpty ActualJournalError)
  | UndeclaredAccount HKernel.Account.Account
  | MissingCommodity HKernel.Account.Account
  | ZeroAmount HKernel.Account.Account
  | ValidationError HKernel.Ledger.TransactionError
  deriving (Eq, Show)

data ActualAppendPreview = ActualAppendPreview
  { candidateBlock          :: Text
  , candidateCompleteSource :: Text
  } deriving (Eq, Show)

prepareActualAppend
  :: Text
  -> ActualEditIntent
  -> Either (NonEmpty ActualEditError) ActualAppendPreview
prepareActualAppend existingSource intent = do
  journal <- parseSource existingSource
  block <- first (fmap toActualEditError)
    (prepareTransactionBlock
      (journalAccountRegistry (actualJournalValue journal))
      (toTransactionBlockIntent intent))

  let preview = ActualAppendPreview
        { candidateBlock = block
        , candidateCompleteSource = appendSourceBlock existingSource block
        }

  _ <- first (pure . CandidateSourceParseError)
    (parseActualJournal (candidateCompleteSource preview))
  pure preview

parseSource :: Text -> Either (NonEmpty ActualEditError) ActualJournal
parseSource = first (pure . SourceParseError) . parseActualJournal

toTransactionBlockIntent :: ActualEditIntent -> TransactionBlockIntent
toTransactionBlockIntent intent = TransactionBlockIntent
  { blockDate = intentDate intent
  , blockDescription = intentDescription intent
  , blockPostings = intentPostings intent
  , blockMetadata = intentMetadata intent
  }

toActualEditError :: TransactionBlockError -> ActualEditError
toActualEditError blockError = case blockError of
  BlockUndeclaredAccount account -> UndeclaredAccount account
  BlockMissingCommodity account -> MissingCommodity account
  BlockZeroAmount account -> ZeroAmount account
  BlockValidationError transactionError -> ValidationError transactionError
