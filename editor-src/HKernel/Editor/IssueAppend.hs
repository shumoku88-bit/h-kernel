{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.IssueAppend
  ( IssueAppendIntent(..)
  , IssueAppendError(..)
  , IssueAppendPreview(..)
  , generateAvailableIssueId
  , prepareIssueAppend
  , IssueCloseDisposition(..)
  , IssueCloseIntent(..)
  , IssueCloseError(..)
  , IssueClosePreview(..)
  , prepareIssueClose
  ) where

import Data.Bifunctor (first)
import Data.Char (isControl)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , HouseholdIssueError
  , IssueId
  , IssueIdError
  , IssueStatus(..)
  , IssueDue(..)
  , householdIssueId
  , householdIssueStatus
  , mkHouseholdIssue
  , mkIssueId
  , issueIdText
  )
import HKernel.Household.Issue.TSV
  ( HouseholdIssueTSVError
  , householdIssueSourceHasHeader
  , householdIssueSourceUsesDueColumn
  , householdIssuesHeader
  , parseHouseholdIssues
  )
import HKernel.Money
  ( Amount
  , amountCommodity
  , amountQuantity
  , commodityCode
  , renderQuantity
  )

data IssueAppendIntent = IssueAppendIntent
  { intentIssueId       :: IssueId
  , intentStatus        :: IssueStatus
  , intentDate          :: Day
  , intentDue           :: IssueDue
  , intentCategory      :: Text
  , intentTitle         :: Text
  , intentAmount        :: Maybe Amount
  , intentDetails       :: Text
  } deriving (Eq, Show)

data IssueAppendError
  = SourceParseError (NonEmpty HouseholdIssueTSVError)
  | CandidateSourceParseError (NonEmpty HouseholdIssueTSVError)
  | DomainValidationError HouseholdIssueError
  | LegacyIssueSourceCannotRepresentDue IssueDue
  deriving (Eq, Show)

data IssueAppendPreview = IssueAppendPreview
  { candidateBlock          :: Text
  , candidateCompleteSource :: Text
  } deriving (Eq, Show)

-- | Generate the first unused Editor-owned Issue identity for one day.
--
-- The stable Issue domain admits explicit durable identifiers. This function
-- owns only the current Editor convention for generated identifiers; callers
-- supply the day and already-admitted identities from their Household
-- observation.
generateAvailableIssueId
  :: Day
  -> [IssueId]
  -> Either IssueIdError IssueId
generateAvailableIssueId day existingIds = go (1 :: Int)
  where
    dayText = T.filter (/= '-') (T.pack (show day))
    existing = Set.fromList (map issueIdText existingIds)

    go index =
      let candidateText = "ISS" <> dayText <> "-" <> T.pack (show index)
      in if candidateText `Set.member` existing
          then go (index + 1)
          else mkIssueId candidateText

prepareIssueAppend
  :: Text
  -> IssueAppendIntent
  -> Either (NonEmpty IssueAppendError) IssueAppendPreview
prepareIssueAppend existingSource intent = do
  _ <- first (pure . DomainValidationError) $
    mkHouseholdIssue
      (intentIssueId intent)
      (intentDate intent)
      (intentStatus intent)
      (intentDue intent)
      (intentAmount intent)
      (intentTitle intent)
      ("[" <> intentCategory intent <> "] " <> intentDetails intent)

  _ <- first (pure . SourceParseError)
    (parseHouseholdIssues existingSource)

  let hasHeader = householdIssueSourceHasHeader existingSource
      usesDueColumn = householdIssueSourceUsesDueColumn existingSource
      renderDueColumn = not hasHeader || usesDueColumn
  if hasHeader && not usesDueColumn && intentDue intent /= DueUndetermined
    then Left (pure (LegacyIssueSourceCannotRepresentDue (intentDue intent)))
    else Right ()

  let block = renderIntent renderDueColumn intent
      appendBody
        | hasHeader = block
        | otherwise = householdIssuesHeader <> "\n" <> block
      preview = IssueAppendPreview
        { candidateBlock = block
        , candidateCompleteSource =
            appendSourceBlock existingSource (SourceBlock appendBody)
        }

  _ <- first (pure . CandidateSourceParseError)
    (parseHouseholdIssues (candidateCompleteSource preview))
  pure preview

renderIntent :: Bool -> IssueAppendIntent -> Text
renderIntent usesDueColumn intent = T.intercalate "\t" fields
  where
    commonBeforeDue =
      [ issueIdText (intentIssueId intent)
      , renderStatus (intentStatus intent)
      , T.pack (formatTime defaultTimeLocale "%F" (intentDate intent))
      ]
    commonAfterDue =
      [ intentCategory intent
      , intentTitle intent
      , maybe "" (renderQuantity . amountQuantity) (intentAmount intent)
      , maybe "" (commodityCode . amountCommodity) (intentAmount intent)
      , intentDetails intent
      ]
    fields
      | usesDueColumn =
          commonBeforeDue ++ [renderDue (intentDue intent)] ++ commonAfterDue
      | otherwise = commonBeforeDue ++ commonAfterDue

renderStatus :: IssueStatus -> Text
renderStatus Open = "open"
renderStatus Resolved = "resolved"
renderStatus Dropped = "dropped"

renderDue :: IssueDue -> Text
renderDue (DueOn day) = T.pack (formatTime defaultTimeLocale "%F" day)
renderDue NoDueDate = "none"
renderDue DueUndetermined = "undetermined"

-- Issue close

-- | Closing an Issue records why attention ended without overloading the
-- source status with an arbitrary string.
data IssueCloseDisposition
  = ResolveIssue
  | DropIssue
  deriving (Eq, Show)

data IssueCloseIntent = IssueCloseIntent
  { closeIssueId      :: IssueId
  , closeDisposition  :: IssueCloseDisposition
  , closeDecisionMemo :: Text
  } deriving (Eq, Show)

data IssueCloseError
  = CloseSourceParseError (NonEmpty HouseholdIssueTSVError)
  | CloseIssueNotFound IssueId
  | CloseIssueNotOpen IssueStatus
  | CloseDecisionMemoBlank
  | CloseDecisionMemoHasSurroundingWhitespace
  | CloseDecisionMemoHasControlCharacter
  | ClosePhysicalRowMismatch IssueId
  | CloseCandidateSourceParseError (NonEmpty HouseholdIssueTSVError)
  deriving (Eq, Show)

data IssueClosePreview = IssueClosePreview
  { closeOriginalRow             :: Text
  , closeCandidateRow            :: Text
  , closeCandidateCompleteSource :: Text
  } deriving (Eq, Show)

prepareIssueClose
  :: Text
  -> IssueCloseIntent
  -> Either (NonEmpty IssueCloseError) IssueClosePreview
prepareIssueClose existingSource intent = do
  issues <- first (pure . CloseSourceParseError)
    (parseHouseholdIssues existingSource)
  target <- maybe
    (Left (pure (CloseIssueNotFound (closeIssueId intent))))
    Right
    (findIssue (closeIssueId intent) issues)
  case householdIssueStatus target of
    Open -> Right ()
    status -> Left (pure (CloseIssueNotOpen status))
  validateDecisionMemo (closeDecisionMemo intent)
  (originalRow, candidateRow, candidateSource) <-
    replaceIssueRow intent existingSource
  _ <- first (pure . CloseCandidateSourceParseError)
    (parseHouseholdIssues candidateSource)
  pure IssueClosePreview
    { closeOriginalRow = originalRow
    , closeCandidateRow = candidateRow
    , closeCandidateCompleteSource = candidateSource
    }

findIssue :: IssueId -> [HouseholdIssue] -> Maybe HouseholdIssue
findIssue targetId = go
  where
    go [] = Nothing
    go (issue : rest)
      | householdIssueId issue == targetId = Just issue
      | otherwise = go rest

validateDecisionMemo
  :: Text
  -> Either (NonEmpty IssueCloseError) ()
validateDecisionMemo memo
  | T.null (T.strip memo) = Left (pure CloseDecisionMemoBlank)
  | T.strip memo /= memo = Left (pure CloseDecisionMemoHasSurroundingWhitespace)
  | T.any isControl memo = Left (pure CloseDecisionMemoHasControlCharacter)
  | otherwise = Right ()

replaceIssueRow
  :: IssueCloseIntent
  -> Text
  -> Either (NonEmpty IssueCloseError) (Text, Text, Text)
replaceIssueRow intent source =
  case matches of
    [(index, oldRow, fields)] ->
      let newFields = replaceFields intent fields
          newRow = T.intercalate "\t" newFields
          newLines = replaceAt index newRow sourceLines
      in Right (oldRow, newRow, T.intercalate "\n" newLines)
    _ -> Left (pure (ClosePhysicalRowMismatch (closeIssueId intent)))
  where
    sourceLines = T.splitOn "\n" source
    matches =
      [ (index, row, fields)
      | (index, row) <- zip [0 ..] sourceLines
      , not (ignoredPhysicalLine row)
      , Just fields <- [matchingIssueFields (closeIssueId intent) row]
      ]

matchingIssueFields :: IssueId -> Text -> Maybe [Text]
matchingIssueFields targetId row = case T.splitOn "\t" row of
  fields@[identifier, _, _, _, _, _, _, _]
    | identifier == issueIdText targetId -> Just fields
  fields@[identifier, _, _, _, _, _, _, _, _]
    | identifier == issueIdText targetId -> Just fields
  _ -> Nothing

ignoredPhysicalLine :: Text -> Bool
ignoredPhysicalLine row =
  let stripped = T.strip row
  in T.null stripped || "#" `T.isPrefixOf` stripped

replaceFields :: IssueCloseIntent -> [Text] -> [Text]
replaceFields intent fields = case fields of
  [identifier, _, day, category, title, amount, currency, details] ->
    [ identifier
    , closeStatusText (closeDisposition intent)
    , day
    , category
    , title
    , amount
    , currency
    , details <> "。Decision: " <> closeDecisionMemo intent
    ]
  [identifier, _, day, due, category, title, amount, currency, details] ->
    [ identifier
    , closeStatusText (closeDisposition intent)
    , day
    , due
    , category
    , title
    , amount
    , currency
    , details <> "。Decision: " <> closeDecisionMemo intent
    ]
  _ -> fields

closeStatusText :: IssueCloseDisposition -> Text
closeStatusText ResolveIssue = "resolved"
closeStatusText DropIssue = "dropped"

replaceAt :: Int -> value -> [value] -> [value]
replaceAt target replacement = go 0
  where
    go _ [] = []
    go index (value : rest)
      | index == target = replacement : rest
      | otherwise = value : go (index + 1) rest
