{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.AccountAppend
  ( AccountJournalAppendError(..)
  , AccountJournalAppendPreview(..)
  , prepareAccountJournalAppend
  , ActualAccountAppendError(..)
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
  , AccountJournalError
  , parseAccountJournal
  , renderAccountDeclaration
  )
import HKernel.Actual.Journal
  ( ActualJournalError
  , ActualJournal
  , actualJournalValue
  , parseActualJournal
  )
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Journal
  ( journalAccountRegistry
  )

-- Account Journal append

-- | Failure to append one declaration to the canonical declaration-only
-- @accounts.journal@ source.
data AccountJournalAppendError
  = AccountJournalSourceParseError (NonEmpty AccountJournalError)
  | AccountJournalCandidateSourceParseError (NonEmpty AccountJournalError)
  | AccountJournalDuplicateDeclaration Account
  | AccountJournalDeclarationRenderError AccountDeclarationRenderError
  | AccountJournalCandidateDeclarationRoundTripMismatch
  deriving (Eq, Show)

data AccountJournalAppendPreview = AccountJournalAppendPreview
  { accountCandidateBlock          :: Text
  , accountCandidateCompleteSource :: Text
  } deriving (Eq, Show)

-- | Prepare one canonical Account declaration append without touching IO.
--
-- The declaration-only Account Journal owns identity/type/default Commodity;
-- Actual transactions are deliberately not involved in this candidate.
prepareAccountJournalAppend
  :: Text
  -> AccountDeclaration
  -> Either (NonEmpty AccountJournalAppendError) AccountJournalAppendPreview
prepareAccountJournalAppend existingSource declaration = do
  registry <- first (pure . AccountJournalSourceParseError)
    (parseAccountJournal existingSource)
  _ <- verifyAccountJournalNotDuplicate registry declaration
  block <- first (pure . AccountJournalDeclarationRenderError)
    (renderAccountDeclaration declaration)
  let preview = AccountJournalAppendPreview
        { accountCandidateBlock = block
        , accountCandidateCompleteSource =
            appendSourceBlock existingSource (SourceBlock block)
        }
  candidateRegistry <- first (pure . AccountJournalCandidateSourceParseError)
    (parseAccountJournal (accountCandidateCompleteSource preview))
  verifyAccountJournalExactCandidateDeclaration candidateRegistry declaration
  pure preview

verifyAccountJournalNotDuplicate
  :: AccountRegistry
  -> AccountDeclaration
  -> Either (NonEmpty AccountJournalAppendError) AccountRegistry
verifyAccountJournalNotDuplicate registry declaration =
  case registerAccount declaration registry of
    Left (DuplicateAccountDeclaration account) ->
      Left (pure (AccountJournalDuplicateDeclaration account))
    Right newRegistry -> Right newRegistry

verifyAccountJournalExactCandidateDeclaration
  :: AccountRegistry
  -> AccountDeclaration
  -> Either (NonEmpty AccountJournalAppendError) ()
verifyAccountJournalExactCandidateDeclaration registry expected =
  case lookupAccountDeclaration (declaredAccount expected) registry of
    Just actual | actual == expected -> Right ()
    _ -> Left (pure AccountJournalCandidateDeclarationRoundTripMismatch)

-- Retained Actual Journal append

-- | Compatibility preparation for the current Actual source while Account
-- declaration ownership moves to @accounts.journal@. New application wiring
-- should use 'prepareAccountJournalAppend' once the native reader cutover lands.
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
    , candidateCompleteSource =
        appendSourceBlock existingSource (SourceBlock block)
    }
