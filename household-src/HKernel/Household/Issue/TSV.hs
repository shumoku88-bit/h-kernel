{-# LANGUAGE OverloadedStrings #-}

-- | Admission for the retained @issues.tsv@ surface.
--
-- Each physical row becomes one typed 'HouseholdIssue'. The source remains a
-- household notebook surface: admitting it changes no Journal, Plan, Budget,
-- or accounting result by itself.
module HKernel.Household.Issue.TSV
  ( HouseholdIssueTSVError(..)
  , householdIssuesHeader
  , householdIssueSourceHasHeader
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
  (headerLine, header) : rows
    | header /= householdIssuesHeader ->
        Left (errorAt headerLine "unexpected issues header" NonEmpty.:| [])
    | otherwise -> do
        issues <- mapLeft NonEmpty.singleton (traverse parseRow rows)
        ensureUniqueIssues issues

-- | The stable physical header for the retained Issue source.
householdIssuesHeader :: Text
householdIssuesHeader = T.intercalate "\t"
  [ "issue_id"
  , "status"
  , "date"
  , "category"
  , "title"
  , "amount"
  , "currency"
  , "details"
  ]

-- | Whether an admitted source already contains its stable header.
--
-- Callers use this only after 'parseHouseholdIssues' succeeds. Blank and
-- comment-only sources are admitted but still need a header before the first
-- row is appended.
householdIssueSourceHasHeader :: Text -> Bool
householdIssueSourceHasHeader input = case meaningfulLines input of
  [] -> False
  (_, header) : _ -> header == householdIssuesHeader

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
      amount <- parseOptionalAmount lineNumber quantityText currencyText
      mapLeft (errorAt lineNumber . tshow)
        (mkHouseholdIssue
          identifier'
          day
          status
          DueUndetermined
          amount
          title
          ("[" <> category <> "] " <> details))
  _ -> Left (errorAt lineNumber "expected eight issue columns")

parseOptionalAmount
  :: Int
  -> Text
  -> Text
  -> Either HouseholdIssueTSVError (Maybe Amount)
parseOptionalAmount _ "" "" = Right Nothing
parseOptionalAmount lineNumber "" _ =
  Left (errorAt lineNumber
    "amount and currency must both be blank or both be present")
parseOptionalAmount lineNumber _ "" =
  Left (errorAt lineNumber
    "amount and currency must both be blank or both be present")
parseOptionalAmount lineNumber quantityText currencyText = do
  quantity <- mapLeft (errorAt lineNumber . tshow)
    (parseQuantity quantityText)
  commodity <- mapLeft (errorAt lineNumber . tshow)
    (mkCommodity currencyText)
  Right (Just (mkAmount commodity quantity))

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
