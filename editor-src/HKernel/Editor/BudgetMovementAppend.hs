{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.BudgetMovementAppend
  ( BudgetJournalEndpoint(..)
  , BudgetJournalAppendError(..)
  , BudgetJournalAppendPreview(..)
  , prepareBudgetJournalMovementAppend
  , BudgetMovementAppendError(..)
  , BudgetMovementAppendPreview(..)
  , prepareBudgetMovementAppend
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Account (AccountType(..), accountName, accountTypeFor)
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement(..)
  , HouseholdBudgetMovementJournalRenderError
  , renderHouseholdBudgetMovementTransactions
  )
import HKernel.Household.BudgetMovement.TSV
  ( HouseholdBudgetMovementTSVError
  , parseHouseholdBudgetMovements
  )
import HKernel.Journal (Journal, journalAccountRegistry)
import HKernel.Money (amountCommodity, amountQuantity, commodityCode, renderQuantity)

-- Native budget.journal candidate

data BudgetJournalEndpoint
  = BudgetJournalFrom
  | BudgetJournalTo
  deriving (Eq, Show)

data BudgetJournalAppendError
  = BudgetJournalEndpointNotBudget BudgetJournalEndpoint
  | BudgetJournalRenderError HouseholdBudgetMovementJournalRenderError
  deriving (Eq, Show)

data BudgetJournalAppendPreview = BudgetJournalAppendPreview
  { budgetJournalCandidateBlock          :: Text
  , budgetJournalCandidateCompleteSource :: Text
  } deriving (Eq, Show)

-- | Prepare one movement for the canonical @budget.journal@ root bytes.
--
-- The already loaded Journal supplies the admitted Account registry, including
-- declarations resolved through @include accounts.journal@. The candidate root
-- text may therefore remain declaration-free. Complete graph admission after
-- publication belongs to the path-aware safe writer.
prepareBudgetJournalMovementAppend
  :: Journal
  -> Text
  -> HouseholdBudgetMovement
  -> Either (NonEmpty BudgetJournalAppendError) BudgetJournalAppendPreview
prepareBudgetJournalMovementAppend loadedJournal existingRoot movement = do
  validateBudgetEndpoints loadedJournal movement
  block <- first (fmap BudgetJournalRenderError)
    (renderHouseholdBudgetMovementTransactions [movement])
  pure BudgetJournalAppendPreview
    { budgetJournalCandidateBlock = block
    , budgetJournalCandidateCompleteSource =
        appendSourceBlock existingRoot (SourceBlock block)
    }

validateBudgetEndpoints
  :: Journal
  -> HouseholdBudgetMovement
  -> Either (NonEmpty BudgetJournalAppendError) ()
validateBudgetEndpoints journal movement =
  case NonEmpty.nonEmpty errors of
    Nothing -> Right ()
    Just nonEmptyErrors -> Left nonEmptyErrors
  where
    registry = journalAccountRegistry journal
    endpoints =
      [ (BudgetJournalFrom, householdBudgetMovementFrom movement)
      , (BudgetJournalTo, householdBudgetMovementTo movement)
      ]
    errors =
      [ BudgetJournalEndpointNotBudget endpoint
      | (endpoint, account) <- endpoints
      , accountTypeFor account registry /= Just Budget
      ]

-- Retained budget_alloc.tsv compatibility

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
