{-# LANGUAGE OverloadedStrings #-}

-- | Source-independent household Budget movement facts together with their
-- narrow native Journal admission boundary.
--
-- The accounting Journal parser owns syntax, Account declarations, exact
-- amounts, balancing, and root source coordinates. This module adds only the
-- household Budget movement shape. Retained TSV admission remains a
-- compatibility adapter.
module HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement(..)
  , householdBudgetMovement
  , HouseholdBudgetMovementJournal
  , householdBudgetMovementJournalValue
  , householdBudgetMovementJournalMovements
  , HouseholdBudgetMovementJournalError(..)
  , admitHouseholdBudgetMovementJournal
  , admitHouseholdBudgetMovementJournalFromResolvedJournal
  , admitHouseholdBudgetMovementJournalFromResolvedSources
  , HouseholdBudgetMovementJournalRenderError(..)
  , renderHouseholdBudgetMovementTransactions
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)
import HKernel.Account
  ( Account
  , AccountType(..)
  , accountName
  , accountTypeFor
  )
import HKernel.Journal
  ( Journal
  , JournalError
  , JournalTransactionSource
  , journalAccountRegistry
  , journalDocumentTransactionSources
  , journalTransactionSourceTransaction
  , journalTransactions
  , parseJournalDocument
  )
import HKernel.Ledger
  ( postingAccount
  , postingAmount
  , transactionDate
  , transactionDescription
  , transactionPostings
  )
import HKernel.Money
  ( Amount
  , amountCommodity
  , amountQuantity
  , commodityCode
  , negateAmount
  , renderQuantity
  )

-- | One exact movement between two household Budget Accounts.
--
-- Source order and memo are retained as evidence. Interpretation belongs to the
-- calculation that receives the movement together with validated policy.
data HouseholdBudgetMovement = HouseholdBudgetMovement
  { householdBudgetMovementDate   :: Day
  , householdBudgetMovementMemo   :: Text
  , householdBudgetMovementFrom   :: Account
  , householdBudgetMovementTo     :: Account
  , householdBudgetMovementAmount :: Amount
  } deriving (Eq, Show)

householdBudgetMovement
  :: Day
  -> Text
  -> Account
  -> Account
  -> Amount
  -> HouseholdBudgetMovement
householdBudgetMovement = HouseholdBudgetMovement

-- | One admitted native @budget.journal@ observation.
--
-- The resolved Journal owns accounting meaning. Ordered movements own the
-- household Budget projection. Root transaction sources are used only as an
-- admission fence and are not retained as household semantic state.
data HouseholdBudgetMovementJournal = HouseholdBudgetMovementJournal
  { householdBudgetMovementJournalValue     :: Journal
  , householdBudgetMovementJournalMovements :: [HouseholdBudgetMovement]
  } deriving (Eq, Show)

-- | Privacy-preserving failures to admit one native Budget Journal observation.
-- Diagnostics retain only structural coordinates or parser-owned errors, never
-- private Account names, descriptions, or amounts.
data HouseholdBudgetMovementJournalError
  = BudgetMovementJournalSyntaxError JournalError
  | BudgetMovementJournalMetadataAlignmentMismatch Int Int
  | BudgetMovementJournalTransactionSourceAlignmentMismatch Int
  | BudgetMovementJournalRequiresBinaryTransaction Int Int
  | BudgetMovementJournalPostingNotBudget Int Int
  | BudgetMovementJournalPostingsNotExactOpposites Int
  deriving (Eq, Show)

-- | Admit a validated accounting Journal as an ordered sequence of household
-- Budget movements.
--
-- This source-independent projection remains useful to compatibility callers.
-- Canonical native loading should prefer a root-evidence admission so source
-- coordinates and movement meaning remain one observation.
--
-- Posting order is meaningful at this boundary: posting 1 is @from@ and posting
-- 2 is @to@. This preserves the source-independent movement value even for a
-- signed or zero amount instead of re-inferring direction from sign.
admitHouseholdBudgetMovementJournal
  :: Journal
  -> Either
      (NonEmpty HouseholdBudgetMovementJournalError)
      [HouseholdBudgetMovement]
admitHouseholdBudgetMovementJournal journal =
  case partitionEithers admissions of
    ([], movements) -> Right movements
    (errorGroups, _) -> case concat errorGroups of
      firstError : remainingErrors -> Left (firstError :| remainingErrors)
      [] -> Right []
  where
    registry = journalAccountRegistry journal
    admissions = zipWith admit [1..] (journalTransactions journal)

    admit transactionIndex transaction =
      case NonEmpty.toList (transactionPostings transaction) of
        [fromPosting, toPosting] ->
          case binaryErrors transactionIndex fromPosting toPosting of
            [] -> Right
              (householdBudgetMovement
                (transactionDate transaction)
                (transactionDescription transaction)
                (postingAccount fromPosting)
                (postingAccount toPosting)
                (postingAmount toPosting))
            errors -> Left errors
        postings -> Left
          [ BudgetMovementJournalRequiresBinaryTransaction
              transactionIndex (length postings)
          ]

    binaryErrors transactionIndex fromPosting toPosting =
      [ BudgetMovementJournalPostingNotBudget transactionIndex postingIndex
      | (postingIndex, posting) <- [(1, fromPosting), (2, toPosting)]
      , accountTypeFor (postingAccount posting) registry /= Just Budget
      ]
      ++ [ BudgetMovementJournalPostingsNotExactOpposites transactionIndex
         | postingAmount fromPosting /= negateAmount (postingAmount toPosting)
         ]

-- | Admit one resolved Budget Journal together with the exact root bytes from
-- which root-local transaction evidence was observed.
--
-- This compatibility entry point reparses the supplied root Text, then delegates
-- to the same parser-owned source admission used by canonical filesystem loading.
admitHouseholdBudgetMovementJournalFromResolvedJournal
  :: Journal
  -> Text
  -> Either
      (NonEmpty HouseholdBudgetMovementJournalError)
      HouseholdBudgetMovementJournal
admitHouseholdBudgetMovementJournalFromResolvedJournal journal rootSource = do
  document <- case parseJournalDocument rootSource of
    Left errors -> Left (fmap BudgetMovementJournalSyntaxError errors)
    Right value -> Right value
  admitHouseholdBudgetMovementJournalFromResolvedSources
    journal
    (journalDocumentTransactionSources document)

-- | Admit Budget movement meaning from parser-owned root transaction evidence
-- retained by the same loading observation as the resolved Journal.
--
-- Included Account declarations may contribute to the resolved Journal, but a
-- hidden included transaction cannot silently become a Budget movement. The
-- count fence rejects missing/extra sources, while the semantic fence rejects
-- equal-count evidence from a different transaction observation.
admitHouseholdBudgetMovementJournalFromResolvedSources
  :: Journal
  -> [JournalTransactionSource]
  -> Either
      (NonEmpty HouseholdBudgetMovementJournalError)
      HouseholdBudgetMovementJournal
admitHouseholdBudgetMovementJournalFromResolvedSources journal sources = do
  let transactions = journalTransactions journal
      transactionCount = length transactions
      sourceCount = length sources
      sourceAlignmentErrors =
        [ BudgetMovementJournalTransactionSourceAlignmentMismatch index
        | (index, transaction, source) <- zip3 [1..] transactions sources
        , transaction /= journalTransactionSourceTransaction source
        ]
  if transactionCount /= sourceCount
    then Left (pure
      (BudgetMovementJournalMetadataAlignmentMismatch
        transactionCount sourceCount))
    else case NonEmpty.nonEmpty sourceAlignmentErrors of
      Just errors -> Left errors
      Nothing -> Right ()
  movements <- admitHouseholdBudgetMovementJournal journal
  pure HouseholdBudgetMovementJournal
    { householdBudgetMovementJournalValue = journal
    , householdBudgetMovementJournalMovements = movements
    }

-- | Privacy-preserving rendering rejection. The transaction index identifies
-- the coordinate without retaining source text.
newtype HouseholdBudgetMovementJournalRenderError
  = BudgetMovementJournalUnrepresentableTransaction Int
  deriving (Eq, Show)

-- | Render native transaction blocks without duplicating Account declarations.
--
-- A canonical @budget.journal@ may place @include accounts.journal@ before this
-- text. The shared Loader then owns path resolution and Account admission.
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

renderPosting :: Account -> Amount -> Text
renderPosting account amount =
  "    " <> accountName account
    <> "    " <> renderQuantity (amountQuantity amount)
    <> " " <> commodityCode (amountCommodity amount)
