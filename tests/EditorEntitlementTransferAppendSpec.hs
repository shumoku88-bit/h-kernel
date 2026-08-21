{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (IOException, catch)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Editor.EntitlementTransferAppend
  ( EntitlementTransferAppendError(..)
  , EntitlementTransferAppendPreview(..)
  , EntitlementTransferPublicationError(..)
  , prepareCurrentEntitlementTransferAppend
  , prepareEntitlementTransferAppend
  , publishCurrentEntitlementTransferFromPreview
  )
import HKernel.Editor.SourcePublication
  ( WriterFileSystem(..)
  , defaultWriterFileSystem
  )
import HKernel.Envelope
  ( CurrentEnvelopePolicy
  , Pacing(..)
  , defineEnvelope
  , mkCurrentEnvelopePolicy
  , mkEnvelopeLabel
  )
import HKernel.Envelope.Entitlement.Journal (admitEntitlementJournal)
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , EnvelopeEntitlementTransfer(..)
  , mkEnvelopeEntitlementTransfer
  )
import HKernel.Envelope.Identity (EnvelopeId, EnvelopeRegistry, mkEnvelopeId, mkEnvelopeRegistry)
import HKernel.Money (Commodity, mkAmount, mkCommodity, quantityFromInteger)

main :: IO ()
main = do
  let tests =
        [ ("testNativeEntitlementTransferAppend", pure testNativeEntitlementTransferAppend)
        , ("testCurrentWriterRejectsRetiredEnvelope", pure testCurrentWriterRejectsRetiredEnvelope)
        , ("testPathAwareJournalCommit", testPathAwareJournalCommit)
        , ("testPublicationRechecksCurrentPolicy", testPublicationRechecksCurrentPolicy)
        , ("testPublicationIgnoresPreviewCandidateBytes", testPublicationIgnoresPreviewCandidateBytes)
        ]
  results <- sequence [action | (_, action) <- tests]
  let namedResults = zip (map fst tests) results
  mapM_ print namedResults
  if all snd namedResults
    then exitSuccess
    else exitFailure

jpy :: Commodity
jpy = mustRight (mkCommodity "JPY")

currentEnv, retiredEnv :: EnvelopeId
currentEnv = mustRight (mkEnvelopeId "current")
retiredEnv = mustRight (mkEnvelopeId "retired")

testRegistry :: EnvelopeRegistry
testRegistry = mustRight (mkEnvelopeRegistry [currentEnv, retiredEnv])

currentPolicy :: CurrentEnvelopePolicy
currentPolicy = mustRight (mkCurrentEnvelopePolicy
  [defineEnvelope currentEnv (mustRight (mkEnvelopeLabel "Current")) Flex])

retiredOnlyPolicy :: CurrentEnvelopePolicy
retiredOnlyPolicy = mustRight (mkCurrentEnvelopePolicy
  [defineEnvelope retiredEnv (mustRight (mkEnvelopeLabel "Retired")) Flex])

testTransfer :: EnvelopeEntitlementTransfer
testTransfer = mustRight (mkEnvelopeEntitlementTransfer
  (fromGregorian 2026 8 4)
  Unallocated
  (Spendable currentEnv)
  (mkAmount jpy (quantityFromInteger 500))
  "alloc")

testRetiredTransfer :: EnvelopeEntitlementTransfer
testRetiredTransfer = mustRight (mkEnvelopeEntitlementTransfer
  (fromGregorian 2026 8 4)
  (Spendable retiredEnv)
  (Spendable currentEnv)
  (mkAmount jpy (quantityFromInteger 500))
  "move")

existingSource :: Text
existingSource = "2026-01-01 origin JPY\n"

testNativeEntitlementTransferAppend :: Bool
testNativeEntitlementTransferAppend =
  case prepareEntitlementTransferAppend testRegistry existingSource testTransfer of
    Right preview ->
      entitlementCandidateBlock preview == "2026-08-04 transfer unallocated -> current 500 JPY alloc"
        && entitlementCandidateCompleteSource preview == (existingSource <> "\n2026-08-04 transfer unallocated -> current 500 JPY alloc")
    Left err -> error (show err)

testCurrentWriterRejectsRetiredEnvelope :: Bool
testCurrentWriterRejectsRetiredEnvelope =
  case prepareCurrentEntitlementTransferAppend currentPolicy testRegistry existingSource testRetiredTransfer of
    Left (EntitlementTransferAppendRetiredEnvelope eid :| _) ->
      eid == retiredEnv
    _ -> False

testPathAwareJournalCommit :: IO Bool
testPathAwareJournalCommit = do
  let targetPath = "tests/fixtures/test_editor_path_entitlement.journal"
  cleanup targetPath
  TIO.writeFile targetPath existingSource
  let preview = mustRight
        (prepareCurrentEntitlementTransferAppend
          currentPolicy testRegistry existingSource testTransfer)
  result <- publishCurrentEntitlementTransferFromPreview
    (\p -> do
      content <- TIO.readFile p
      pure (admitEntitlementJournal testRegistry content))
    targetPath
    currentPolicy
    testRegistry
    preview
  current <- TIO.readFile targetPath
  cleanup targetPath
  pure
    (result == Right ()
      && current == entitlementCandidateCompleteSource preview)

testPublicationRechecksCurrentPolicy :: IO Bool
testPublicationRechecksCurrentPolicy = do
  let targetPath = "tests/fixtures/test_editor_policy_recheck_entitlement.journal"
  cleanup targetPath
  TIO.writeFile targetPath existingSource
  let preview = mustRight
        (prepareCurrentEntitlementTransferAppend
          currentPolicy testRegistry existingSource testTransfer)
  result <- publishCurrentEntitlementTransferFromPreview
    (\p -> do
      content <- TIO.readFile p
      pure (admitEntitlementJournal testRegistry content))
    targetPath
    retiredOnlyPolicy
    testRegistry
    preview
  current <- TIO.readFile targetPath
  cleanup targetPath
  pure $ case result of
    Left
      (EntitlementTransferPublicationPreparationFailed
        (EntitlementTransferAppendRetiredEnvelope eid :| _)) ->
          eid == currentEnv && current == existingSource
    _ -> False

testPublicationIgnoresPreviewCandidateBytes :: IO Bool
testPublicationIgnoresPreviewCandidateBytes = do
  let targetPath = "tests/fixtures/test_editor_preview_bytes_entitlement.journal"
  cleanup targetPath
  TIO.writeFile targetPath existingSource
  let prepared = mustRight
        (prepareCurrentEntitlementTransferAppend
          currentPolicy testRegistry existingSource testTransfer)
      expectedCandidate = entitlementCandidateCompleteSource prepared
      tamperedPreview = prepared
        { entitlementCandidateCompleteSource = "replacement bytes that are not an append"
        }
  result <- publishCurrentEntitlementTransferFromPreview
    (\p -> do
      content <- TIO.readFile p
      pure (admitEntitlementJournal testRegistry content))
    targetPath
    currentPolicy
    testRegistry
    tamperedPreview
  current <- TIO.readFile targetPath
  cleanup targetPath
  pure (result == Right () && current == expectedCandidate)

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

cleanup :: FilePath -> IO ()
cleanup path = do
  removeIfPresent path
  removeIfPresent (path <> ".backup.tmp")
  removeIfPresent (path <> ".new.tmp")

removeIfPresent :: FilePath -> IO ()
removeIfPresent path =
  catch
    (removeTextFile defaultWriterFileSystem path)
    (\(_ :: IOException) -> pure ())
