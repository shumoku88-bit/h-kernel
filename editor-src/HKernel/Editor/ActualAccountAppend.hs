{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.ActualAccountAppend
  ( ActualAccountAppendError(..)
  , ActualAccountAppendPreview(..)
  , prepareActualAccountAppend
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)

import HKernel.Account
  ( Account
  , AccountDeclaration
  , AccountRegistry
  , AccountRegistryError(..)
  , declaredAccount
  , lookupAccountDeclaration
  , registerAccount
  )
import HKernel.Account.Journal
  ( AccountDeclarationRenderError
  , renderAccountDeclaration
  )
import HKernel.Actual.Journal
  ( ActualJournalError
  , ActualJournal
  , actualJournalValue
  , parseActualJournal
  )
import HKernel.Editor.SourceAppend (appendSourceBlock)
import HKernel.Journal
  ( journalAccountRegistry
  )

data ActualAccountAppendError
  = SourceParseError (NonEmpty ActualJournalError)
  | CandidateSourceParseError (NonEmpty ActualJournalError)
  | DuplicateDeclaration Account
  | DeclarationRenderError AccountDeclarationRenderError
  | CandidateDeclarationRoundTripMismatch
  deriving (Eq, Show)

data ActualAccountAppendPreview = ActualAccountAppendPreview
  { candidateBlock          :: Text
  , candidateCompleteSource :: Text
  } deriving (Eq, Show)

prepareActualAccountAppend
  :: Text
  -> AccountDeclaration
  -> Either (NonEmpty ActualAccountAppendError) ActualAccountAppendPreview
prepareActualAccountAppend existingSource declaration = do
  journal <- parseSource existingSource
  _ <- verifyNotDuplicate
    (journalAccountRegistry (actualJournalValue journal))
    declaration
  block <- first (pure . DeclarationRenderError)
    (renderAccountDeclaration declaration)
  let preview = buildPreview existingSource block
  candidateJournal <- first (pure . CandidateSourceParseError)
    (parseActualJournal (candidateCompleteSource preview))
  verifyExactCandidateDeclaration candidateJournal declaration
  pure preview

parseSource :: Text -> Either (NonEmpty ActualAccountAppendError) ActualJournal
parseSource = first (pure . SourceParseError) . parseActualJournal

verifyNotDuplicate
  :: AccountRegistry
  -> AccountDeclaration
  -> Either (NonEmpty ActualAccountAppendError) AccountRegistry
verifyNotDuplicate registry declaration =
  case registerAccount declaration registry of
    Left (DuplicateAccountDeclaration account) ->
      Left (pure (DuplicateDeclaration account))
    Right newRegistry -> Right newRegistry

verifyExactCandidateDeclaration
  :: ActualJournal
  -> AccountDeclaration
  -> Either (NonEmpty ActualAccountAppendError) ()
verifyExactCandidateDeclaration journal expected =
  case lookupAccountDeclaration
      (declaredAccount expected)
      (journalAccountRegistry (actualJournalValue journal)) of
    Just actual | actual == expected -> Right ()
    _ -> Left (pure CandidateDeclarationRoundTripMismatch)

buildPreview :: Text -> Text -> ActualAccountAppendPreview
buildPreview existingSource block =
  ActualAccountAppendPreview
    { candidateBlock = block
    , candidateCompleteSource = appendSourceBlock existingSource block
    }
