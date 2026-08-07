{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.BudgetMovementAppend
  ( BudgetMovementAppendError(..)
  , BudgetMovementAppendPreview(..)
  , prepareBudgetMovementAppend
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Account (accountName)
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement(..)
  )
import HKernel.Household.BudgetMovement.TSV
  ( HouseholdBudgetMovementTSVError
  , parseHouseholdBudgetMovements
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
