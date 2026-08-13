{-# LANGUAGE OverloadedStrings #-}

-- | Pure admission and rendering for the proposed Issue relation history source.
--
-- This module owns only the six-coordinate source syntax for typed historical
-- relations. It is deliberately not wired into canonical Household paths,
-- snapshots, writer authority, or TUI publication yet.
module HKernel.Household.Issue.Relation.TSV
  ( IssueRelationTSVError(..)
  , issueRelationHeader
  , parseIssueRelations
  , renderIssueRelations
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.HouseholdIssue
import HKernel.Plan (mkPlanId, planIdText)
import HKernel.Plan.Completion
  ( actualTransactionIdText
  , mkActualTransactionId
  )

-- | Source-local diagnostic with a physical line coordinate but no retained
-- private row text.
data IssueRelationTSVError = IssueRelationTSVError
  { issueRelationTSVErrorLine    :: Int
  , issueRelationTSVErrorMessage :: Text
  } deriving (Eq, Show)

-- | Engine-neutral six-coordinate relation history header.
issueRelationHeader :: Text
issueRelationHeader = T.intercalate "\t"
  [ "relation_event_id"
  , "recorded_on"
  , "issue_id"
  , "relation_kind"
  , "target_id"
  , "details"
  ]

-- | Admit zero or more historical Issue relation occurrences.
--
-- A blank or comment-only source carries no history. Once data is present, the
-- header and every row are exact. Cross-source target existence is intentionally
-- outside this source-local owner.
parseIssueRelations
  :: Text
  -> Either (NonEmpty IssueRelationTSVError) [IssueRelationEvent]
parseIssueRelations input = case meaningfulLines input of
  [] -> Right []
  (headerLine, header) : rows
    | header /= issueRelationHeader ->
        Left (errorAt headerLine "unexpected issue relation header" NonEmpty.:| [])
    | otherwise -> do
        relations <- mapLeft NonEmpty.singleton (traverse parseRow rows)
        ensureUniqueEventIds relations

-- | Render an admitted collection into the same six-coordinate source shape.
--
-- Rendering the empty collection still emits the header so the result is a
-- ready-to-append source rather than an absent source.
renderIssueRelations :: [IssueRelationEvent] -> Text
renderIssueRelations relations = T.unlines
  (issueRelationHeader : map renderRow relations)

parseRow
  :: (Int, Text)
  -> Either IssueRelationTSVError IssueRelationEvent
parseRow (lineNumber, line) = case T.splitOn "\t" line of
  [eventIdText, dayText, issueIdText', kind, targetText, details] -> do
    eventId <- mapLeft (errorAt lineNumber . tshow)
      (mkIssueRelationEventId eventIdText)
    day <- parseDay lineNumber dayText
    issueId <- mapLeft (errorAt lineNumber . tshow)
      (mkIssueId issueIdText')
    meaning <- parseMeaning lineNumber kind targetText
    mapLeft (errorAt lineNumber . tshow)
      (mkIssueRelationEvent eventId day issueId meaning details)
  _ -> Left (errorAt lineNumber "expected six issue relation columns")

parseMeaning
  :: Int
  -> Text
  -> Text
  -> Either IssueRelationTSVError IssueRelation
parseMeaning lineNumber kind target = case kind of
  "concerns-plan" ->
    IssueConcernsPlan <$> mapLeft (errorAt lineNumber . tshow) (mkPlanId target)
  "planned-as" ->
    IssuePlannedAs <$> mapLeft (errorAt lineNumber . tshow) (mkPlanId target)
  "planning-withdrawn" ->
    IssuePlanningWithdrawn <$> mapLeft (errorAt lineNumber . tshow) (mkPlanId target)
  "realized-as" ->
    IssueRealizedAs
      <$> mapLeft (errorAt lineNumber . tshow) (mkActualTransactionId target)
  "funded-by" ->
    IssueFundedBy
      <$> mapLeft (errorAt lineNumber . tshow) (mkActualTransactionId target)
  _ -> Left (errorAt lineNumber "unknown issue relation kind")

parseDay :: Int -> Text -> Either IssueRelationTSVError Day
parseDay lineNumber value =
  case parseTimeM True defaultTimeLocale "%F" (T.unpack value) of
    Just day -> Right day
    Nothing -> Left (errorAt lineNumber "invalid issue relation recorded-on")

ensureUniqueEventIds
  :: [IssueRelationEvent]
  -> Either (NonEmpty IssueRelationTSVError) [IssueRelationEvent]
ensureUniqueEventIds relations = case duplicateKeys issueRelationEventId relations of
  [] -> Right relations
  _ -> Left (errorAt 0 "duplicate issue relation event identity" NonEmpty.:| [])

renderRow :: IssueRelationEvent -> Text
renderRow relation = T.intercalate "\t"
  [ issueRelationEventIdText (issueRelationEventId relation)
  , T.pack (show (issueRelationRecordedOn relation))
  , issueIdText (issueRelationIssueId relation)
  , kind
  , target
  , issueRelationDetails relation
  ]
  where
    (kind, target) = renderMeaning (issueRelationMeaning relation)

renderMeaning :: IssueRelation -> (Text, Text)
renderMeaning relation = case relation of
  IssueConcernsPlan planId -> ("concerns-plan", planIdText planId)
  IssuePlannedAs planId -> ("planned-as", planIdText planId)
  IssuePlanningWithdrawn planId -> ("planning-withdrawn", planIdText planId)
  IssueRealizedAs actualId -> ("realized-as", actualTransactionIdText actualId)
  IssueFundedBy actualId -> ("funded-by", actualTransactionIdText actualId)

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

errorAt :: Int -> Text -> IssueRelationTSVError
errorAt = IssueRelationTSVError

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value

tshow :: Show value => value -> Text
tshow = T.pack . show
