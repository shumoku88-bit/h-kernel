{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.IORef (newIORef, readIORef, modifyIORef')
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import System.Exit (exitFailure)

import HKernel.Actual.Journal (ActualJournal, parseActualJournal)
import HKernel.Editor.ActualIdentity
  ( ActualEventIdentityAdmissionFailure(..)
  , ActualIdentityCandidateSource(..)
  , ActualIdentityGenerationFailure(..)
  , actualEventIdentityMetadata
  , actualIdentityAttemptLimit
  , actualIdentityGenerationFailureText
  , actualIdentityIsAlreadyUsed
  , admitActualEventIdentityText
  , generateActualTransactionId
  , generateActualTransactionIdUsing
  )
import HKernel.Plan.Completion
  ( actualTransactionIdText
  , mkActualTransactionId
  )

main :: IO ()
main = do
  testCanonicalAdmissionSuccess
  testCanonicalAdmissionRejections
  testDeterministicCandidateAdmission
  testInvalidCandidateRejection
  testCollisionWithExplicitIdentityRetry
  testEffectiveIdentityMembership
  testCollisionLimitReached
  testCandidateSourceFailure
  testSanitizedFailureDiagnostics
  testFiniteCallCount
  testDeterministicCandidateSelection
  testProductionUUIDSmokeTest
  testMetadataHelper
  putStrLn "EditorActualIdentitySpec: ALL PASSED"

assert :: String -> Bool -> IO ()
assert _ True = pure ()
assert msg False = do
  putStrLn ("FAIL: " <> msg)
  exitFailure

syntheticHeader :: Text
syntheticHeader = T.unlines
  [ "account acc:a"
  , "    type: asset"
  , "    commodity: JPY"
  , ""
  , "account acc:b"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  ]

parseSyntheticJournal :: Text -> IO (Either String ActualJournal)
parseSyntheticJournal src = case parseActualJournal (syntheticHeader <> src) of
  Left err -> pure (Left (show err))
  Right j -> pure (Right j)

-- 1. Canonical lowercase UUID v4 admission succeeds
testCanonicalAdmissionSuccess :: IO ()
testCanonicalAdmissionSuccess = do
  let validText = "evt-550e8400-e29b-41d4-a716-446655440000"
  case admitActualEventIdentityText validText of
    Left _ -> assert "Canonical UUID v4 text admitted" False
    Right actualId ->
      assert "Admitted ID text matches input"
        (actualTransactionIdText actualId == validText)

-- 2. Pure admission boundary rejects non-canonical texts
testCanonicalAdmissionRejections :: IO ()
testCanonicalAdmissionRejections = do
  let rejected =
        [ ("missing prefix", "550e8400-e29b-41d4-a716-446655440000")
        , ("arbitrary text", "banana")
        , ("legacy synthetic id", "evt-synthetic-cli-001")
        , ("uppercase UUID", "evt-550E8400-E29B-41D4-A716-446655440000")
        , ("UUID v1", "evt-550e8400-e29b-11d4-a716-446655440000")
        , ("UUID v3", "evt-550e8400-e29b-31d4-a716-446655440000")
        , ("UUID v5", "evt-550e8400-e29b-51d4-a716-446655440000")
        , ("nil UUID", "evt-00000000-0000-0000-0000-000000000000")
        , ("invalid variant c", "evt-550e8400-e29b-41d4-c716-446655440000")
        , ("trailing text", "evt-550e8400-e29b-41d4-a716-446655440000-extra")
        , ("extra whitespace", " evt-550e8400-e29b-41d4-a716-446655440000 ")
        ]
  mapM_ checkRejection rejected
  where
    checkRejection (label, val) =
      assert ("Rejected: " <> label)
        (admitActualEventIdentityText val == Left ActualEventIdentityFormatInvalid)

-- 3. Deterministic injected canonical candidate is admitted as ActualTransactionId
testDeterministicCandidateAdmission :: IO ()
testDeterministicCandidateAdmission = do
  let candidate = "evt-550e8400-e29b-41d4-a716-446655440000"
      src = ActualIdentityCandidateSource (pure (Right candidate))
  journalResult <- parseSyntheticJournal "2026-08-01 Test\n  acc:a  100 JPY\n  acc:b  -100 JPY\n"
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      res <- generateActualTransactionIdUsing src journal
      case res of
        Left err -> assert ("Expected success, got: " <> show err) False
        Right actualId ->
          assert "Admitted ID matches candidate"
            (actualTransactionIdText actualId == candidate)

-- 4. Candidate violating canonical format returns typed invalid failure
testInvalidCandidateRejection :: IO ()
testInvalidCandidateRejection = do
  let invalidCandidates =
        [ "evt-synthetic-cli-001"
        , "banana"
        , "evt-550E8400-E29B-41D4-A716-446655440000"
        ]
  mapM_ checkCandidate invalidCandidates
  where
    checkCandidate cand = do
      let src = ActualIdentityCandidateSource (pure (Right cand))
      journalResult <- parseSyntheticJournal "2026-08-01 Test\n  acc:a  100 JPY\n  acc:b  -100 JPY\n"
      case journalResult of
        Left err -> assert ("Failed to parse synthetic journal: " <> err) False
        Right journal -> do
          res <- generateActualTransactionIdUsing src journal
          assert ("Invalid candidate yields ActualIdentityCandidateInvalid: " <> T.unpack cand)
            (res == Left ActualIdentityCandidateInvalid)

-- 5. Explicit existing identity collision triggers retry and succeeds on unique candidate
testCollisionWithExplicitIdentityRetry :: IO ()
testCollisionWithExplicitIdentityRetry = do
  let collidingId = "evt-550e8400-e29b-41d4-a716-446655440001"
      uniqueId = "evt-550e8400-e29b-41d4-a716-446655440002"
      journalSource = T.unlines
        [ "2026-08-01 Existing"
        , "  ; event-id: " <> collidingId
        , "  acc:a  100 JPY"
        , "  acc:b  -100 JPY"
        ]
  journalResult <- parseSyntheticJournal journalSource
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      candidatesRef <- newIORef [collidingId, uniqueId]
      let src = ActualIdentityCandidateSource $ do
            candidates <- readIORef candidatesRef
            case candidates of
              (c:cs) -> do
                modifyIORef' candidatesRef (const cs)
                pure (Right c)
              [] -> pure (Right "evt-550e8400-e29b-41d4-a716-446655440009")
      res <- generateActualTransactionIdUsing src journal
      case res of
        Left err -> assert ("Expected success after retry, got: " <> show err) False
        Right actualId ->
          assert "Second unique candidate admitted after retry"
            (actualTransactionIdText actualId == uniqueId)

-- 6. Effective identity membership contains both explicit and plan-derived identities
testEffectiveIdentityMembership :: IO ()
testEffectiveIdentityMembership = do
  let journalSource = T.unlines
        [ "2026-08-01 Explicit"
        , "  ; event-id: evt-550e8400-e29b-41d4-a716-446655440010"
        , "  acc:a  100 JPY"
        , "  acc:b  -100 JPY"
        , ""
        , "2026-08-01 Plan Derived"
        , "  ; plan-id: plan-alpha"
        , "  acc:a  50 JPY"
        , "  acc:b  -50 JPY"
        ]
  journalResult <- parseSyntheticJournal journalSource
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      case
        ( admitActualEventIdentityText "evt-550e8400-e29b-41d4-a716-446655440010"
        , mkActualTransactionId "plan-completion-plan-alpha"
        , admitActualEventIdentityText "evt-550e8400-e29b-41d4-a716-446655440099"
        ) of
        (Right explicitId, Right planDerivedId, Right unknownId) -> do
          assert "Explicit event identity is already used"
            (actualIdentityIsAlreadyUsed journal explicitId)
          assert "Plan-derived runtime identity is already used"
            (actualIdentityIsAlreadyUsed journal planDerivedId)
          assert "Unknown identity is not used"
            (not (actualIdentityIsAlreadyUsed journal unknownId))
        _ -> assert "Failed to construct test IDs" False

-- 7. Reaching retry limit (8 attempts) returns ActualIdentityCollisionLimitReached
testCollisionLimitReached :: IO ()
testCollisionLimitReached = do
  let collidingId = "evt-550e8400-e29b-41d4-a716-446655440001"
      journalSource = T.unlines
        [ "2026-08-01 Existing"
        , "  ; event-id: " <> collidingId
        , "  acc:a  100 JPY"
        , "  acc:b  -100 JPY"
        ]
  journalResult <- parseSyntheticJournal journalSource
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      let src = ActualIdentityCandidateSource (pure (Right collidingId))
      res <- generateActualTransactionIdUsing src journal
      assert "Returns ActualIdentityCollisionLimitReached when retry limit reached"
        (res == Left ActualIdentityCollisionLimitReached)

-- 8. Candidate source failure returns ActualIdentityGenerationUnavailable
testCandidateSourceFailure :: IO ()
testCandidateSourceFailure = do
  let src = ActualIdentityCandidateSource (pure (Left ActualIdentityGenerationUnavailable))
  journalResult <- parseSyntheticJournal "2026-08-01 Test\n  acc:a  100 JPY\n  acc:b  -100 JPY\n"
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      res <- generateActualTransactionIdUsing src journal
      assert "Propagates ActualIdentityGenerationUnavailable"
        (res == Left ActualIdentityGenerationUnavailable)

-- 9. Failure Show and renderer contain no candidate, source, path, or exception text
testSanitizedFailureDiagnostics :: IO ()
testSanitizedFailureDiagnostics = do
  let failures =
        [ ActualIdentityGenerationUnavailable
        , ActualIdentityCandidateInvalid
        , ActualIdentityCollisionLimitReached
        ]
  mapM_ checkSanitization failures
  where
    checkSanitization failure = do
      let showText = show failure
          userText = T.unpack (actualIdentityGenerationFailureText failure)
      assert "Show output does not leak path or internal state"
        (not ("/" `isInfixOf` showText) && not ("IOException" `isInfixOf` showText))
      assert "Sanitized failure text does not leak path or internal state"
        (not ("/" `isInfixOf` userText) && not ("IOException" `isInfixOf` userText))

-- 10. Generator call count is finite
testFiniteCallCount :: IO ()
testFiniteCallCount = do
  let collidingId = "evt-550e8400-e29b-41d4-a716-446655440001"
      journalSource = T.unlines
        [ "2026-08-01 Existing"
        , "  ; event-id: " <> collidingId
        , "  acc:a  100 JPY"
        , "  acc:b  -100 JPY"
        ]
  journalResult <- parseSyntheticJournal journalSource
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      countRef <- newIORef (0 :: Int)
      let src = ActualIdentityCandidateSource $ do
            modifyIORef' countRef (+1)
            pure (Right collidingId)
      _ <- generateActualTransactionIdUsing src journal
      count <- readIORef countRef
      assert "Call count equals actualIdentityAttemptLimit (8)"
        (count == actualIdentityAttemptLimit)

-- 11. Deterministic candidate selection proves identity is not derived from source content
testDeterministicCandidateSelection :: IO ()
testDeterministicCandidateSelection = do
  let candA = "evt-550e8400-e29b-41d4-a716-4466554400a1"
      candB = "evt-550e8400-e29b-41d4-a716-4466554400b2"
      srcA = ActualIdentityCandidateSource (pure (Right candA))
      srcB = ActualIdentityCandidateSource (pure (Right candB))
      journalSource = "2026-08-01 Identical Source\n  acc:b  1000 JPY\n  acc:a  -1000 JPY\n"
  jResult <- parseSyntheticJournal journalSource
  case jResult of
    Right journal -> do
      resA <- generateActualTransactionIdUsing srcA journal
      resB <- generateActualTransactionIdUsing srcB journal
      case (resA, resB) of
        (Right idA, Right idB) -> do
          assert "Candidate A produces candidate A" (actualTransactionIdText idA == candA)
          assert "Candidate B produces candidate B" (actualTransactionIdText idB == candB)
        _ -> assert "Generation failed unexpectedly" False
    Left err -> assert ("Failed journal parse: " <> err) False

-- 12. Production UUID v4 candidate generator smoke test
testProductionUUIDSmokeTest :: IO ()
testProductionUUIDSmokeTest = do
  journalResult <- parseSyntheticJournal "2026-08-01 Test\n  acc:a  100 JPY\n  acc:b  -100 JPY\n"
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      res <- generateActualTransactionId journal
      case res of
        Left _ -> assert "Expected production generation success" False
        Right actualId -> do
          let idText = actualTransactionIdText actualId
          assert "Production candidate has 'evt-' prefix"
            ("evt-" `T.isPrefixOf` idText)
          let uuidBody = T.drop 4 idText
          case UUID.fromText uuidBody of
            Nothing -> assert "UUID body parses via UUID.fromText" False
            Just uuid -> do
              assert "UUID.toText round-trip equality"
                (UUID.toText uuid == uuidBody)
              case T.splitOn "-" uuidBody of
                [_, _, group3, group4, _] -> do
                  assert "Version nibble is 4" (T.take 1 group3 == "4")
                  assert "Variant nibble is 8, 9, a, or b"
                    (T.take 1 group4 `elem` ["8", "9", "a", "b"])
                _ -> assert "UUID hyphenated group count is 5" False

-- Helper metadata check
testMetadataHelper :: IO ()
testMetadataHelper = do
  let candidate = "evt-550e8400-e29b-41d4-a716-446655440000"
  case admitActualEventIdentityText candidate of
    Right actualId ->
      assert "Metadata helper produces ('event-id', canonicalText)"
        (actualEventIdentityMetadata actualId == ("event-id", candidate))
    Left _ -> assert "Failed admission" False

