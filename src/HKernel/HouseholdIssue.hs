{-# LANGUAGE OverloadedStrings #-}

-- | User-authored household matters that remain outside accounting calculations.
--
-- A Household Issue may mention a possible payment, amount, or due date, but it
-- is not a Journal fact, Plan commitment, BudgetChange, or diagnostic. It changes
-- no balance or budget result by itself.
module HKernel.HouseholdIssue
  ( IssueId
  , IssueIdError(..)
  , mkIssueId
  , issueIdText
  , IssueStatus(..)
  , IssueDue(..)
  , HouseholdIssue
  , HouseholdIssueError(..)
  , mkHouseholdIssue
  , householdIssueId
  , householdIssueRecordedOn
  , householdIssueStatus
  , householdIssueDue
  , householdIssueAmount
  , householdIssueText
  , householdIssueDetails
  ) where

import Data.Char (isControl, isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import HKernel.Money (Amount)

-- | Stable machine identity used to update or resolve one issue safely.
newtype IssueId = IssueId { issueIdText :: Text }
  deriving (Eq, Ord, Show)

data IssueIdError
  = EmptyIssueId
  | IssueIdHasSurroundingWhitespace Text
  | IssueIdContainsControlCharacter Text
  | IssueIdContainsWhitespace Text
  deriving (Eq, Show)

mkIssueId :: Text -> Either IssueIdError IssueId
mkIssueId value
  | T.null value = Left EmptyIssueId
  | T.strip value /= value = Left (IssueIdHasSurroundingWhitespace value)
  | T.any isControl value = Left (IssueIdContainsControlCharacter value)
  | T.any isSpace value = Left (IssueIdContainsWhitespace value)
  | otherwise = Right (IssueId value)

-- | Whether the household matter still needs attention.
data IssueStatus
  = Open
  | Resolved
  deriving (Eq, Ord, Show)

-- | Either one known due date or an explicit statement that it is not yet known.
data IssueDue
  = DueOn Day
  | DueUndetermined
  deriving (Eq, Ord, Show)

-- | One small household notebook entry.
--
-- Text is the matter itself. Details retain its short household context. Amount
-- is optional because some matters are not monetary; when present it remains an
-- exact single-commodity Amount.
data HouseholdIssue = HouseholdIssue
  { householdIssueId         :: IssueId
  , householdIssueRecordedOn :: Day
  , householdIssueStatus     :: IssueStatus
  , householdIssueDue        :: IssueDue
  , householdIssueAmount     :: Maybe Amount
  , householdIssueText       :: Text
  , householdIssueDetails    :: Text
  } deriving (Eq, Show)

data HouseholdIssueError
  = EmptyHouseholdIssueText
  | HouseholdIssueTextHasSurroundingWhitespace Text
  | HouseholdIssueTextContainsControlCharacter Text
  | HouseholdIssueDetailsHasSurroundingWhitespace Text
  | HouseholdIssueDetailsContainsControlCharacter Text
  deriving (Eq, Show)

mkHouseholdIssue
  :: IssueId
  -> Day
  -> IssueStatus
  -> IssueDue
  -> Maybe Amount
  -> Text
  -> Text
  -> Either HouseholdIssueError HouseholdIssue
mkHouseholdIssue issueId recordedOn status due amount text details
  | T.null text = Left EmptyHouseholdIssueText
  | T.strip text /= text =
      Left (HouseholdIssueTextHasSurroundingWhitespace text)
  | T.any isControl text =
      Left (HouseholdIssueTextContainsControlCharacter text)
  | T.strip details /= details =
      Left (HouseholdIssueDetailsHasSurroundingWhitespace details)
  | T.any isControl details =
      Left (HouseholdIssueDetailsContainsControlCharacter details)
  | otherwise = Right HouseholdIssue
      { householdIssueId = issueId
      , householdIssueRecordedOn = recordedOn
      , householdIssueStatus = status
      , householdIssueDue = due
      , householdIssueAmount = amount
      , householdIssueText = text
      , householdIssueDetails = details
      }
