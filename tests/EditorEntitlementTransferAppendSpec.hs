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
  , prepareCurrentEntitlementTransferAppend
  , prepareEntitlementTransferAppend
  )
import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteError(..)
  , WriteIntent(..)
  , WriterFileSystem(..)
  , defaultWriterFileSystem
  , publishWithPathAdmission
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
  let preview = mustRight (prepareCurrentEntitlementTransferAppend currentPolicy testRegistry existingSource testTransfer)
  result <- publishWithPathAdmission
    (\p -> do
      content <- TIO.readFile p
      pure (admitEntitlementJournal testRegistry content))
    WriteIntent
      { targetFilePath = targetPath
      , expectedOldBytes = ExpectedSource existingSource
      , candidateNewBytes = CandidateSource (entitlementCandidateCompleteSource preview)
      }
  current <- TIO.readFile targetPath
  cleanup targetPath
  pure (result == Right () && current == entitlementCandidateCompleteSource preview)

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
