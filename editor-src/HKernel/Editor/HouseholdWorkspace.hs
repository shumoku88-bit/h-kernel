-- | Pure presentation projections shared by Household workspace deliveries.
-- Canonical source order remains owned by the admitted source models.
module HKernel.Editor.HouseholdWorkspace
  ( issuesForWorkspace
  ) where

import Data.List (sortOn)
import Data.Time.Calendar (toModifiedJulianDay)

import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueStatus(..)
  , householdIssueRecordedOn
  , householdIssueStatus
  )

-- | Keep matters needing attention before completed history, with the newest
-- recorded matter first inside each group. Stable sorting preserves source
-- order for ties without mutating issues.tsv.
issuesForWorkspace :: [HouseholdIssue] -> [HouseholdIssue]
issuesForWorkspace = sortOn issueWorkspaceKey
  where
    issueWorkspaceKey issue =
      ( statusRank (householdIssueStatus issue)
      , negate (toModifiedJulianDay (householdIssueRecordedOn issue))
      )
    statusRank Open = (0 :: Int)
    statusRank Resolved = 1
    statusRank Dropped = 1
