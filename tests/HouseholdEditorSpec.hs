module Main (main) where

import qualified HouseholdIssueSpec
import qualified HouseholdWorkspaceProjectionSpec

main :: IO ()
main = do
  HouseholdIssueSpec.main
  HouseholdWorkspaceProjectionSpec.main
