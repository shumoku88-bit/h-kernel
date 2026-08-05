{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TransactionBlock
  ( TransactionBlockIntent(..)
  , IntentPosting(..)
  , TransactionBlockError(..)
  , prepareTransactionBlock
  ) where

import Control.Applicative ((<|>))
import Control.Monad (when)
import Data.Bifunctor (first)
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Account
  ( Account
  , AccountRegistry
  , accountName
  , declaredAccountDefaultCommodity
  , lookupAccountDeclaration
  )
import HKernel.Ledger
  ( Posting
  , Transaction
  , TransactionError
  , mkPosting
  , mkTransaction
  , postingAccount
  , postingAmount
  , transactionDate
  , transactionDescription
  , transactionPostings
  )
import HKernel.Money
  ( Commodity
  , Quantity
  , amountCommodity
  , amountQuantity
  , commodityCode
  , isZeroQuantity
  , mkAmount
  , renderQuantity
  )

-- | Source-neutral input for one validated Journal transaction block.
data TransactionBlockIntent = TransactionBlockIntent
  { blockDate        :: Day
  , blockDescription :: Text
  , blockPostings    :: NonEmpty IntentPosting
  , blockMetadata    :: [(Text, Text)]
  } deriving (Eq, Show)

data IntentPosting = IntentPosting
  { intentAccount   :: Account
  , intentQuantity  :: Quantity
  , intentCommodity :: Maybe Commodity
  } deriving (Eq, Show)

data TransactionBlockError
  = BlockUndeclaredAccount Account
  | BlockMissingCommodity Account
  | BlockZeroAmount Account
  | BlockValidationError TransactionError
  deriving (Eq, Show)

prepareTransactionBlock
  :: AccountRegistry
  -> TransactionBlockIntent
  -> Either (NonEmpty TransactionBlockError) Text
prepareTransactionBlock registry intent = do
  postings <- resolvePostings registry (blockPostings intent)
  transaction <- buildTransaction intent postings
  pure (renderTransaction (blockMetadata intent) transaction)

resolvePostings
  :: AccountRegistry
  -> NonEmpty IntentPosting
  -> Either (NonEmpty TransactionBlockError) (NonEmpty Posting)
resolvePostings registry (firstIntent :| remainingIntents) =
  foldl'
    combineResult
    (singleResult (resolvePosting registry firstIntent))
    (map (resolvePosting registry) remainingIntents)
  where
    singleResult result = case result of
      Left err -> Left (pure err)
      Right posting -> Right (pure posting)

    combineResult accumulated result = case (accumulated, result) of
      (Left errors, Left err) -> Left (errors <> pure err)
      (Left errors, Right _) -> Left errors
      (Right _, Left err) -> Left (pure err)
      (Right postings, Right posting) -> Right (postings <> pure posting)

buildTransaction
  :: TransactionBlockIntent
  -> NonEmpty Posting
  -> Either (NonEmpty TransactionBlockError) Transaction
buildTransaction intent postings =
  first (pure . BlockValidationError)
    (mkTransaction (blockDate intent) (blockDescription intent) postings)

resolvePosting
  :: AccountRegistry
  -> IntentPosting
  -> Either TransactionBlockError Posting
resolvePosting registry (IntentPosting account quantity maybeCommodity) = do
  when (isZeroQuantity quantity) (Left (BlockZeroAmount account))

  declaration <- maybe
    (Left (BlockUndeclaredAccount account))
    pure
    (lookupAccountDeclaration account registry)

  let effectiveCommodity =
        maybeCommodity <|> declaredAccountDefaultCommodity declaration
  commodity <- maybe
    (Left (BlockMissingCommodity account))
    pure
    effectiveCommodity

  pure (mkPosting account (mkAmount commodity quantity))

renderTransaction :: [(Text, Text)] -> Transaction -> Text
renderTransaction metadata transaction =
  T.pack
    (formatTime defaultTimeLocale "%Y-%m-%d" (transactionDate transaction))
  <> " " <> transactionDescription transaction <> "\n"
  <> (if null metadata
        then ""
        else T.intercalate "\n" (map renderMetadata metadata) <> "\n")
  <> T.intercalate "\n"
      (map renderPosting (NonEmpty.toList (transactionPostings transaction)))
  <> "\n"

renderMetadata :: (Text, Text) -> Text
renderMetadata (key, value) = "    ; " <> key <> ": " <> value

renderPosting :: Posting -> Text
renderPosting posting =
  "  " <> accountName (postingAccount posting)
  <> "  " <> renderQuantity (amountQuantity amount)
  <> " " <> commodityCode (amountCommodity amount)
  where
    amount = postingAmount posting
