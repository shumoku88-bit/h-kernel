{-# LANGUAGE OverloadedStrings #-}

-- | Application-level source topology and retained configuration admission.
--
-- The canonical Household root is the stable application bootstrap: delivery
-- adapters receive one root and this module resolves the canonical basenames in
-- one place. The retained @config.tsv@ parser remains temporarily for migration
-- evidence; it is not the owner of Household facts or policy.
module HKernel.Application.Config
  ( HouseholdRoot
  , HouseholdRootError(..)
  , mkHouseholdRoot
  , householdRootPath
  , HouseholdSourcePaths(..)
  , householdSourcePaths
  , ApplicationConfig
  , applicationActualJournalFile
  , ApplicationConfigError(..)
  , parseApplicationConfig
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath ((</>), normalise)

-- | One canonical Household directory supplied by the application bootstrap.
newtype HouseholdRoot = HouseholdRoot
  { householdRootPath :: FilePath
  } deriving (Eq, Show)

data HouseholdRootError
  = EmptyHouseholdRootPath
  deriving (Eq, Show)

mkHouseholdRoot :: FilePath -> Either HouseholdRootError HouseholdRoot
mkHouseholdRoot path
  | null path = Left EmptyHouseholdRootPath
  | otherwise = Right (HouseholdRoot (normalise path))

-- | Physical paths for the agreed canonical source/config target.
--
-- No TUI screen, CLI route, or Report preset should construct these basenames
-- independently. The record says where a semantic owner lives; it does not
-- imply that all files share one parser or writer.
data HouseholdSourcePaths = HouseholdSourcePaths
  { householdAccountsJournalPath :: FilePath
  , householdActualJournalPath   :: FilePath
  , householdPlanJournalPath     :: FilePath
  , householdBudgetJournalPath   :: FilePath
  , householdBudgetConfigPath    :: FilePath
  , householdPolicyConfigPath    :: FilePath
  , householdReportConfigPath    :: FilePath
  , householdIssuesPath          :: FilePath
  } deriving (Eq, Show)

householdSourcePaths :: HouseholdRoot -> HouseholdSourcePaths
householdSourcePaths root = HouseholdSourcePaths
  { householdAccountsJournalPath = at "accounts.journal"
  , householdActualJournalPath = at "actual.journal"
  , householdPlanJournalPath = at "plan.journal"
  , householdBudgetJournalPath = at "budget.journal"
  , householdBudgetConfigPath = at "budget.toml"
  , householdPolicyConfigPath = at "household.toml"
  , householdReportConfigPath = at "report.toml"
  , householdIssuesPath = at "issues.tsv"
  }
  where
    at basename = householdRootPath root </> basename

-- Retained config.tsv compatibility

-- | The application-level source selection admitted from retained @config.tsv@.
newtype ApplicationConfig = ApplicationConfig
  { applicationActualJournalFile :: Text
  } deriving (Eq, Show)

-- | One source-local configuration admission failure.
--
-- The complete physical row is deliberately not retained.
data ApplicationConfigError = ApplicationConfigError
  { applicationConfigErrorLine    :: Int
  , applicationConfigErrorMessage :: Text
  } deriving (Eq, Show)

-- | Admit the retained KEY=VALUE surface into the application source choice.
--
-- Unknown keys and last-write-wins duplicate handling are retained for
-- compatibility with the current source. Only @ACTUAL_JOURNAL_FILE@ has
-- application meaning here.
parseApplicationConfig
  :: Text
  -> Either (NonEmpty ApplicationConfigError) ApplicationConfig
parseApplicationConfig input = do
  entries <- mapLeft NonEmpty.singleton
    (traverse parseLine (meaningfulLines input))
  let config = Map.fromList entries
  case Map.lookup "ACTUAL_JOURNAL_FILE" config of
    Just "actual.journal" -> Right (ApplicationConfig "actual.journal")
    Just value -> Left (ApplicationConfigError 0
      ("ACTUAL_JOURNAL_FILE must be actual.journal, got " <> value)
      NonEmpty.:| [])
    Nothing -> Left (ApplicationConfigError 0
      "ACTUAL_JOURNAL_FILE is required" NonEmpty.:| [])
  where
    parseLine (lineNumber, line) = case T.breakOn "=" line of
      (key, value)
        | not (T.null key)
        , not (T.null value) -> Right (key, T.drop 1 value)
      _ -> Left (ApplicationConfigError lineNumber "expected KEY=VALUE")

meaningfulLines :: Text -> [(Int, Text)]
meaningfulLines =
  filter (not . ignored . snd) . zip [1..] . T.lines
  where
    ignored line =
      let stripped = T.strip line
      in T.null stripped || "#" `T.isPrefixOf` stripped

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value
