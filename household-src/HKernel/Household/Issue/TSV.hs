{-# LANGUAGE OverloadedStrings #-}

-- | Admission for the retained @issues.tsv@ surface.
--
-- Each physical row becomes one typed 'HouseholdIssue'. The source remains a
-- household notebook surface: admitting it changes no Journal, Plan, Budget,
-- or accounting result by itself.
module HKernel.Household.Issue.TSV
  ( HouseholdIssueTSVError(..)
  , householdIssuesHeader
  , dueAwareHouseholdIssuesHeader
  , legacyHouseholdIssuesHeader
  , householdIssueSourceHasHeader
  , householdIssueSourceUsesDueColumn
  , householdIssueSourceUsesClosedColumn
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
    | header == householdIssuesHeader -> do
        issues <- mapLeft NonEmpty.singleton (traverse parseClosedAwareRow rows)
        ensureUniqueIssues issues
    | header == dueAwareHouseholdIssuesHeader -> do
        issues <- mapLeft NonEmpty.singleton (traverse parseDueAwareRow rows)
        ensureUniqueIssues issues
    | header == legacyHouseholdIssuesHeader -> do
        issues <- mapLeft NonEmpty.singleton (traverse parseLegacyRow rows)
        ensureUniqueIssues issues
    | otherwise ->
        Left (errorAt headerLine "unexpected issues header" NonEmpty.:| [])

-- | Current source header. Recorded, due, and closure time are deliberately
-- separate coordinates.
householdIssuesHeader :: Text
householdIssuesHeader = T.intercalate "\t"
  [ "issue_id"
  , "status"
  , "date"
  , "due"
  , "closed"
  , "category"
  , "title"
  , "amount"
  , "currency"
  , "details"
  ]

-- | Bounded compatibility for the previous explicit-due source shape.
-- Closed Issues admitted through this header have status evidence but no
-- closure-date evidence, so their closure time remains 'ClosedUndetermined'.
dueAwareHouseholdIssuesHeader :: Text
dueAwareHouseholdIssuesHeader = T.intercalate "\t"
  [ "issue_id"
  , "status"
  , "date"
  , "due"
  , "category"
  , "title"
  , "amount"
  , "currency"
  , "details"
  ]

-- | Bounded migration compatibility for the pre-due source shape.
--
-- Rows admitted through this header carry neither explicit due nor closure-date
-- evidence. Missing due becomes 'DueUndetermined'; closed status becomes
-- 'ClosedUndetermined' rather than a guessed date.
legacyHouseholdIssuesHeader :: Text
legacyHouseholdIssuesHeader = T.intercalate "\t"
  [ "issue_id"
  , "status"
  , "date"
  , "category"
  , "title"
  , "amount"
  , "currency"
  , "details"
  ]

-- | Whether an admitted source already contains any supported header.
--
-- Callers use this only after 'parseHouseholdIssues' succeeds. Blank and
-- comment-only sources are admitted but still need a header before the first
-- row is appended.
householdIssueSourceHasHeader :: Text -> Bool
householdIssueSourceHasHeader input = case meaningfulLines input of
  [] -> False
  (_, header) : _ ->
    header == householdIssuesHeader
      || header == dueAwareHouseholdIssuesHeader
      || header == legacyHouseholdIssuesHeader

-- | Whether an admitted source has the explicit due coordinate.
householdIssueSourceUsesDueColumn :: Text -> Bool
householdIssueSourceUsesDueColumn input = case meaningfulLines input of
  [] -> False
  (_, header) : _ ->
    header == householdIssuesHeader || header == dueAwareHouseholdIssuesHeader

-- | Whether an admitted source has the explicit closure-time coordinate.
householdIssueSourceUsesClosedColumn :: Text -> Bool
householdIssueSourceUsesClosedColumn input = case meaningfulLines input of
  [] -> False
  (_, header) : _ -> header == householdIssuesHeader

parseClosedAwareRow :: (Int, Text) -> Either HouseholdIssueTSVError HouseholdIssue
parseClosedAwareRow (lineNumber, line) = case T.splitOn "\t" line of
  [ identifier
    , statusText
    , dateText
    , dueText
    , closedText
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
      due <- parseDue lineNumber dueText
      closed <- parseClosed lineNumber closedText
      amount <- parseOptionalAmount lineNumber quantityText currencyText
      mapLeft (errorAt lineNumber . tshow)
        (mkHouseholdIssueWithClosed
          identifier'
          day
          status
          due
          closed
          amount
          title
          ("[" <> category <> "] " <> details))
  _ -> Left (errorAt lineNumber "expected ten issue columns")

parseDueAwareRow :: (Int, Text) -> Either HouseholdIssueTSVError HouseholdIssue
parseDueAwareRow (lineNumber, line) = case T.splitOn "\t" line of
  [ identifier
    , statusText
    , dateText
    , dueText
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
      due <- parseDue lineNumber dueText
      amount <- parseOptionalAmount lineNumber quantityText currencyText
      mapLeft (errorAt lineNumber . tshow)
        (mkHouseholdIssueWithClosed
          identifier'
          day
          status
          due
          (compatibilityClosed status)
          amount
          title
          ("[" <> category <> "] " <> details))
  _ -> Left (errorAt lineNumber "expected nine due-aware issue columns")

parseLegacyRow :: (Int, Text) -> Either HouseholdIssueTSVError HouseholdIssue
parseLegacyRow (lineNumber, line) = case T.splitOn "\t" line of
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
        (mkHouseholdIssueWithClosed
          identifier'
          day
          status
          DueUndetermined
          (compatibilityClosed status)
          amount
          title
          ("[" <> category <> "] " <> details))
  _ -> Left (errorAt lineNumber "expected eight legacy issue columns")

compatibilityClosed :: IssueStatus -> IssueClosed
compatibilityClosed status = case status of
  Open -> NotClosed
  Resolved -> ClosedUndetermined
  Dropped -> ClosedUndetermined

parseDue :: Int -> Text -> Either HouseholdIssueTSVError IssueDue
parseDue _ "none" = Right NoDueDate
parseDue _ "undetermined" = Right DueUndetermined
parseDue lineNumber input =
  DueOn <$> parseDayWithMessage lineNumber "invalid issue due" input

parseClosed :: Int -> Text -> Either HouseholdIssueTSVError IssueClosed
parseClosed _ "none" = Right NotClosed
parseClosed _ "undetermined" = Right ClosedUndetermined
parseClosed lineNumber input =
  ClosedOn <$> parseDayWithMessage lineNumber "invalid issue closed date" input

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
parseStatus _ "dropped" = Right Dropped
parseStatus lineNumber _ =
  Left (errorAt lineNumber "unknown issue status")

parseDay :: Int -> Text -> Either HouseholdIssueTSVError Day
parseDay lineNumber = parseDayWithMessage lineNumber "invalid date"

parseDayWithMessage :: Int -> Text -> Text -> Either HouseholdIssueTSVError Day
parseDayWithMessage lineNumber message input =
  case parseTimeM True defaultTimeLocale "%F" (T.unpack input) of
    Just day -> Right day
    Nothing -> Left (errorAt lineNumber message)

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
