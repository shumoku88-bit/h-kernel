-- | Pure presentation projections shared by Household workspace deliveries.
-- Canonical source order remains owned by the admitted source models.
module HKernel.Editor.HouseholdWorkspace
  ( IssueWorkspaceFilter(..)
  , issuesForWorkspace
  ) where

import Data.List (sortOn)
import Data.Time.Calendar (toModifiedJulianDay)

import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueStatus(..)
  , householdIssueRecordedOn
  , householdIssueStatus
  )

-- | Workspace-local visibility for the Household notebook.
-- Canonical admission keeps every Issue regardless of this presentation choice.
data IssueWorkspaceFilter
  = OpenIssueFilter
  | ClosedIssueFilter
  | AllIssueFilter
  deriving (Eq, Show)

-- | Select one explicit workspace view and keep newest matters first. Stable
-- sorting preserves source order for ties without mutating issues.tsv.
issuesForWorkspace
  :: IssueWorkspaceFilter
  -> [HouseholdIssue]
  -> [HouseholdIssue]
issuesForWorkspace visibility =
  sortOn issueWorkspaceKey . filter (visibleWith visibility)
  where
    issueWorkspaceKey issue =
      ( statusRank (householdIssueStatus issue)
      , negate (toModifiedJulianDay (householdIssueRecordedOn issue))
      )
    statusRank Open = (0 :: Int)
    statusRank Resolved = 1
    statusRank Dropped = 1

visibleWith :: IssueWorkspaceFilter -> HouseholdIssue -> Bool
visibleWith visibility issue = case visibility of
  OpenIssueFilter -> householdIssueStatus issue == Open
  ClosedIssueFilter -> householdIssueStatus issue /= Open
  AllIssueFilter -> True
