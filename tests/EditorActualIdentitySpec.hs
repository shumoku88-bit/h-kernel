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
  ( ActualIdentityCandidateSource(..)
  , ActualIdentityGenerationFailure(..)
  , actualEventIdentityMetadata
  , actualIdentityAttemptLimit
  , actualIdentityGenerationFailureText
  , generateActualTransactionId
  , generateActualTransactionIdUsing
  )
import HKernel.Plan.Completion (actualTransactionIdText)

main :: IO ()
main = do
  testDeterministicCandidateAdmission
  testEvtPrefix
  testProductionUUIDBodyFormat
  testInvalidCandidateRejection
  testCollisionWithExplicitIdentityRetry
  testCollisionWithPlanDerivedIdentityRetry
  testCollisionLimitReached
  testCandidateSourceFailure
  testSanitizedFailureDiagnostics
  testFiniteCallCount
  testIdentityNotDerivedFromSourceContent
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

-- 1. deterministic injected candidate is admitted as ActualTransactionId
testDeterministicCandidateAdmission :: IO ()
testDeterministicCandidateAdmission = do
  let src = ActualIdentityCandidateSource (pure (Right "evt-550e8400-e29b-41d4-a716-446655440000"))
  journalResult <- parseSyntheticJournal "2026-08-01 Test\n  acc:a  100 JPY\n  acc:b  -100 JPY\n"
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      res <- generateActualTransactionIdUsing src journal
      case res of
        Left err -> assert ("Expected success, got: " <> show err) False
        Right actualId ->
          assert "Admitted ID matches candidate"
            (actualTransactionIdText actualId == "evt-550e8400-e29b-41d4-a716-446655440000")

-- 2. output has "evt-" prefix
testEvtPrefix :: IO ()
testEvtPrefix = do
  journalResult <- parseSyntheticJournal "2026-08-01 Test\n  acc:a  100 JPY\n  acc:b  -100 JPY\n"
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      res <- generateActualTransactionId journal
      case res of
        Left err -> assert ("Expected production generation success, got: " <> show err) False
        Right actualId ->
          assert "Production ID has 'evt-' prefix"
            ("evt-" `T.isPrefixOf` actualTransactionIdText actualId)

-- 3. production UUID body parses as canonical UUID format
testProductionUUIDBodyFormat :: IO ()
testProductionUUIDBodyFormat = do
  journalResult <- parseSyntheticJournal "2026-08-01 Test\n  acc:a  100 JPY\n  acc:b  -100 JPY\n"
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      res <- generateActualTransactionId journal
      case res of
        Left err -> assert ("Expected production generation success, got: " <> show err) False
        Right actualId -> do
          let idText = actualTransactionIdText actualId
              uuidBody = T.drop 4 idText
          case UUID.fromText uuidBody of
            Nothing -> assert ("UUID body was not valid UUID v4 text: " <> T.unpack uuidBody) False
            Just _ -> pure ()

-- 4. candidate with whitespace returns typed invalid failure
testInvalidCandidateRejection :: IO ()
testInvalidCandidateRejection = do
  let src = ActualIdentityCandidateSource (pure (Right "evt-invalid candidate string"))
  journalResult <- parseSyntheticJournal "2026-08-01 Test\n  acc:a  100 JPY\n  acc:b  -100 JPY\n"
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      res <- generateActualTransactionIdUsing src journal
      assert "Invalid candidate yields ActualIdentityCandidateInvalid"
        (res == Left ActualIdentityCandidateInvalid)

-- 5. explicit existing identity collision triggers retry and succeeds on unique candidate
testCollisionWithExplicitIdentityRetry :: IO ()
testCollisionWithExplicitIdentityRetry = do
  let journalSource = T.unlines
        [ "2026-08-01 Existing"
        , "  ; event-id: evt-colliding-001"
        , "  acc:a  100 JPY"
        , "  acc:b  -100 JPY"
        ]
  journalResult <- parseSyntheticJournal journalSource
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      candidatesRef <- newIORef ["evt-colliding-001", "evt-unique-002"]
      let src = ActualIdentityCandidateSource $ do
            candidates <- readIORef candidatesRef
            case candidates of
              (c:cs) -> do
                modifyIORef' candidatesRef (const cs)
                pure (Right c)
              [] -> pure (Right "evt-fallback")
      res <- generateActualTransactionIdUsing src journal
      case res of
        Left err -> assert ("Expected success after retry, got: " <> show err) False
        Right actualId ->
          assert "Second unique candidate admitted after retry"
            (actualTransactionIdText actualId == "evt-unique-002")

-- 6. plan-derived runtime identity collision triggers retry and succeeds on unique candidate
testCollisionWithPlanDerivedIdentityRetry :: IO ()
testCollisionWithPlanDerivedIdentityRetry = do
  let journalSource = T.unlines
        [ "2026-08-01 Plan Completed"
        , "  ; plan-id: plan-alpha"
        , "  acc:a  100 JPY"
        , "  acc:b  -100 JPY"
        ]
  journalResult <- parseSyntheticJournal journalSource
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      -- The plan-derived runtime identity is "plan-completion-plan-alpha"
      candidatesRef <- newIORef ["plan-completion-plan-alpha", "evt-unique-after-plan-collision"]
      let src = ActualIdentityCandidateSource $ do
            candidates <- readIORef candidatesRef
            case candidates of
              (c:cs) -> do
                modifyIORef' candidatesRef (const cs)
                pure (Right c)
              [] -> pure (Right "evt-fallback")
      res <- generateActualTransactionIdUsing src journal
      case res of
        Left err -> assert ("Expected success after plan collision retry, got: " <> show err) False
        Right actualId ->
          assert "Unique candidate admitted after plan-derived collision retry"
            (actualTransactionIdText actualId == "evt-unique-after-plan-collision")

-- 7 & 8. reaching retry limit (8 attempts) returns ActualIdentityCollisionLimitReached
testCollisionLimitReached :: IO ()
testCollisionLimitReached = do
  let journalSource = T.unlines
        [ "2026-08-01 Existing"
        , "  ; event-id: evt-colliding-forever"
        , "  acc:a  100 JPY"
        , "  acc:b  -100 JPY"
        ]
  journalResult <- parseSyntheticJournal journalSource
  case journalResult of
    Left err -> assert ("Failed to parse synthetic journal: " <> err) False
    Right journal -> do
      let src = ActualIdentityCandidateSource (pure (Right "evt-colliding-forever"))
      res <- generateActualTransactionIdUsing src journal
      assert "Returns ActualIdentityCollisionLimitReached when retry limit reached"
        (res == Left ActualIdentityCollisionLimitReached)

-- 9. candidate source failure returns ActualIdentityGenerationUnavailable
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

-- 10. failure Show and renderer contain no candidate, source, path, or exception text
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

-- 11. generator call count is finite
testFiniteCallCount :: IO ()
testFiniteCallCount = do
  let journalSource = T.unlines
        [ "2026-08-01 Existing"
        , "  ; event-id: evt-always-colliding"
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
            pure (Right "evt-always-colliding")
      _ <- generateActualTransactionIdUsing src journal
      count <- readIORef countRef
      assert "Call count equals actualIdentityAttemptLimit (8)"
        (count == actualIdentityAttemptLimit)

-- 12. generated ID is not derived from existing source content
testIdentityNotDerivedFromSourceContent :: IO ()
testIdentityNotDerivedFromSourceContent = do
  let src1 = "2026-08-01 Alpha Description\n  acc:b  1000 JPY\n  acc:a  -1000 JPY\n"
      src2 = "2026-08-01 Alpha Description\n  acc:b  1000 JPY\n  acc:a  -1000 JPY\n"
  j1 <- parseSyntheticJournal src1
  j2 <- parseSyntheticJournal src2
  case (j1, j2) of
    (Right journal1, Right journal2) -> do
      id1 <- generateActualTransactionId journal1
      id2 <- generateActualTransactionId journal2
      case (id1, id2) of
        (Right res1, Right res2) ->
          assert "Two production generations for identical source produce distinct random UUIDs"
            (res1 /= res2)
        _ -> assert "Production generation failed" False
    _ -> assert "Failed to parse synthetic journals" False

-- Helper metadata check
testMetadataHelper :: IO ()
testMetadataHelper = do
  let src = ActualIdentityCandidateSource (pure (Right "evt-meta-test"))
  j <- parseSyntheticJournal "2026-08-01 Test\n  acc:a  1 JPY\n  acc:b  -1 JPY\n"
  case j of
    Right journal -> do
      res <- generateActualTransactionIdUsing src journal
      case res of
        Right actualId ->
          assert "Metadata helper produces ('event-id', text)"
            (actualEventIdentityMetadata actualId == ("event-id", "evt-meta-test"))
        Left _ -> assert "Failed generation" False
    Left err -> assert ("Failed journal parse: " <> err) False
