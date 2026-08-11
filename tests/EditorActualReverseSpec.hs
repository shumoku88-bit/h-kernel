{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (assertEqual)
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
import HKernel.Editor.ActualReverse
import HKernel.Journal (parseJournal)
import HKernel.Plan.Completion
  ( actualTransactionIdText
  , mkActualTransactionId
  )
import System.Exit (exitFailure)

main :: IO ()
main = do
  let reverseDay = fromGregorian 2026 8 5
      targetId = mustRight (mkActualTransactionId "event-123")
      reversalId = mustRight (mkActualTransactionId "event-123-reversal-1")
      secondReversalId = mustRight
        (mkActualTransactionId "event-123-reversal-2")
      missingId = mustRight (mkActualTransactionId "event-999")

  let validIntent = ActualReverseIntent
        { reverseEventId = reversalId
        , reverseTargetId = targetId
        , reverseDate = reverseDay
        , reverseDescription = "Reverse mistaken expense"
        }

  let missingIntent = ActualReverseIntent
        { reverseEventId = secondReversalId
        , reverseTargetId = missingId
        , reverseDate = reverseDay
        , reverseDescription = "Should not be appended"
        }

  -- 1. Valid append block preview retains both identities.
  -- Exact amounts are negated properly and posting order is preserved.
  let preview = mustRight (prepareActualReverse fixtureSource validIntent)
      expectedBlock = T.unlines
        [ "2026-08-05 Reverse mistaken expense"
        , "  ; event-id: event-123-reversal-1"
        , "  ; reverses: event-123"
        , "  assets:cash  -100 JPY"
        , "  expenses:food  100 JPY"
        ]

  assertEqual "render durable reversal identity and provenance"
    expectedBlock
    (candidateBlock preview)

  let resolvedJournal = mustRight (parseJournal resolvedFixtureSource)
      resolvedPreview = mustRight
        (prepareActualReverseFromResolvedJournal
          resolvedJournal
          resolvedActualRoot
          validIntent)
  assertEqual "reverse using declarations outside the Actual root"
    expectedBlock
    (candidateBlock resolvedPreview)

  -- 2. Delivery-neutral input keeps the target typed and converges on the
  -- same reversal candidate as the explicit intent path.
  let validInput = ActualReverseInput
        { reverseInputEventIdText = "event-123-reversal-1"
        , reverseInputDateText = "2026-08-05"
        , reverseInputDescriptionText = "Reverse mistaken expense"
        }
  assertEqual "build reversal intent around the selected typed target"
    (Right validIntent)
    (buildActualReverseIntent targetId validInput)
  assertEqual "delivery input prepares the same validated reversal block"
    (ActualReverseCandidateReady expectedBlock)
    (prepareActualReverseInputFromResolvedJournal
      resolvedJournal resolvedActualRoot targetId validInput)
  assertEqual "reject malformed reversal identity before candidate creation"
    (Left ActualReverseInvalidEventId)
    (buildActualReverseIntent targetId
      validInput { reverseInputEventIdText = "bad event id" })
  assertEqual "reject malformed reversal date before candidate creation"
    (Left ActualReverseInvalidDate)
    (buildActualReverseIntent targetId
      validInput { reverseInputDateText = "2026-99-99" })
  assertEqual "suggest the simple reversal identity when it is free"
    "event-123-reversal"
    (suggestActualReverseEventIdText [targetId] targetId)
  assertEqual "skip an occupied suggested reversal identity"
    "event-123-reversal-2"
    (suggestActualReverseEventIdText
      [ targetId
      , mustRight (mkActualTransactionId "event-123-reversal")
      ]
      targetId)

  -- 3. Candidate complete source is re-parseable and provenance remains typed.
  case parseActualJournal (candidateCompleteSource preview) of
    Left errs -> do
      putStrLn "  [FAIL] candidate complete source should be parseable"
      print errs
      exitFailure
    Right admitted -> do
      assertEqual "parse-back retains one typed reversal edge"
        [("event-123-reversal-1", "event-123")]
        [ ( actualTransactionIdText (reversalTransactionId declaration)
          , actualTransactionIdText (reversedTransactionId declaration)
          )
        | declaration <- actualJournalReversalDeclarations admitted
        ]

  -- 4. TargetNotFound rejection.
  assertLeftEqual "reject reverse when target ID is not found"
    [TargetNotFound missingId]
    (prepareActualReverse fixtureSource missingIntent)

  -- 5. Reversal identity cannot reuse an existing Actual identity.
  let duplicateIdentityIntent = validIntent
        { reverseEventId = targetId }
  assertLeftEqual "reject reversal ID already present in source"
    [ReversalIdAlreadyExists targetId]
    (prepareActualReverse fixtureSource duplicateIdentityIntent)

  -- 6. The same target cannot be reversed directly twice.
  let duplicateTargetIntent = ActualReverseIntent
        { reverseEventId = secondReversalId
        , reverseTargetId = targetId
        , reverseDate = reverseDay
        , reverseDescription = "Duplicate direct reversal"
        }
  assertLeftEqual "reject a second direct reversal of one target"
    [TargetAlreadyReversed targetId reversalId]
    (prepareActualReverse
      (candidateCompleteSource preview)
      duplicateTargetIntent)

  -- 7. A reversal can itself be reversed through its own durable identity.
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
    ("; event-id: event-123-reversal-2"
      `T.isInfixOf` candidateBlock reverseOfReversePreview
      && "; reverses: event-123-reversal-1"
        `T.isInfixOf` candidateBlock reverseOfReversePreview)

resolvedActualRoot :: Text
resolvedActualRoot = T.unlines
  [ "include accounts.journal"
  , ""
  , "2026-08-04 Grocery shopping"
  , "  ; event-id: event-123"
  , "  assets:cash  100 JPY"
  , "  expenses:food  -100 JPY"
  ]

resolvedFixtureSource :: Text
resolvedFixtureSource = fixtureSource

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

