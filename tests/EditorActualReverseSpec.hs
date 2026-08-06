{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Actual.Journal
  ( actualJournalReversalDeclarations
  , parseActualJournal
  , reversedTransactionId
  , reversalTransactionId
  )
import HKernel.Editor.ActualIdentity (admitActualEventIdentityText)
import HKernel.Editor.ActualReverse
import HKernel.Plan.Completion
  ( actualTransactionIdText
  , mkActualTransactionId
  )
import System.Exit (exitFailure)

main :: IO ()
main = do
  let reverseDay = fromGregorian 2026 8 5

      -- Target identities of various origins
      legacyTargetId = mustRight (mkActualTransactionId "event-123")
      canonicalTargetId = mustRight (admitActualEventIdentityText "evt-550e8400-e29b-41d4-a716-446655440100")
      planDerivedTargetId = mustRight (mkActualTransactionId "plan-completion-plan-alpha")
      missingTargetId = mustRight (mkActualTransactionId "event-999")

      -- Canonical new reversal event identities (constructed via admitActualEventIdentityText)
      reversalId = mustRight (admitActualEventIdentityText "evt-550e8400-e29b-41d4-a716-446655440200")
      secondReversalId = mustRight (admitActualEventIdentityText "evt-550e8400-e29b-41d4-a716-446655440201")
      thirdReversalId = mustRight (admitActualEventIdentityText "evt-550e8400-e29b-41d4-a716-446655440202")

      -- Generic non-canonical identity for direct preparation bypass test
      nonCanonicalNewId = mustRight (mkActualTransactionId "event-123-reversal-legacy")

  let validIntent = ActualReverseIntent
        { reverseEventId = reversalId
        , reverseTargetId = legacyTargetId
        , reverseDate = reverseDay
        , reverseDescription = "Reverse mistaken expense"
        }

  let missingIntent = ActualReverseIntent
        { reverseEventId = secondReversalId
        , reverseTargetId = missingTargetId
        , reverseDate = reverseDay
        , reverseDescription = "Should not be appended"
        }

  -- 1. Canonical new ID + legacy target success (renders event-id and reverses, negates amounts, preserves order)
  let preview = mustRight (prepareActualReverse fixtureSource validIntent)
      expectedBlock = T.unlines
        [ "2026-08-05 Reverse mistaken expense"
        , "  ; event-id: evt-550e8400-e29b-41d4-a716-446655440200"
        , "  ; reverses: event-123"
        , "  assets:cash  -100 JPY"
        , "  expenses:food  100 JPY"
        ]

  assertEqual "render durable canonical reversal identity and legacy target provenance"
    expectedBlock
    (candidateBlock preview)

  -- 2. Candidate complete source is re-parseable and provenance remains typed.
  case parseActualJournal (candidateCompleteSource preview) of
    Left errs -> do
      putStrLn "  [FAIL] candidate complete source should be parseable"
      print errs
      exitFailure
    Right admitted -> do
      assertEqual "parse-back retains one typed reversal edge"
        [("evt-550e8400-e29b-41d4-a716-446655440200", "event-123")]
        [ ( actualTransactionIdText (reversalTransactionId declaration)
          , actualTransactionIdText (reversedTransactionId declaration)
          )
        | declaration <- actualJournalReversalDeclarations admitted
        ]

  -- 3. Canonical new ID + canonical explicit target success
  let canonicalTargetIntent = ActualReverseIntent
        { reverseEventId = secondReversalId
        , reverseTargetId = canonicalTargetId
        , reverseDate = reverseDay
        , reverseDescription = "Reverse canonical transaction"
        }
      canonicalTargetPreview = mustRight (prepareActualReverse fixtureSource canonicalTargetIntent)
  assertEqual "allow canonical explicit target for reversal"
    True
    ("; event-id: evt-550e8400-e29b-41d4-a716-446655440201" `T.isInfixOf` candidateBlock canonicalTargetPreview
      && "; reverses: evt-550e8400-e29b-41d4-a716-446655440100" `T.isInfixOf` candidateBlock canonicalTargetPreview)

  -- 4. Canonical new ID + plan-derived runtime target success
  let planDerivedIntent = ActualReverseIntent
        { reverseEventId = thirdReversalId
        , reverseTargetId = planDerivedTargetId
        , reverseDate = reverseDay
        , reverseDescription = "Reverse plan completion"
        }
      planDerivedPreview = mustRight (prepareActualReverse fixtureSource planDerivedIntent)
  assertEqual "allow plan-derived runtime target for reversal"
    True
    ("; event-id: evt-550e8400-e29b-41d4-a716-446655440202" `T.isInfixOf` candidateBlock planDerivedPreview
      && "; reverses: plan-completion-plan-alpha" `T.isInfixOf` candidateBlock planDerivedPreview)

  -- 5. Direct preparation bypass rejection (non-canonical new ID passed via generic ActualTransactionId)
  let bypassIntent = ActualReverseIntent
        { reverseEventId = nonCanonicalNewId
        , reverseTargetId = legacyTargetId
        , reverseDate = reverseDay
        , reverseDescription = "Direct bypass attempt"
        }
  assertLeftEqual "reject non-canonical new reversal event identity in prepareActualReverse"
    [InvalidReversalEventIdentity]
    (prepareActualReverse fixtureSource bypassIntent)

  -- 6. TargetNotFound rejection
  assertLeftEqual "reject reverse when target ID is not found"
    [TargetNotFound missingTargetId]
    (prepareActualReverse fixtureSource missingIntent)

  -- 7. Reversal identity cannot reuse an existing Actual identity (explicit or plan-derived)
  let duplicateIdentityIntent = validIntent
        { reverseEventId = canonicalTargetId }
  assertLeftEqual "reject reversal ID already present in source"
    [ReversalIdAlreadyExists canonicalTargetId]
    (prepareActualReverse fixtureSource duplicateIdentityIntent)

  let duplicatePlanDerivedCollision = validIntent
        { reverseEventId = legacyTargetId } -- legacyTargetId triggers InvalidReversalEventIdentity first because it's not canonical!
  assertLeftEqual "non-canonical existing ID triggers InvalidReversalEventIdentity before collision check"
    [InvalidReversalEventIdentity]
    (prepareActualReverse fixtureSource duplicatePlanDerivedCollision)

  -- 8. The same target cannot be reversed directly twice
  let duplicateTargetIntent = ActualReverseIntent
        { reverseEventId = secondReversalId
        , reverseTargetId = legacyTargetId
        , reverseDate = reverseDay
        , reverseDescription = "Duplicate direct reversal"
        }
  assertLeftEqual "reject a second direct reversal of one target"
    [TargetAlreadyReversed legacyTargetId reversalId]
    (prepareActualReverse
      (candidateCompleteSource preview)
      duplicateTargetIntent)

  -- 9. A reversal can itself be reversed through its own durable canonical identity
  let reverseOfReverseIntent = ActualReverseIntent
        { reverseEventId = secondReversalId
        , reverseTargetId = reversalId
        , reverseDate = reverseDay
        , reverseDescription = "Restore original effect"
        }
      reverseOfReversePreview = mustRight
        (prepareActualReverse
          (candidateCompleteSource preview)
          reverseOfReverseIntent)
  assertEqual "allow reverse-of-reverse as a new provenance edge"
    True
    ("; event-id: evt-550e8400-e29b-41d4-a716-446655440201"
      `T.isInfixOf` candidateBlock reverseOfReversePreview
      && "; reverses: evt-550e8400-e29b-41d4-a716-446655440200"
        `T.isInfixOf` candidateBlock reverseOfReversePreview)

  -- 10. Error precedence evidence:
  -- (a) Invalid new identity precedes missing target
  let invalidNewMissingTargetIntent = ActualReverseIntent
        { reverseEventId = nonCanonicalNewId
        , reverseTargetId = missingTargetId
        , reverseDate = reverseDay
        , reverseDescription = "Invalid new ID and missing target"
        }
  assertLeftEqual "InvalidReversalEventIdentity precedes TargetNotFound"
    [InvalidReversalEventIdentity]
    (prepareActualReverse fixtureSource invalidNewMissingTargetIntent)

  -- (b) Colliding new identity precedes missing target
  let collidingNewMissingTargetIntent = ActualReverseIntent
        { reverseEventId = canonicalTargetId
        , reverseTargetId = missingTargetId
        , reverseDate = reverseDay
        , reverseDescription = "Colliding new ID and missing target"
        }
  assertLeftEqual "ReversalIdAlreadyExists precedes TargetNotFound"
    [ReversalIdAlreadyExists canonicalTargetId]
    (prepareActualReverse fixtureSource collidingNewMissingTargetIntent)

  -- (c) Valid unique new identity exposes missing target
  assertLeftEqual "Valid unique new identity exposes TargetNotFound"
    [TargetNotFound missingTargetId]
    (prepareActualReverse fixtureSource missingIntent)

  -- (d) Valid unique new identity exposes already reversed target
  assertLeftEqual "Valid unique new identity exposes TargetAlreadyReversed"
    [TargetAlreadyReversed legacyTargetId reversalId]
    (prepareActualReverse
      (candidateCompleteSource preview)
      duplicateTargetIntent)

fixtureSource :: Text
fixtureSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2026-08-04 Grocery shopping"
  , "  ; event-id: event-123"
  , "  assets:cash  100 JPY"
  , "  expenses:food  -100 JPY"
  , ""
  , "2026-08-04 Canonical transaction"
  , "  ; event-id: evt-550e8400-e29b-41d4-a716-446655440100"
  , "  assets:cash  200 JPY"
  , "  expenses:food  -200 JPY"
  , ""
  , "2026-08-04 Plan completion"
  , "  ; plan-id: plan-alpha"
  , "  assets:cash  300 JPY"
  , "  expenses:food  -300 JPY"
  ]

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Left err -> error ("invalid test setup: " ++ show err)
  Right value -> value

assertLeftEqual
  :: (Eq error, Show error)
  => String
  -> [error]
  -> Either (NonEmpty.NonEmpty error) value
  -> IO ()
assertLeftEqual label expected result = case result of
  Left errors -> assertEqual label expected (NonEmpty.toList errors)
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly succeeded"
    exitFailure

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure
