{-# LANGUAGE OverloadedStrings #-}

-- | Admission for the retained @issues.tsv@ surface.
--
-- Each physical row becomes one typed 'HouseholdIssue'. The source remains a
-- household notebook surface: admitting it changes no Journal, Plan, Budget,
-- or accounting result by itself.
module HKernel.Household.Issue.TSV
  ( HouseholdIssueTSVError(..)
  , parseHouseholdIssues
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.HouseholdIssue
import HKernel.Money

-- | Source-local diagnostic that retains a physical line coordinate without
-- retaining a complete private row.
data HouseholdIssueTSVError = HouseholdIssueTSVError
  { householdIssueTSVErrorLine    :: Int
  , householdIssueTSVErrorMessage :: Text
  } deriving (Eq, Show)

parseHouseholdIssues
  :: Text
  -> Either (NonEmpty HouseholdIssueTSVError) [HouseholdIssue]
parseHouseholdIssues input = case meaningfulLines input of
  [] -> Right []
  (_, header) : rows
    | header /= expectedHeader ->
        Left (errorAt 1 "unexpected issues header" NonEmpty.:| [])
    | otherwise -> do
        issues <- mapLeft NonEmpty.singleton (traverse parseRow rows)
        ensureUniqueIssues issues

expectedHeader :: Text
expectedHeader = T.intercalate "\t"
  [ "issue_id"
  , "status"
  , "date"
  , "category"
  , "title"
  , "amount"
  , "currency"
  , "details"
  ]

parseRow :: (Int, Text) -> Either HouseholdIssueTSVError HouseholdIssue
parseRow (lineNumber, line) = case T.splitOn "\t" line of
  [ identifier
    , statusText
    , dateText
    , category
    , title
    , quantityText
    , currencyText
    , details
    ] -> do
      identifier' <- mapLeft (errorAt lineNumber . tshow)
        (mkIssueId identifier)
      status <- parseStatus lineNumber statusText
      day <- parseDay lineNumber dateText
      quantity <- mapLeft (errorAt lineNumber . tshow)
        (parseQuantity quantityText)
      commodity <- mapLeft (errorAt lineNumber . tshow)
        (mkCommodity currencyText)
      mapLeft (errorAt lineNumber . tshow)
        (mkHouseholdIssue
          identifier'
          day
          status
          DueUndetermined
          (Just (mkAmount commodity quantity))
          title
          ("[" <> category <> "] " <> details))
  _ -> Left (errorAt lineNumber "expected eight issue columns")

parseStatus :: Int -> Text -> Either HouseholdIssueTSVError IssueStatus
parseStatus _ "open" = Right Open
parseStatus _ "resolved" = Right Resolved
parseStatus lineNumber _ =
  Left (errorAt lineNumber "unknown issue status")

parseDay :: Int -> Text -> Either HouseholdIssueTSVError Day
parseDay lineNumber input =
  case parseTimeM True defaultTimeLocale "%F" (T.unpack input) of
    Just day -> Right day
    Nothing -> Left (errorAt lineNumber "invalid date")

ensureUniqueIssues
  :: [HouseholdIssue]
  -> Either (NonEmpty HouseholdIssueTSVError) [HouseholdIssue]
ensureUniqueIssues issues = case duplicateKeys householdIssueId issues of
  [] -> Right issues
  _ -> Left (errorAt 0 "duplicate identity" NonEmpty.:| [])

meaningfulLines :: Text -> [(Int, Text)]
meaningfulLines =
  filter (not . ignored . snd) . zip [1..] . T.lines
  where
    ignored line =
      let stripped = T.strip line
      in T.null stripped || "#" `T.isPrefixOf` stripped

duplicateKeys :: Ord key => (value -> key) -> [value] -> [key]
duplicateKeys keyOf values =
  [ key
  | (key, count) <- Map.toAscList
      (Map.fromListWith (+) [(keyOf value, 1 :: Int) | value <- values])
  , count > 1
  ]

errorAt :: Int -> Text -> HouseholdIssueTSVError
errorAt = HouseholdIssueTSVError

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value

tshow :: Show value => value -> Text
tshow = T.pack . show
