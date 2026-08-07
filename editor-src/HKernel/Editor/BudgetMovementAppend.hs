{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.BudgetMovementAppend
  ( BudgetMovementAppendError(..)
  , BudgetMovementAppendPreview(..)
  , prepareBudgetMovementAppend
  , BudgetJournalMovementAppendError(..)
  , BudgetJournalMovementAppendPreview(..)
  , prepareBudgetJournalMovementAppend
  ) where

import Data.Bifunctor (first)
import Data.Functor.Identity (Identity(..), runIdentity)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Account (Account, AccountRegistry, AccountType(..), accountDeclarations, accountName, accountTypeFor)
import HKernel.Account.Journal (renderAccountDeclaration)
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement(..)
  , HouseholdBudgetMovementJournalError
  , HouseholdBudgetMovementJournalRenderError
  , admitHouseholdBudgetMovementJournal
  , renderHouseholdBudgetMovementTransactions
  )
import HKernel.Household.BudgetMovement.TSV
  ( HouseholdBudgetMovementTSVError
  , parseHouseholdBudgetMovements
  )
import HKernel.Journal
  ( Journal
  , JournalError
  , combineJournalDocuments
  , journalDocumentIncludes
  , parseJournalDocument
  , resolveJournalDocumentIncludes
  , validateJournalDocument
  )
import HKernel.Money (amountCommodity, amountQuantity, commodityCode, renderQuantity)

data BudgetMovementAppendError
  = SourceParseError (NonEmpty HouseholdBudgetMovementTSVError)
  | CandidateSourceParseError (NonEmpty HouseholdBudgetMovementTSVError)
  deriving (Eq, Show)

data BudgetMovementAppendPreview = BudgetMovementAppendPreview
  { candidateBlock          :: Text
  , candidateCompleteSource :: Text
  } deriving (Eq, Show)

prepareBudgetMovementAppend
  :: Text
  -> HouseholdBudgetMovement
  -> Either (NonEmpty BudgetMovementAppendError) BudgetMovementAppendPreview
prepareBudgetMovementAppend existingSource movement = do
  _ <- first (pure . SourceParseError) (parseHouseholdBudgetMovements existingSource)

  let block = renderHouseholdBudgetMovement movement
      preview = BudgetMovementAppendPreview
        { candidateBlock = block
        , candidateCompleteSource =
            appendSourceBlock existingSource (SourceBlock block)
        }

  _ <- first (pure . CandidateSourceParseError)
    (parseHouseholdBudgetMovements (candidateCompleteSource preview))
  pure preview

renderHouseholdBudgetMovement :: HouseholdBudgetMovement -> Text
renderHouseholdBudgetMovement movement = T.intercalate "\t"
  [ T.pack (formatTime defaultTimeLocale "%F" (householdBudgetMovementDate movement))
  , householdBudgetMovementMemo movement
  , accountName (householdBudgetMovementFrom movement)
  , accountName (householdBudgetMovementTo movement)
  , renderQuantity (amountQuantity (householdBudgetMovementAmount movement))
  , "currency=" <> commodityCode (amountCommodity (householdBudgetMovementAmount movement))
  ]

-- Native budget.journal append

data BudgetJournalMovementAppendError
  = BudgetJournalMovementNotBudgetAccount Account
  | BudgetJournalRenderError (NonEmpty HouseholdBudgetMovementJournalRenderError)
  | BudgetJournalCandidateAdmitError (NonEmpty HouseholdBudgetMovementJournalError)
  | BudgetJournalCandidateParseError (NonEmpty JournalError)
  deriving (Eq, Show)

data BudgetJournalMovementAppendPreview = BudgetJournalMovementAppendPreview
  { budgetJournalCandidateBlock          :: Text
  , budgetJournalCandidateCompleteSource :: Text
  } deriving (Eq, Show)

prepareBudgetJournalMovementAppend
  :: AccountRegistry
  -> Text
  -> HouseholdBudgetMovement
  -> Either (NonEmpty BudgetJournalMovementAppendError) BudgetJournalMovementAppendPreview
prepareBudgetJournalMovementAppend registry existingSource movement = do
  _ <- verifyBudgetAccount (householdBudgetMovementFrom movement)
  _ <- verifyBudgetAccount (householdBudgetMovementTo movement)
  block <- first (pure . BudgetJournalRenderError)
    (renderHouseholdBudgetMovementTransactions [movement])

  let preview = BudgetJournalMovementAppendPreview
        { budgetJournalCandidateBlock = block
        , budgetJournalCandidateCompleteSource =
            appendSourceBlock existingSource (SourceBlock block)
        }

  candidateJournal <- first (pure . BudgetJournalCandidateParseError)
    (resolveInMemoryJournal registry (budgetJournalCandidateCompleteSource preview))

  _ <- first (pure . BudgetJournalCandidateAdmitError)
    (admitHouseholdBudgetMovementJournal candidateJournal)

  pure preview
  where
    verifyBudgetAccount acc = case accountTypeFor acc registry of
      Just Budget -> Right ()
      _ -> Left (NonEmpty.singleton (BudgetJournalMovementNotBudgetAccount acc))

resolveInMemoryJournal
  :: AccountRegistry
  -> Text
  -> Either (NonEmpty JournalError) Journal
resolveInMemoryJournal registry input = do
  doc <- parseJournalDocument input
  case renderRegistryText registry of
    Nothing -> validateJournalDocument doc
    Just accText -> case parseJournalDocument accText of
      Left _ -> validateJournalDocument doc
      Right accountsDoc ->
        let resolvedDoc = runIdentity (resolveJournalDocumentIncludes (\_ -> Identity accountsDoc) doc)
        in if null (journalDocumentIncludes doc)
             then validateJournalDocument (combineJournalDocuments accountsDoc resolvedDoc)
             else validateJournalDocument resolvedDoc

renderRegistryText :: AccountRegistry -> Maybe Text
renderRegistryText registry =
  case traverse renderAccountDeclaration (accountDeclarations registry) of
    Left _ -> Nothing
    Right rendered -> Just (T.unlines rendered)
