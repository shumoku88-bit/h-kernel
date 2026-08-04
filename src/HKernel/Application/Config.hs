{-# LANGUAGE OverloadedStrings #-}

-- | Platform-neutral admission for the retained application configuration.
--
-- The current application contract uses only the selected Actual Journal file.
-- Other retained keys remain accepted without being promoted to domain facts.
module HKernel.Application.Config
  ( ApplicationConfig
  , applicationActualJournalFile
  , ApplicationConfigError(..)
  , parseApplicationConfig
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

-- | The application-level source selection admitted from @config.tsv@.
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
