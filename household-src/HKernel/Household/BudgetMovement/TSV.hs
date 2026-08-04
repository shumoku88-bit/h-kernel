{-# LANGUAGE OverloadedStrings #-}

-- | Admission for the retained @budget_alloc.tsv@ surface.
--
-- Each meaningful physical row becomes one source-independent
-- 'HouseholdBudgetMovement'. Entitlement and Backing may interpret the same
-- admitted movement differently, but neither calculation depends on TSV shape.
module HKernel.Household.BudgetMovement.TSV
  ( HouseholdBudgetMovementTSVError(..)
  , parseHouseholdBudgetMovements
  ) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.Account (mkAccount)
import HKernel.Household.BudgetMovement
import HKernel.Money

-- | Source-local diagnostic retaining only a physical line and message.
data HouseholdBudgetMovementTSVError = HouseholdBudgetMovementTSVError
  { householdBudgetMovementTSVErrorLine    :: Int
  , householdBudgetMovementTSVErrorMessage :: Text
  } deriving (Eq, Show)

parseHouseholdBudgetMovements
  :: Text
  -> Either (NonEmpty HouseholdBudgetMovementTSVError) [HouseholdBudgetMovement]
parseHouseholdBudgetMovements input =
  mapLeft NonEmpty.singleton
    (traverse parseRow (meaningfulLines input))

parseRow
  :: (Int, Text)
  -> Either HouseholdBudgetMovementTSVError HouseholdBudgetMovement
parseRow (lineNumber, line) = case T.splitOn "\t" line of
  dateText : memo : fromText : toText : quantityText : fields -> do
    day <- parseDay lineNumber dateText
    fromAccount <- mapLeft (errorAt lineNumber . tshow)
      (mkAccount fromText)
    toAccount <- mapLeft (errorAt lineNumber . tshow)
      (mkAccount toText)
    quantity <- mapLeft (errorAt lineNumber . tshow)
      (parseQuantity quantityText)
    let metadata = Map.fromList (mapMaybe keyValue fields)
    currencyText <- requireField lineNumber "currency" metadata
    commodity <- mapLeft (errorAt lineNumber . tshow)
      (mkCommodity currencyText)
    Right (householdBudgetMovement
      day memo fromAccount toAccount (mkAmount commodity quantity))
  _ -> Left (errorAt lineNumber
    "expected date, memo, from, to, amount, and currency")

parseDay :: Int -> Text -> Either HouseholdBudgetMovementTSVError Day
parseDay lineNumber input =
  case parseTimeM True defaultTimeLocale "%F" (T.unpack input) of
    Just day -> Right day
    Nothing -> Left (errorAt lineNumber "invalid date")

meaningfulLines :: Text -> [(Int, Text)]
meaningfulLines =
  filter (not . ignored . snd) . zip [1..] . T.lines
  where
    ignored line =
      let stripped = T.strip line
      in T.null stripped || "#" `T.isPrefixOf` stripped

keyValue :: Text -> Maybe (Text, Text)
keyValue field = case T.breakOn "=" field of
  (key, value) | not (T.null key) && not (T.null value) ->
    Just (key, T.drop 1 value)
  _ -> Nothing

requireField
  :: Int
  -> Text
  -> Map.Map Text Text
  -> Either HouseholdBudgetMovementTSVError Text
requireField lineNumber field metadata =
  maybe (Left (errorAt lineNumber ("missing " <> field))) Right
    (Map.lookup field metadata)

errorAt :: Int -> Text -> HouseholdBudgetMovementTSVError
errorAt = HouseholdBudgetMovementTSVError

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value

tshow :: Show value => value -> Text
tshow = T.pack . show
