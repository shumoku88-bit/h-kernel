{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import RepositoryAudit
import System.Exit (ExitCode(..), exitFailure)
import System.FilePath ((</>))
import System.IO (stderr)
import System.Process
  ( CreateProcess(..)
  , proc
  , readCreateProcessWithExitCode
  )

data InventoryLoadError
  = ExternalCommandCouldNotStart FilePath IOException
  | ExternalCommandFailed FilePath [String] ExitCode Text
  | InventoryContainsInvalidPaths Text [RepositoryPathError]
  | DocumentIndexCouldNotBeRead FilePath IOException
  | DocumentIndexWasInvalid [Text]

main :: IO ()
main = do
  inventoryResult <- loadRepositoryInventory
  case inventoryResult of
    Left err -> do
      TIO.hPutStrLn stderr ("repository-audit: " <> renderLoadError err)
      exitFailure
    Right inventory ->
      case auditRepository inventory of
        [] -> TIO.putStrLn "repository-audit: repository ownership is consistent"
        findings -> do
          TIO.hPutStrLn stderr "repository-audit: ownership findings"
          mapM_ (TIO.hPutStrLn stderr . ("  - " <>) . renderFinding) findings
          exitFailure

loadRepositoryInventory :: IO (Either InventoryLoadError RepositoryInventory)
loadRepositoryInventory = do
  rootResult <- runCommand Nothing "git" ["rev-parse", "--show-toplevel"]
  case rootResult of
    Left err -> pure (Left err)
    Right rootOutput -> do
      let root = T.unpack (dropLineEndings rootOutput)
      trackedResult <- runCommand (Just root) "git" ["ls-files", "-z"]
      packagedResult <- runCommand
        (Just root)
        "cabal"
        ["sdist", "-v0", "--list-only", "--null-sep"]
      indexResult <- readDocumentIndex (root </> "docs" </> "INDEX.toml")
      pure $ do
        trackedOutput <- trackedResult
        packagedOutput <- packagedResult
        index <- indexResult
        tracked <- admitPaths "git ls-files" trackedOutput
        packaged <- admitPaths "cabal sdist --list-only" packagedOutput
        Right (repositoryInventory tracked packaged index)

runCommand
  :: Maybe FilePath
  -> FilePath
  -> [String]
  -> IO (Either InventoryLoadError Text)
runCommand workingDirectory command arguments = do
  let process = (proc command arguments) { cwd = workingDirectory }
  result <- try (readCreateProcessWithExitCode process "")
    :: IO (Either IOException (ExitCode, String, String))
  pure $ case result of
    Left err -> Left (ExternalCommandCouldNotStart command err)
    Right (ExitSuccess, output, _) -> Right (T.pack output)
    Right (exitCode, _, errorOutput) ->
      Left
        (ExternalCommandFailed
          command
          arguments
          exitCode
          (T.pack errorOutput))

readDocumentIndex :: FilePath -> IO (Either InventoryLoadError DocumentIndex)
readDocumentIndex path = do
  result <- try (TIO.readFile path)
    :: IO (Either IOException Text)
  pure $ case result of
    Left err -> Left (DocumentIndexCouldNotBeRead path err)
    Right input -> case parseDocumentIndex input of
      Left errors -> Left (DocumentIndexWasInvalid errors)
      Right index -> Right index

admitPaths
  :: Text
  -> Text
  -> Either InventoryLoadError [RepositoryPath]
admitPaths owner output =
  case parseNulSeparatedPaths output of
    Left errors -> Left (InventoryContainsInvalidPaths owner errors)
    Right paths -> Right paths

renderLoadError :: InventoryLoadError -> Text
renderLoadError err = case err of
  ExternalCommandCouldNotStart command ioError ->
    "could not start " <> T.pack command <> ": " <> T.pack (show ioError)
  ExternalCommandFailed command arguments exitCode errorOutput ->
    "command failed (" <> T.pack (show exitCode) <> "): "
      <> T.unwords (map T.pack (command : arguments))
      <> renderCommandError errorOutput
  InventoryContainsInvalidPaths owner errors ->
    owner <> " produced invalid repository paths: "
      <> T.intercalate "; " (map (T.pack . show) errors)
  DocumentIndexCouldNotBeRead path ioError ->
    "could not read " <> T.pack path <> ": " <> T.pack (show ioError)
  DocumentIndexWasInvalid errors ->
    "invalid docs/INDEX.toml:\n" <> T.unlines (map ("  " <>) errors)

renderCommandError :: Text -> Text
renderCommandError output
  | T.null (T.strip output) = ""
  | otherwise = "\n" <> T.stripEnd output

dropLineEndings :: Text -> Text
dropLineEndings = T.dropWhileEnd isLineEnding
  where
    isLineEnding char = char == '\n' || char == '\r'
