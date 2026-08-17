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
  ( EntitlementJournalError(..)
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
  testRenderAndParseRoundtrip

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

testTransferWithoutOriginFails :: IO ()
testTransferWithoutOriginFails = do
  let input = T.unlines
        [ "2026-01-15 alloc unallocated -> living 1000 JPY"
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
        , "2026-01-10 alloc unallocated -> living 1000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left (EntitlementJournalHistoryError (EnvelopeEntitlementOriginAfterTransfer c _ _):|[]) ->
      assertEqual "origin after transfer commodity" c jpy
    other -> failTest "testOriginAfterTransferFails: unexpected result: " other

testPositiveUnallocatedToEnvelopeSucceeds :: IO ()
testPositiveUnallocatedToEnvelopeSucceeds = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 alloc unallocated -> living 50000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left errs -> failTest "testPositiveUnallocatedToEnvelopeSucceeds: expected Right, got " errs
    Right history ->
      assertEqual "transfer count" (length (envelopeEntitlementHistoryTransfers history)) 1

testEnvelopeToEnvelopeSucceeds :: IO ()
testEnvelopeToEnvelopeSucceeds = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 alloc unallocated -> living 50000 JPY"
        , "2026-01-10 move living -> savings 10000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left errs -> failTest "testEnvelopeToEnvelopeSucceeds: expected Right, got " errs
    Right history ->
      assertEqual "transfer count" (length (envelopeEntitlementHistoryTransfers history)) 2

testEnvelopeToUnallocatedSucceeds :: IO ()
testEnvelopeToUnallocatedSucceeds = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 alloc unallocated -> living 50000 JPY"
        , "2026-01-10 release living -> unallocated 5000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left errs -> failTest "testEnvelopeToUnallocatedSucceeds: expected Right, got " errs
    Right history ->
      assertEqual "transfer count" (length (envelopeEntitlementHistoryTransfers history)) 2

testSameEndpointFails :: IO ()
testSameEndpointFails = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 move living -> living 5000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left (EntitlementJournalTransferError _ (EntitlementTransferSameEndpoint _):|[]) -> pure ()
    other -> failTest "testSameEndpointFails: unexpected result: " other

testZeroOrNegativeTransferFails :: IO ()
testZeroOrNegativeTransferFails = do
  let inputZero = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 alloc unallocated -> living 0 JPY"
        ]
      inputNeg = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 alloc unallocated -> living -500 JPY"
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
        , "2026-01-05 alloc unallocated -> unknown-envelope 5000 JPY"
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
        , "2026-01-05 alloc unallocated -> retired-2024 10000 JPY"
        , "2026-01-10 move retired-2024 -> living 10000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left errs -> failTest "testRetiredHistoricalEnvelopeCanBeRead: expected Right, got " errs
    Right history ->
      assertEqual "transfer count" (length (envelopeEntitlementHistoryTransfers history)) 2

testSameDayEffectsCombineBeforeNonnegativeValidation :: IO ()
testSameDayEffectsCombineBeforeNonnegativeValidation = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-05 move living -> savings 10000 JPY"
        , "2026-01-05 alloc unallocated -> living 50000 JPY"
        ]
  case admitEntitlementJournal testRegistry input of
    Left errs -> failTest "testSameDayEffectsCombineBeforeNonnegativeValidation: expected Right, got " errs
    Right history ->
      assertEqual "transfer count" (length (envelopeEntitlementHistoryTransfers history)) 2

testRenderAndParseRoundtrip :: IO ()
testRenderAndParseRoundtrip = do
  let input = T.unlines
        [ "2026-01-01 origin JPY"
        , "2026-01-01 origin USD"
        , "2026-01-05 unallocated -> living 50000 JPY"
        , "2026-01-10 living -> savings 10000 JPY"
        , "2026-01-15 savings -> unallocated 2000 JPY"
        ]
  case parseEntitlementJournal input of
    Left errs -> failTest "testRenderAndParseRoundtrip parse failed: " errs
    Right journal -> do
      let rendered = renderEntitlementJournal journal
      case parseEntitlementJournal rendered of
        Left errs -> failTest "testRenderAndParseRoundtrip re-parse failed: " errs
        Right reParsed ->
          assertEqual "roundtrip match" reParsed journal

failTest :: Show a => String -> a -> IO ()
failTest msg val = do
  putStrLn (msg <> show val)
  exitFailure

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label actual expected =
  unless (actual == expected) $ do
    putStrLn ("Assertion failed for " <> label <> ":\nExpected: " <> show expected <> "\nActual:   " <> show actual)
    exitFailure
