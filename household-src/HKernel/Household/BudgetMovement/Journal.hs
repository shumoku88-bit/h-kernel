{-# LANGUAGE OverloadedStrings #-}

-- | Native Journal admission and deterministic rendering for ordered household
-- Budget movement facts.
--
-- The accounting Journal parser owns syntax, Account declarations, exact
-- amounts, and balancing. This module adds only the household Budget movement
-- shape: each transaction has exactly two Budget postings; the first posting is
-- the movement source, the second is the movement destination, and their
-- amounts are exact opposites. Transaction source order is preserved.
module HKernel.Household.BudgetMovement.Journal
  ( HouseholdBudgetMovementJournalError(..)
  , admitHouseholdBudgetMovementJournal
  , HouseholdBudgetMovementJournalRenderError(..)
  , renderHouseholdBudgetMovementTransactions
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Format (defaultTimeLocale, formatTime)
import HKernel.Account
  ( AccountType(..)
  , accountName
  , accountTypeFor
  )
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement(..)
  , householdBudgetMovement
  )
import HKernel.Journal
  ( Journal
  , journalAccountRegistry
  , journalTransactions
  )
import HKernel.Ledger
  ( Posting
  , Transaction
  , postingAccount
  , postingAmount
  , transactionDate
  , transactionDescription
  , transactionPostings
  )
import HKernel.Money
  ( amountCommodity
  , amountQuantity
  , commodityCode
  , negateAmount
  , renderQuantity
  )

-- | Privacy-preserving failure to project one validated Journal transaction as
-- a household Budget movement. Diagnostics retain only transaction/posting
-- coordinates, never private Account names, descriptions, or amounts.
data HouseholdBudgetMovementJournalError
  = BudgetMovementJournalRequiresBinaryTransaction
      { budgetMovementJournalTransactionIndex :: Int
      , budgetMovementJournalPostingCount     :: Int
      }
  | BudgetMovementJournalPostingNotBudget
      { budgetMovementJournalTransactionIndex :: Int
      , budgetMovementJournalPostingIndex     :: Int
      }
  | BudgetMovementJournalPostingsNotExactOpposites
      { budgetMovementJournalTransactionIndex :: Int
      }
  deriving (Eq, Show)

-- | Admit a validated accounting Journal as an ordered sequence of household
-- Budget movements.
--
-- Posting order is meaningful at this boundary: posting 1 is @from@ and posting
-- 2 is @to@. This preserves the existing source-independent movement value even
-- for a signed or zero amount instead of re-inferring direction from sign.
admitHouseholdBudgetMovementJournal
  :: Journal
  -> Either
      (NonEmpty HouseholdBudgetMovementJournalError)
      [HouseholdBudgetMovement]
admitHouseholdBudgetMovementJournal journal =
  case traverse admit indexedTransactions of
    Left err -> Left (err NonEmpty.:| [])
    Right movements -> Right movements
  where
    registry = journalAccountRegistry journal
    indexedTransactions = zip [1..] (journalTransactions journal)

    admit (transactionIndex, transaction) =
      case NonEmpty.toList (transactionPostings transaction) of
        [fromPosting, toPosting] -> do
          requireBudget transactionIndex 1 fromPosting
          requireBudget transactionIndex 2 toPosting
          if postingAmount fromPosting == negateAmount (postingAmount toPosting)
            then Right
              (householdBudgetMovement
                (transactionDate transaction)
                (transactionDescription transaction)
                (postingAccount fromPosting)
                (postingAccount toPosting)
                (postingAmount toPosting))
            else Left
              (BudgetMovementJournalPostingsNotExactOpposites transactionIndex)
        postings -> Left
          (BudgetMovementJournalRequiresBinaryTransaction
            transactionIndex (length postings))

    requireBudget transactionIndex postingIndex posting
      | accountTypeFor (postingAccount posting) registry == Just Budget = Right ()
      | otherwise = Left
          (BudgetMovementJournalPostingNotBudget transactionIndex postingIndex)

-- | Privacy-preserving rendering rejection. The transaction index identifies
-- the coordinate without retaining source text.
newtype HouseholdBudgetMovementJournalRenderError
  = BudgetMovementJournalUnrepresentableTransaction Int
  deriving (Eq, Show)

-- | Render only native transaction blocks. Account declarations are deliberately
-- not duplicated here: the canonical @budget.journal@ root may include the
-- canonical @accounts.journal@ before these blocks.
renderHouseholdBudgetMovementTransactions
  :: [HouseholdBudgetMovement]
  -> Either
      (NonEmpty HouseholdBudgetMovementJournalRenderError)
      Text
renderHouseholdBudgetMovementTransactions movements =
  case NonEmpty.nonEmpty unrepresentable of
    Just errors -> Left errors
    Nothing -> Right (T.intercalate "\n" (map renderMovement movements))
  where
    unrepresentable =
      [ BudgetMovementJournalUnrepresentableTransaction index
      | (index, movement) <- zip [1..] movements
      , not (movementIsRepresentable movement)
      ]

movementIsRepresentable :: HouseholdBudgetMovement -> Bool
movementIsRepresentable movement =
  all representableAccount
    [ householdBudgetMovementFrom movement
    , householdBudgetMovementTo movement
    ]
    && not (T.any (`elem` ['\n', '\r']) (householdBudgetMovementMemo movement))
  where
    representableAccount = not . T.any (== ';') . accountName

renderMovement :: HouseholdBudgetMovement -> Text
renderMovement movement = T.unlines
  [ T.pack
      (formatTime defaultTimeLocale "%F" (householdBudgetMovementDate movement))
      <> " " <> householdBudgetMovementMemo movement
  , renderPosting
      (householdBudgetMovementFrom movement)
      (negateAmount amount)
  , renderPosting
      (householdBudgetMovementTo movement)
      amount
  ]
  where
    amount = householdBudgetMovementAmount movement

renderPosting account amount =
  "    " <> accountName account
    <> "    " <> renderQuantity (amountQuantity amount)
    <> " " <> commodityCode (amountCommodity amount)
