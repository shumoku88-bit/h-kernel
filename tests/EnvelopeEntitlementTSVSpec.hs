{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistoryError(..)
  , envelopeEntitlementHistoryTransfers
  )
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , entitlementTransferFrom
  , entitlementTransferNote
  , entitlementTransferTo
  )
import HKernel.Envelope.EntitlementTSV
import HKernel.Envelope.Identity (mkEnvelopeId)
import System.Exit (exitFailure)

main :: IO ()
main = do
  admittedShape
  sameDayHistoryLaw
  sourceLocalBoundary
  sourceDiagnostics

admittedShape :: IO ()
admittedShape = do
  let source = T.unlines
        [ header
        , "# source order is provenance"
        , "2026-08-15\t2026-08-15\t2026-10-15\tunallocated\tfood\t10000\tJPY\tinitial"
        , ""
        , "2026-08-16\t2026-08-15\t2026-10-15\tfood\tstock-food\t1000\tJPY\tmove\twith-tab"
        ]
      history = mustRight (parseEnvelopeEntitlementTSV source)
      transfers = envelopeEntitlementHistoryTransfers history
      food = mustRight (mkEnvelopeId "food")
      stock = mustRight (mkEnvelopeId "stock-food")

  equal "source order is preserved" 2 (length transfers)
  case transfers of
    [allocation, moved] -> do
      equal "Unallocated is an endpoint"
        Unallocated
        (entitlementTransferFrom allocation)
      equal "Envelope destination keeps stable identity"
        (Spendable food)
        (entitlementTransferTo allocation)
      equal "Envelope-to-Envelope movement stays atomic"
        (Spendable food, Spendable stock)
        (entitlementTransferFrom moved, entitlementTransferTo moved)
      equal "note remainder preserves interior tabs"
        "move\twith-tab"
        (entitlementTransferNote moved)
    unexpected -> failTest "admitted transfer shape" (show unexpected)

  right "CRLF input is admitted"
    (parseEnvelopeEntitlementTSV
      (T.replace "\n" "\r\n"
        (header <> "\n2026-08-15\t2026-08-15\t2026-10-15\tunallocated\tfood\t1\tJPY\tcrlf\n")))

sameDayHistoryLaw :: IO ()
sameDayHistoryLaw = do
  let source = T.unlines
        [ header
        , "2026-08-20\t2026-08-15\t2026-10-15\tfood\tstock-food\t5000\tJPY\tmove first in source"
        , "2026-08-20\t2026-08-15\t2026-10-15\tunallocated\tfood\t5000\tJPY\tgrant same day"
        ]
  right "same-day deltas combine before negativity is checked"
    (parseEnvelopeEntitlementTSV source)

sourceLocalBoundary :: IO ()
sourceLocalBoundary = do
  let source = T.unlines
        [ header
        , "2026-08-15\t2026-08-15\t2026-10-15\tunallocated\tfuture-envelope\t1\tJPY\tsyntax only"
        ]
  right "source admission does not reinterpret current policy"
    (parseEnvelopeEntitlementTSV source)

sourceDiagnostics :: IO ()
sourceDiagnostics = do
  assertSingleError "missing header has physical line 1"
    (\err -> envelopeEntitlementTSVErrorLine err == 1
      && envelopeEntitlementTSVErrorReason err == MissingEnvelopeEntitlementHeader)
    (parseEnvelopeEntitlementTSV "")

  assertSingleError "effective-date error names its field"
    (\err -> envelopeEntitlementTSVErrorLine err == 2
      && case envelopeEntitlementTSVErrorReason err of
        InvalidEnvelopeEntitlementDate EntitlementDate "2026/08/15" -> True
        _ -> False)
    (parseEnvelopeEntitlementTSV (T.unlines
      [ header
      , "2026/08/15\t2026-08-15\t2026-10-15\tunallocated\tfood\t1\tJPY\tbad date"
      ]))

  assertSingleError "period-start error names its field"
    (\err -> envelopeEntitlementTSVErrorLine err == 2
      && case envelopeEntitlementTSVErrorReason err of
        InvalidEnvelopeEntitlementDate EntitlementPeriodStart "bad" -> True
        _ -> False)
    (parseEnvelopeEntitlementTSV (T.unlines
      [ header
      , "2026-08-15\tbad\t2026-10-15\tunallocated\tfood\t1\tJPY\tbad period start"
      ]))

  assertSingleError "zero amount is rejected by native transfer law"
    (\err -> envelopeEntitlementTSVErrorLine err == 2
      && case envelopeEntitlementTSVErrorReason err of
        InvalidEnvelopeEntitlementTransfer _ -> True
        _ -> False)
    (parseEnvelopeEntitlementTSV (T.unlines
      [ header
      , "2026-08-15\t2026-08-15\t2026-10-15\tunallocated\tfood\t0\tJPY\tzero"
      ]))

  assertSingleError "same endpoint is rejected by native transfer law"
    (\err -> envelopeEntitlementTSVErrorLine err == 2
      && case envelopeEntitlementTSVErrorReason err of
        InvalidEnvelopeEntitlementTransfer _ -> True
        _ -> False)
    (parseEnvelopeEntitlementTSV (T.unlines
      [ header
      , "2026-08-15\t2026-08-15\t2026-10-15\tfood\tfood\t1\tJPY\tsame"
      ]))

  assertSingleError "history failure points at the overdraw row"
    (\err -> envelopeEntitlementTSVErrorLine err == 3
      && case envelopeEntitlementTSVErrorReason err of
        InvalidEnvelopeEntitlementHistory (EnvelopeEntitlementBecameNegative {}) -> True
        _ -> False)
    (parseEnvelopeEntitlementTSV (T.unlines
      [ header
      , "2026-08-15\t2026-08-15\t2026-10-15\tunallocated\tfood\t1000\tJPY\tgrant"
      , "2026-08-16\t2026-08-15\t2026-10-15\tfood\tstock-food\t2000\tJPY\toverdraw"
      ]))

header :: Text
header =
  "date\tperiod_start\tperiod_end_exclusive\tfrom\tto\tquantity\tcommodity\tnote"

assertSingleError
  :: Show value
  => String
  -> (EnvelopeEntitlementTSVError -> Bool)
  -> Either (NonEmpty.NonEmpty EnvelopeEntitlementTSVError) value
  -> IO ()
assertSingleError label predicate result = case result of
  Left errors -> case NonEmpty.toList errors of
    [err] | predicate err -> pass label
    unexpected -> failTest label ("unexpected errors: " ++ show unexpected)
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

right :: Show error => String -> Either error value -> IO ()
right label result = case result of
  Right _ -> pass label
  Left err -> failTest label ("unexpectedly rejected: " ++ show err)

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

equal :: (Eq value, Show value) => String -> value -> value -> IO ()
equal label expected actual
  | expected == actual = pass label
  | otherwise = failTest label
      ("expected " ++ show expected ++ ", but got " ++ show actual)

pass :: String -> IO ()
pass label = putStrLn ("  [PASS] " ++ label)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
