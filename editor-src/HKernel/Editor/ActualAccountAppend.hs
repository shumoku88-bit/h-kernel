{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.ActualAccountAppend
  ( ActualAccountAppendError(..)
  , ActualAccountAppendPreview(..)
  , prepareActualAccountAppend
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text as T

import HKernel.Account
  ( Account
  , AccountDeclaration
  , declaredAccount
  , declaredAccountDefaultCommodity
  , declaredAccountType
  , accountName
  , AccountRegistry
  , AccountRegistryError(..)
  , registerAccount
  )
import HKernel.Actual.Journal
  ( ActualJournalError
  , ActualJournal
  , actualJournalValue
  , parseActualJournal
  )
import HKernel.Journal
  ( journalAccountRegistry
  )
import HKernel.Money (commodityCode)
import HKernel.Editor.ActualAppend (appendBlock)

data ActualAccountAppendError
  = SourceParseError (NonEmpty ActualJournalError)
  | CandidateSourceParseError (NonEmpty ActualJournalError)
  | DuplicateDeclaration Account
  deriving (Eq, Show)

data ActualAccountAppendPreview = ActualAccountAppendPreview
  { candidateBlock          :: Text
  , candidateCompleteSource :: Text
  } deriving (Eq, Show)

prepareActualAccountAppend
  :: Text
  -> AccountDeclaration
  -> Either (NonEmpty ActualAccountAppendError) ActualAccountAppendPreview
prepareActualAccountAppend existingSource decl = do
  journal <- parseSource existingSource
  _ <- verifyNotDuplicate (journalAccountRegistry (actualJournalValue journal)) decl
  
  let preview = buildPreview existingSource decl
  
  _ <- first (pure . CandidateSourceParseError) (parseActualJournal (candidateCompleteSource preview))
  pure preview

parseSource :: Text -> Either (NonEmpty ActualAccountAppendError) ActualJournal
parseSource = first (pure . SourceParseError) . parseActualJournal

verifyNotDuplicate
  :: AccountRegistry
  -> AccountDeclaration
  -> Either (NonEmpty ActualAccountAppendError) AccountRegistry
verifyNotDuplicate registry decl =
  case registerAccount decl registry of
    Left (DuplicateAccountDeclaration acc) -> Left (pure (DuplicateDeclaration acc))
    Right newRegistry -> Right newRegistry

buildPreview :: Text -> AccountDeclaration -> ActualAccountAppendPreview
buildPreview existingSource decl =
  ActualAccountAppendPreview
    { candidateBlock = block
    , candidateCompleteSource = appendBlock existingSource block
    }
  where
    block = renderAccountDeclaration decl

renderAccountDeclaration :: AccountDeclaration -> Text
renderAccountDeclaration decl = T.unlines $
  [ "account " <> accountName (declaredAccount decl)
  , "  type: " <> T.pack (show (declaredAccountType decl))
  ] ++ [ "  commodity: " <> commodityCode c | Just c <- [declaredAccountDefaultCommodity decl] ]
