{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.IssueAppend
  ( IssueAppendIntent(..)
  , IssueAppendError(..)
  , IssueAppendPreview(..)
  , prepareIssueAppend
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Editor.ActualAppend (appendBlock)
import HKernel.HouseholdIssue
  ( HouseholdIssueError
  , IssueId
  , IssueStatus(..)
  , IssueDue(..)
  , mkHouseholdIssue
  , issueIdText
  )
import HKernel.Household.Issue.TSV
  ( HouseholdIssueTSVError
  , parseHouseholdIssues
  )
import HKernel.Money (Amount, amountCommodity, amountQuantity, commodityCode, renderQuantity)

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
  deriving (Eq, Show)

data IssueAppendPreview = IssueAppendPreview
  { candidateBlock          :: Text
  , candidateCompleteSource :: Text
  } deriving (Eq, Show)

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
      DueUndetermined
      (intentAmount intent)
      (intentTitle intent)
      ("[" <> intentCategory intent <> "] " <> intentDetails intent)
  
  _ <- first (pure . SourceParseError) (parseHouseholdIssues existingSource)
  
  let block = renderIntent intent
      preview = IssueAppendPreview
        { candidateBlock = block
        , candidateCompleteSource = appendBlock existingSource block
        }
  
  _ <- first (pure . CandidateSourceParseError) (parseHouseholdIssues (candidateCompleteSource preview))
  pure preview

renderIntent :: IssueAppendIntent -> Text
renderIntent intent = T.intercalate "\t"
  [ issueIdText (intentIssueId intent)
  , renderStatus (intentStatus intent)
  , T.pack (formatTime defaultTimeLocale "%F" (intentDate intent))
  , intentCategory intent
  , intentTitle intent
  , maybe "" (renderQuantity . amountQuantity) (intentAmount intent)
  , maybe "" (commodityCode . amountCommodity) (intentAmount intent)
  , intentDetails intent
  ]

renderStatus :: IssueStatus -> Text
renderStatus Open = "open"
renderStatus Resolved = "resolved"
