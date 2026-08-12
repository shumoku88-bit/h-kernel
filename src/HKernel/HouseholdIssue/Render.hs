{-# LANGUAGE OverloadedStrings #-}

-- | Pure one-line rendering for household issues.
--
-- Every household-facing field is published. Nothing is truncated, folded into
-- a details screen, or inferred from another source.
module HKernel.HouseholdIssue.Render
  ( renderHouseholdIssueLine
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)
import HKernel.HouseholdIssue
import HKernel.Money
  ( Amount
  , amountCommodity
  , amountQuantity
  , commodityCode
  , renderQuantity
  )

renderHouseholdIssueLine :: HouseholdIssue -> Text
renderHouseholdIssueLine issue = T.intercalate " | "
  [ renderDay (householdIssueRecordedOn issue)
  , renderStatus (householdIssueStatus issue)
  , renderDue (householdIssueDue issue)
  , maybe "no amount" renderAmount (householdIssueAmount issue)
  , householdIssueText issue
  , householdIssueDetails issue
  ]

renderStatus :: IssueStatus -> Text
renderStatus = \case
  Open -> "open"
  Resolved -> "resolved"
  Dropped -> "dropped"

renderDue :: IssueDue -> Text
renderDue = \case
  DueOn day -> "due " <> renderDay day
  NoDueDate -> "no due date"
  DueUndetermined -> "due undetermined"

renderAmount :: Amount -> Text
renderAmount amount =
  renderQuantity (amountQuantity amount)
    <> " " <> commodityCode (amountCommodity amount)

renderDay :: Day -> Text
renderDay = T.pack . formatTime defaultTimeLocale "%Y-%m-%d"
