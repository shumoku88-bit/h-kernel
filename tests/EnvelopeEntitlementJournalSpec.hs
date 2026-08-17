{-# LANGUAGE OverloadedStrings #-}

module EnvelopeEntitlementJournalSpec (main, tests) where

import Control.Monad (unless)
import Data.Either (isLeft, isRight)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure)

import HKernel.Envelope.Entitlement.Journal
  ( EntitlementJournal(..)
  , EntitlementJournalError(..)
  , StockOrigin(..)
  , admitEntitlementJournal
  , parseEntitlementJournal
  , parseEntitlementJournalFromText
  , renderEntitlementJournal
  , renderEntitlementTransfer
  , renderStockOrigin
  )
import HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistory
  , EnvelopeEntitlementHistoryError(..)
  , envelopeEntitlementHistoryOrigins
  , envelopeEntitlementHistoryOriginFor
  , envelopeEntitlementHistoryTransfers
  )
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , EnvelopeEntitlementTransfer(..)
  , EnvelopeEntitlementTransferError(..)
  , mkEnvelopeEntitlementTransfer
  )
import HKernel.Envelope.Identity (EnvelopeId, EnvelopeRegistry, mkEnvelopeId, mkEnvelopeRegistry)
import HKernel.Money (Commodity, mkAmount, mkCommodity, parseQuantity)

main :: IO ()
main = tests

tests :: IO ()
tests = do
  testOriginOnlySucceeds
  testTransferWithoutOriginFails
  testDuplicateOriginFails
  testOriginAfterTransferFails
  testPositiveUnallocatedToEnvelopeSucceeds
  testEnvelopeToEnvelopeSucceeds
  testEnvelopeToUnallocatedSucceeds
  testSameEndpointFails
  testZeroOrNegativeTransferFails
  testUnknownEnvelopeIdFailsClosed
  testRetiredHistoricalEnvelopeCanBeRead
  testSameDayEffectsCombineBeforeNonnegativeValidation
  testUnknownKeywordFailsClosed
  testRenderAndParseRoundtrip
  testProvenancePreservedInHistory

jpy, usd :: Commodity
Right jpy = mkCommodity "JPY"
Right usd = mkCommodity "USD"

living, savings, retiredEnv :: EnvelopeId
Right living = mkEnvelopeId "living"
Right savings = mkEnvelopeId "savings"
Right retiredEnv = mkEnvelopeId "retired-2024"

Right testRegistry = mkEnvelopeRegistry [living, savings, retiredEnv]

testOriginOnlySucceeds :: IO ()
testOriginOnlySucceeds = do
  let input = T.unlines
        [ ";; Stock Origins"
        , "2026-01-01 origin JPY   ; JPY stock origin"
        , "2026-01-01 origin USD   ; USD stock origin"
        ]
  case admitEntitlementJournal testRegistry input of
    Left errs -> failTest "testOriginOnlySucceeds: expected Right, got " errs
    Right history -> do
      assertEqual "origins count" (Map.size (envelopeEntitlementHistoryOrigins history)) 2
      assertEqual "transfers empty" (null (envelopeEntitlementHistoryTransfers history)) True
      case envelopeEntitlementHistoryOriginFor jpy history of
        Just origin -> assertEqual "origin note preserved" (stockOriginNote origin) "JPY stock origin"
        Nothing -> failTest "missing JPY origin in history" history

testTransferWithoutOriginFails :: IO ()
testTransferWithoutOriginFails = do
  let input = T.unlines
        [ "2026-01-15 transfer unallocated -> living 1000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left (EntitlementJournalHistoryError (EnvelopeEntitlementOriginMissing c _):|[]) ->
      assertEqual "missing origin commodity" c jpy
    other -> failTest "testTransferWithoutOriginFails: unexpected result: " other

testDuplicateOriginFails :: IO ()
testDuplicateOriginFails = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-02 origin JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left (EntitlementJournalDuplicateOrigin c d1 d2 :| []) -> do
      assertEqual "duplicate origin commodity" c jpy
      assertEqual "day 1" d1 (fromGregorian 2026 1 1)
      assertEqual "day 2" d2 (fromGregorian 2026 1 2)
    other -> failTest "testDuplicateOriginFails: unexpected result: " other

testOriginAfterTransferFails :: IO ()
testOriginAfterTransferFails = do
  let input = T.unlines
        [ "2026-01-15 origin JPY"
        , "2026-01-10 transfer unallocated -> living 1000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left (EntitlementJournalHistoryError (EnvelopeEntitlementOriginAfterTransfer c _ _):|[]) ->
      assertEqual "origin after transfer commodity" c jpy
    other -> failTest "testOriginAfterTransferFails: unexpected result: " other

testPositiveUnallocatedToEnvelopeSucceeds :: IO ()
testPositiveUnallocatedToEnvelopeSucceeds = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 transfer unallocated -> living 50000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left errs -> failTest "testPositiveUnallocatedToEnvelopeSucceeds: expected Right, got " errs
    Right history ->
      assertEqual "transfer count" (length (envelopeEntitlementHistoryTransfers history)) 1

testEnvelopeToEnvelopeSucceeds :: IO ()
testEnvelopeToEnvelopeSucceeds = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 transfer unallocated -> living 50000 JPY"
        , "2026-01-10 transfer living -> savings 10000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left errs -> failTest "testEnvelopeToEnvelopeSucceeds: expected Right, got " errs
    Right history ->
      assertEqual "transfer count" (length (envelopeEntitlementHistoryTransfers history)) 2

testEnvelopeToUnallocatedSucceeds :: IO ()
testEnvelopeToUnallocatedSucceeds = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 transfer unallocated -> living 50000 JPY"
        , "2026-01-10 transfer living -> unallocated 5000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left errs -> failTest "testEnvelopeToUnallocatedSucceeds: expected Right, got " errs
    Right history ->
      assertEqual "transfer count" (length (envelopeEntitlementHistoryTransfers history)) 2

testSameEndpointFails :: IO ()
testSameEndpointFails = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 transfer living -> living 5000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left (EntitlementJournalTransferError _ (EntitlementTransferSameEndpoint _):|[]) -> pure ()
    other -> failTest "testSameEndpointFails: unexpected result: " other

testZeroOrNegativeTransferFails :: IO ()
testZeroOrNegativeTransferFails = do
  let inputZero = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 transfer unallocated -> living 0 JPY"
        ]
      inputNeg = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 transfer unallocated -> living -500 JPY"
        ]
  case admitEntitlementJournal testRegistry inputZero of
    Left (EntitlementJournalTransferError _ (EntitlementTransferAmountNotPositive _):|[]) -> pure ()
    other -> failTest "testZeroOrNegativeTransferFails (zero): unexpected result: " other
  case admitEntitlementJournal testRegistry inputNeg of
    Left (EntitlementJournalTransferError _ (EntitlementTransferAmountNotPositive _):|[]) -> pure ()
    other -> failTest "testZeroOrNegativeTransferFails (neg): unexpected result: " other

testUnknownEnvelopeIdFailsClosed :: IO ()
testUnknownEnvelopeIdFailsClosed = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 transfer unallocated -> unknown-envelope 5000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left (EntitlementJournalUnknownEnvelope _ eid :| []) -> do
      Right expectedId <- pure (mkEnvelopeId "unknown-envelope")
      assertEqual "unknown envelope id" eid expectedId
    other -> failTest "testUnknownEnvelopeIdFailsClosed: unexpected result: " other

testRetiredHistoricalEnvelopeCanBeRead :: IO ()
testRetiredHistoricalEnvelopeCanBeRead = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 transfer unallocated -> retired-2024 10000 JPY"
        , "2026-01-10 transfer retired-2024 -> living 10000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left errs -> failTest "testRetiredHistoricalEnvelopeCanBeRead: expected Right, got " errs
    Right history ->
      assertEqual "transfer count" (length (envelopeEntitlementHistoryTransfers history)) 2

testSameDayEffectsCombineBeforeNonnegativeValidation :: IO ()
testSameDayEffectsCombineBeforeNonnegativeValidation = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 transfer living -> savings 10000 JPY"
        , "2026-01-05 transfer unallocated -> living 50000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left errs -> failTest "testSameDayEffectsCombineBeforeNonnegativeValidation: expected Right, got " errs
    Right history ->
      assertEqual "transfer count" (length (envelopeEntitlementHistoryTransfers history)) 2

testUnknownKeywordFailsClosed :: IO ()
testUnknownKeywordFailsClosed = do
  let invalidInputs =
        [ ("alloc keyword rejected", "2026-01-05 alloc unallocated -> living 1000 JPY")
        , ("move keyword rejected", "2026-01-05 move living -> savings 1000 JPY")
        , ("release keyword rejected", "2026-01-05 release living -> unallocated 1000 JPY")
        , ("stock-origin alias rejected", "2026-01-01 stock-origin JPY")
        , ("prefixless transfer rejected", "2026-01-05 unallocated -> living 1000 JPY")
        , ("arbitrary keyword rejected", "2026-01-05 grant unallocated -> living 1000 JPY")
        ]
  mapM_ verifySyntaxError invalidInputs
  where
    verifySyntaxError (label, line) = do
      case parseEntitlementJournal line of
        Left (EntitlementJournalSyntaxError _ _ :| []) -> pure ()
        other -> failTest ("testUnknownKeywordFailsClosed: " ++ label ++ ", unexpected result: ") other

testRenderAndParseRoundtrip :: IO ()
testRenderAndParseRoundtrip = do
  let input = T.unlines
        [ "2026-01-01 origin JPY opening stock provenance"
        , "2026-01-01 origin USD usd reserve"
        , "2026-01-05 transfer unallocated -> living 50000 JPY initial living allocation"
        , "2026-01-10 transfer living -> savings 10000 JPY savings transfer"
        , "2026-01-15 transfer savings -> unallocated 2000 JPY unallocated release"
        ]
  case parseEntitlementJournal input of
    Left errs -> failTest "testRenderAndParseRoundtrip parse failed: " errs
    Right journal -> do
      let rendered = renderEntitlementJournal journal
      case parseEntitlementJournal rendered of
        Left errs -> failTest "testRenderAndParseRoundtrip re-parse failed: " errs
        Right reParsed -> do
          assertEqual "roundtrip match" reParsed journal
          assertEqual "rendered output exact match" rendered input

testProvenancePreservedInHistory :: IO ()
testProvenancePreservedInHistory = do
  let input = T.unlines
        [ "2026-01-01 origin JPY JPY first-class note"
        , "2026-01-05 transfer unallocated -> living 1000 JPY grant note"
        ]
  case admitEntitlementJournal testRegistry input of
    Left errs -> failTest "testProvenancePreservedInHistory: expected Right, got " errs
    Right history -> do
      case envelopeEntitlementHistoryOriginFor jpy history of
        Just origin -> do
          assertEqual "origin date" (stockOriginDate origin) (fromGregorian 2026 1 1)
          assertEqual "origin commodity" (stockOriginCommodity origin) jpy
          assertEqual "origin note" (stockOriginNote origin) "JPY first-class note"
        Nothing -> failTest "missing origin in history" history
      case envelopeEntitlementHistoryTransfers history of
        [tr] -> assertEqual "transfer note" (entitlementTransferNote tr) "grant note"
        other -> failTest "unexpected transfers" other

failTest :: Show a => String -> a -> IO ()
failTest msg val = do
  putStrLn (msg <> show val)
  exitFailure

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label actual expected =
  unless (actual == expected) $ do
    putStrLn ("Assertion failed for " <> label <> ":\nExpected: " <> show expected <> "\nActual:   " <> show actual)
    exitFailure
