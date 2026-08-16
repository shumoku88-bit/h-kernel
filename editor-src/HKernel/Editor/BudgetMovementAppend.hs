{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.BudgetMovementAppend
  ( BudgetJournalMovementAppendError(..)
  , BudgetJournalMovementAppendPreview(..)
  , prepareBudgetJournalMovementAppend
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import HKernel.Account
  ( Account
  , AccountRegistry
  , AccountType(..)
  , accountDeclarations
  , accountTypeFor
  )
import HKernel.Account.Journal (renderAccountDeclaration)
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement(..)
  , HouseholdBudgetMovementJournalError
  , HouseholdBudgetMovementJournalRenderError
  , admitHouseholdBudgetMovementJournal
  , renderHouseholdBudgetMovementTransactions
  )
import HKernel.Household.Policy
  ( HouseholdPolicy
  , householdRetiredAllocationAccounts
  )
import HKernel.Journal
  ( Journal
  , JournalError(..)
  , JournalErrorReason(..)
  , combineJournalDocuments
  , includePath
  , journalDocumentIncludes
  , parseJournalDocument
  , resolveJournalDocumentIncludes
  , validateJournalDocument
  )

-- | Prepare one canonical @budget.journal@ movement append. The candidate is
-- admitted through the native Budget Journal owner before publication. Stable
-- allocation Accounts for retired Envelopes remain readable historical evidence
-- but are not writable current endpoints.
data BudgetJournalMovementAppendError
  = BudgetJournalMovementNotBudgetAccount Account
  | BudgetJournalMovementRetiredEnvelopeAccount Account
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
  -> HouseholdPolicy
  -> Text
  -> HouseholdBudgetMovement
  -> Either (NonEmpty BudgetJournalMovementAppendError) BudgetJournalMovementAppendPreview
prepareBudgetJournalMovementAppend registry policy existingSource movement = do
  _ <- verifyBudgetAccount (householdBudgetMovementFrom movement)
  _ <- verifyBudgetAccount (householdBudgetMovementTo movement)
  _ <- verifyCurrentEndpoint (householdBudgetMovementFrom movement)
  _ <- verifyCurrentEndpoint (householdBudgetMovementTo movement)
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
    verifyCurrentEndpoint acc
      | Set.member acc (householdRetiredAllocationAccounts policy) =
          Left (NonEmpty.singleton (BudgetJournalMovementRetiredEnvelopeAccount acc))
      | otherwise = Right ()

resolveInMemoryJournal
  :: AccountRegistry
  -> Text
  -> Either (NonEmpty JournalError) Journal
resolveInMemoryJournal registry input = do
  document <- parseJournalDocument input
  accountText <- case renderRegistryText registry of
    Nothing -> validateJournalDocument document >> Right ""
    Just value -> Right value
  if accountText == ""
    then validateJournalDocument document
    else do
      accountsDocument <- parseJournalDocument accountText
      if null (journalDocumentIncludes document)
        then validateJournalDocument (combineJournalDocuments accountsDocument document)
        else do
          let resolve include
                | includePath include == "accounts.journal" = Right accountsDocument
                | otherwise = Left (pure (JournalError 0 (UnresolvedInclude include)))
          resolved <- resolveJournalDocumentIncludes resolve document
          validateJournalDocument resolved

renderRegistryText :: AccountRegistry -> Maybe Text
renderRegistryText registry =
  case traverse renderAccountDeclaration (accountDeclarations registry) of
    Left _ -> Nothing
    Right rendered -> Just (T.unlines rendered)