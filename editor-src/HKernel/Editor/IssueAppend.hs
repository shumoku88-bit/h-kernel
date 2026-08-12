{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.IssueAppend
  ( IssueAppendIntent(..)
  , IssueAppendError(..)
  , IssueAppendPreview(..)
  , generateAvailableIssueId
  , prepareIssueAppend
  , prepareIssueAppendWithDue
  , IssueDueUpdateIntent(..)
  , IssueDueUpdateError(..)
  , IssueDueUpdatePreview(..)
  , prepareIssueDueUpdate
  , IssueCloseDisposition(..)
  , IssueCloseIntent(..)
  , IssueCloseError(..)
  , IssueClosePreview(..)
  , prepareIssueClose
  , prepareIssueCloseOn
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
  , IssueClosed(..)
  , IssueDue(..)
  , IssueId
  , IssueIdError
  , IssueStatus(..)
  , householdIssueId
  , householdIssueRecordedOn
  , householdIssueStatus
  , issueIdText
  , mkHouseholdIssueWithClosed
  , mkIssueId
  )
import HKernel.Household.Issue.TSV
  ( HouseholdIssueTSVError
  , householdIssueSourceHasHeader
  , householdIssueSourceUsesClosedColumn
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

-- | Compatibility entry point for existing adapters that do not yet collect a
-- due meaning. Missing adapter input is kept explicit as 'DueUndetermined'.
prepareIssueAppend
  :: Text
  -> IssueAppendIntent
  -> Either (NonEmpty IssueAppendError) IssueAppendPreview
prepareIssueAppend existingSource =
  prepareIssueAppendWithDue existingSource DueUndetermined

-- | Prepare one Issue append with an explicit three-way due meaning.
--
-- Existing eight- and nine-column sources retain their admitted physical shape.
-- A new source starts with the current ten-column header. The closure coordinate
-- for a newly appended open Issue is explicitly @none@; an already closed status
-- supplied through this compatibility API retains unknown closure time as
-- @undetermined@ rather than inventing a date.
prepareIssueAppendWithDue
  :: Text
  -> IssueDue
  -> IssueAppendIntent
  -> Either (NonEmpty IssueAppendError) IssueAppendPreview
prepareIssueAppendWithDue existingSource due intent = do
  let closed = appendClosed (intentStatus intent)
  _ <- first (pure . DomainValidationError) $
    mkHouseholdIssueWithClosed
      (intentIssueId intent)
      (intentDate intent)
      (intentStatus intent)
      due
      closed
      (intentAmount intent)
      (intentTitle intent)
      ("[" <> intentCategory intent <> "] " <> intentDetails intent)

  _ <- first (pure . SourceParseError)
    (parseHouseholdIssues existingSource)

  let hasHeader = householdIssueSourceHasHeader existingSource
      usesDueColumn = householdIssueSourceUsesDueColumn existingSource
      usesClosedColumn = householdIssueSourceUsesClosedColumn existingSource
      shape
        | not hasHeader = ClosedAwareShape
        | usesClosedColumn = ClosedAwareShape
        | usesDueColumn = DueAwareShape
        | otherwise = LegacyShape
  if shape == LegacyShape && due /= DueUndetermined
    then Left (pure (LegacyIssueSourceCannotRepresentDue due))
    else Right ()

  let block = renderIntent shape due closed intent
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

data IssueSourceShape
  = LegacyShape
  | DueAwareShape
  | ClosedAwareShape
  deriving (Eq, Show)

appendClosed :: IssueStatus -> IssueClosed
appendClosed status = case status of
  Open -> NotClosed
  Resolved -> ClosedUndetermined
  Dropped -> ClosedUndetermined

renderIntent
  :: IssueSourceShape
  -> IssueDue
  -> IssueClosed
  -> IssueAppendIntent
  -> Text
renderIntent shape due closed intent = T.intercalate "\t" fields
  where
    commonBeforeDue =
      [ issueIdText (intentIssueId intent)
      , renderStatus (intentStatus intent)
      , T.pack (formatTime defaultTimeLocale "%F" (intentDate intent))
      ]
    commonAfterTime =
      [ intentCategory intent
      , intentTitle intent
      , maybe "" (renderQuantity . amountQuantity) (intentAmount intent)
      , maybe "" (commodityCode . amountCommodity) (intentAmount intent)
      , intentDetails intent
      ]
    fields = case shape of
      LegacyShape -> commonBeforeDue ++ commonAfterTime
      DueAwareShape -> commonBeforeDue ++ [renderDue due] ++ commonAfterTime
      ClosedAwareShape ->
        commonBeforeDue ++ [renderDue due, renderClosed closed] ++ commonAfterTime

renderStatus :: IssueStatus -> Text
renderStatus Open = "open"
renderStatus Resolved = "resolved"
renderStatus Dropped = "dropped"

renderDue :: IssueDue -> Text
renderDue (DueOn day) = T.pack (formatTime defaultTimeLocale "%F" day)
renderDue NoDueDate = "none"
renderDue DueUndetermined = "undetermined"

renderClosed :: IssueClosed -> Text
renderClosed (ClosedOn day) = T.pack (formatTime defaultTimeLocale "%F" day)
renderClosed NotClosed = "none"
renderClosed ClosedUndetermined = "undetermined"

-- Issue due update

data IssueDueUpdateIntent = IssueDueUpdateIntent
  { dueUpdateIssueId :: IssueId
  , dueUpdateValue   :: IssueDue
  } deriving (Eq, Show)

data IssueDueUpdateError
  = DueUpdateSourceParseError (NonEmpty HouseholdIssueTSVError)
  | DueUpdateIssueNotFound IssueId
  | DueUpdateIssueNotOpen IssueStatus
  | DueUpdateRequiresDueAwareSource
  | DueUpdatePhysicalRowMismatch IssueId
  | DueUpdateCandidateSourceParseError (NonEmpty HouseholdIssueTSVError)
  deriving (Eq, Show)

data IssueDueUpdatePreview = IssueDueUpdatePreview
  { dueUpdateOriginalRow             :: Text
  , dueUpdateCandidateRow            :: Text
  , dueUpdateCandidateCompleteSource :: Text
  } deriving (Eq, Show)

-- | Replace only the explicit due coordinate of one open Issue.
--
-- Identity resolution is by stable IssueId. Both nine- and ten-column sources
-- carry the due coordinate. Every other physical field is preserved byte-for-byte.
prepareIssueDueUpdate
  :: Text
  -> IssueDueUpdateIntent
  -> Either (NonEmpty IssueDueUpdateError) IssueDueUpdatePreview
prepareIssueDueUpdate existingSource intent = do
  issues <- first (pure . DueUpdateSourceParseError)
    (parseHouseholdIssues existingSource)
  target <- maybe
    (Left (pure (DueUpdateIssueNotFound (dueUpdateIssueId intent))))
    Right
    (findIssue (dueUpdateIssueId intent) issues)
  case householdIssueStatus target of
    Open -> Right ()
    status -> Left (pure (DueUpdateIssueNotOpen status))
  if householdIssueSourceUsesDueColumn existingSource
    then Right ()
    else Left (pure DueUpdateRequiresDueAwareSource)
  (originalRow, candidateRow, candidateSource) <-
    replaceIssueDueRow intent existingSource
  _ <- first (pure . DueUpdateCandidateSourceParseError)
    (parseHouseholdIssues candidateSource)
  pure IssueDueUpdatePreview
    { dueUpdateOriginalRow = originalRow
    , dueUpdateCandidateRow = candidateRow
    , dueUpdateCandidateCompleteSource = candidateSource
    }

replaceIssueDueRow
  :: IssueDueUpdateIntent
  -> Text
  -> Either (NonEmpty IssueDueUpdateError) (Text, Text, Text)
replaceIssueDueRow intent source =
  case matches of
    [(index, oldRow, fields)] ->
      let newFields = replaceDueField (dueUpdateValue intent) fields
          newRow = T.intercalate "\t" newFields
          newLines = replaceAt index newRow sourceLines
      in Right (oldRow, newRow, T.intercalate "\n" newLines)
    _ -> Left (pure (DueUpdatePhysicalRowMismatch (dueUpdateIssueId intent)))
  where
    sourceLines = T.splitOn "\n" source
    matches =
      [ (index, row, fields)
      | (index, row) <- zip [0 ..] sourceLines
      , not (ignoredPhysicalLine row)
      , fields <- [T.splitOn "\t" row]
      , length fields `elem` [9, 10]
      , not (null fields)
      , head fields == issueIdText (dueUpdateIssueId intent)
      ]

replaceDueField :: IssueDue -> [Text] -> [Text]
replaceDueField due fields = case fields of
  [identifier, status, day, _, category, title, amount, currency, details] ->
    [ identifier, status, day, renderDue due
    , category, title, amount, currency, details
    ]
  [identifier, status, day, _, closed, category, title, amount, currency, details] ->
    [ identifier, status, day, renderDue due, closed
    , category, title, amount, currency, details
    ]
  _ -> fields

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
  | CloseDateRequiredForClosedAwareSource
  | CloseDateRequiresClosedAwareSource
  | CloseDateBeforeRecorded Day Day
  | ClosePhysicalRowMismatch IssueId
  | CloseCandidateSourceParseError (NonEmpty HouseholdIssueTSVError)
  deriving (Eq, Show)

data IssueClosePreview = IssueClosePreview
  { closeOriginalRow             :: Text
  , closeCandidateRow            :: Text
  , closeCandidateCompleteSource :: Text
  } deriving (Eq, Show)

-- | Compatibility close for eight- and nine-column sources that cannot retain a
-- closure date. Current ten-column sources fail closed and require
-- 'prepareIssueCloseOn' instead of silently dropping the new coordinate.
prepareIssueClose
  :: Text
  -> IssueCloseIntent
  -> Either (NonEmpty IssueCloseError) IssueClosePreview
prepareIssueClose existingSource intent = do
  if householdIssueSourceUsesClosedColumn existingSource
    then Left (pure CloseDateRequiredForClosedAwareSource)
    else prepareIssueCloseWithMaybeDate existingSource Nothing intent

-- | Close one Issue on an explicit day in the current ten-column source.
prepareIssueCloseOn
  :: Text
  -> Day
  -> IssueCloseIntent
  -> Either (NonEmpty IssueCloseError) IssueClosePreview
prepareIssueCloseOn existingSource closedOn intent = do
  if householdIssueSourceUsesClosedColumn existingSource
    then Right ()
    else Left (pure CloseDateRequiresClosedAwareSource)
  prepareIssueCloseWithMaybeDate existingSource (Just closedOn) intent

prepareIssueCloseWithMaybeDate
  :: Text
  -> Maybe Day
  -> IssueCloseIntent
  -> Either (NonEmpty IssueCloseError) IssueClosePreview
prepareIssueCloseWithMaybeDate existingSource maybeClosedOn intent = do
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
  case maybeClosedOn of
    Just closedOn
      | closedOn < householdIssueRecordedOn target ->
          Left (pure (CloseDateBeforeRecorded
            (householdIssueRecordedOn target) closedOn))
    _ -> Right ()
  (originalRow, candidateRow, candidateSource) <-
    replaceIssueRow maybeClosedOn intent existingSource
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
  :: Maybe Day
  -> IssueCloseIntent
  -> Text
  -> Either (NonEmpty IssueCloseError) (Text, Text, Text)
replaceIssueRow maybeClosedOn intent source =
  case matches of
    [(index, oldRow, fields)] ->
      let newFields = replaceFields maybeClosedOn intent fields
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
  fields@[identifier, _, _, _, _, _, _, _, _, _]
    | identifier == issueIdText targetId -> Just fields
  _ -> Nothing

ignoredPhysicalLine :: Text -> Bool
ignoredPhysicalLine row =
  let stripped = T.strip row
  in T.null stripped || "#" `T.isPrefixOf` stripped

replaceFields :: Maybe Day -> IssueCloseIntent -> [Text] -> [Text]
replaceFields maybeClosedOn intent fields = case fields of
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
  [identifier, _, day, due, _, category, title, amount, currency, details] ->
    [ identifier
    , closeStatusText (closeDisposition intent)
    , day
    , due
    , maybe "undetermined" (renderClosed . ClosedOn) maybeClosedOn
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
