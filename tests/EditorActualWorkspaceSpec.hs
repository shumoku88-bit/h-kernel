{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List (find)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account
  ( Account
  , accountDeclarations
  , accountName
  , declaredAccount
  )
import HKernel.Actual.Journal
  ( ActualTransactionEntry
  , actualJournalTransactionEntries
  , actualJournalValue
  , actualTransactionEntryIdentity
  , actualTransactionEntrySource
  , actualTransactionEntryTransaction
  , parseActualJournal
  )
import HKernel.Editor.ActualWorkspace
  ( ActualIdentityPromotionError(..)
  , ActualReverseAvailability(..)
  , actualReverseAvailability
  , externalBalanceValue
  , identityPromotionCandidateCompleteSource
  , newestTransactionEntriesForAccount
  , observeExternalBalance
  , prepareActualIdentityPromotion
  , reconcileAccountBalance
  , reconciliationDifference
  , reconciliationExternalObservation
  , reconciliationLedgerBalance
  , reconciliationMatches
  , transactionEntriesForAccount
  )
import HKernel.Editor.HouseholdWorkspace
  ( HomeActualObservation(..)
  , HomeIssueObservation(..)
  , HomeIssueObservationError(..)
  , homeActualObservationOn
  , homeIssueObservationOn
  )
import HKernel.HouseholdIssue
  ( IssueClosed(..)
  , IssueDue(..)
  , IssueStatus(..)
  , mkHouseholdIssue
  , mkHouseholdIssueWithClosed
  , mkIssueId
  )
import HKernel.Journal
  ( journalAccountRegistry
  , journalTransactionSourceHeaderLine
  )
import HKernel.Ledger (transactionDate)
import HKernel.Money
  ( balanceEntries
  , mkAmount
  , mkCommodity
  , parseQuantity
  , singletonBalance
  )
import HKernel.Plan.Completion
  ( actualTransactionIdText
  , mkActualTransactionId
  )

main :: IO ()
main = do
  source <- TIO.readFile "tests/fixtures/editor/actual-add.journal"
  fixtureResults <- case parseActualJournal source of
    Left errors -> do
      mapM_ print (NonEmpty.toList errors)
      exitFailure
    Right actualJournal -> do
      let journal = actualJournalValue actualJournal
          transactions = actualJournalTransactionEntries actualJournal
          accounts =
            map declaredAccount
              (accountDeclarations (journalAccountRegistry journal))
      pure
        [("no Account filter preserves all Actual transactions"
          , length (transactionEntriesForAccount Nothing transactions)
              == length transactions)
        , ("selected Account retains matching Actual transactions"
          , matchesAllFor "assets:cash" accounts transactions)
        , ("selected Account excludes non-matching Actual transactions"
          , matchesNoneFor "expenses:food" accounts transactions)
        ]

  let alignedJournal = mustRight (parseActualJournal duplicateShapeSource)
      alignedEntries = actualJournalTransactionEntries alignedJournal
      newestEntries = newestTransactionEntriesForAccount Nothing alignedEntries
      alignmentResult =
        ( "source-position identity survives duplicate Transaction values"
        , map (fmap actualTransactionIdText . actualTransactionEntryIdentity)
            alignedEntries
            == [Nothing, Just "actual-second"]
        )
      sourceEvidenceResult =
        ( "Actual entries retain parser-owned source evidence from the same observation"
        , map
            (journalTransactionSourceHeaderLine . actualTransactionEntrySource)
            alignedEntries
            == [9, 13]
        )
      newestFirstResult =
        ( "newest-first projection reverses display without changing source entries"
        , map (fmap actualTransactionIdText . actualTransactionEntryIdentity)
            newestEntries
            == [Just "actual-second", Nothing]
            && map
                (journalTransactionSourceHeaderLine . actualTransactionEntrySource)
                newestEntries
              == [13, 9]
            && map (fmap actualTransactionIdText . actualTransactionEntryIdentity)
                alignedEntries
              == [Nothing, Just "actual-second"]
            && map
                (journalTransactionSourceHeaderLine . actualTransactionEntrySource)
                alignedEntries
              == [9, 13]
        )
      promotedId = mustRight (mkActualTransactionId "actual-first")
      displayedIdentityFree = last newestEntries
      promotionPreview = mustRight
        (prepareActualIdentityPromotion
          alignedJournal
          duplicateShapeSource
          displayedIdentityFree
          promotedId)
      promotedSource = identityPromotionCandidateCompleteSource promotionPreview
      promotedJournal = mustRight (parseActualJournal promotedSource)
      promotionResult =
        ( "identity promotion targets selected source evidence without changing accounting meaning"
        , actualJournalValue promotedJournal == actualJournalValue alignedJournal
            && map (fmap actualTransactionIdText . actualTransactionEntryIdentity)
                (actualJournalTransactionEntries promotedJournal)
              == [Just "actual-first", Just "actual-second"]
            && "2026-08-08 Same transaction\n  ; event-id: actual-first\n  assets:cash"
                `T.isInfixOf` promotedSource
        )
      staleSourceResult =
        ( "identity promotion rejects source text from a different observation"
        , case prepareActualIdentityPromotion
            alignedJournal
            ("\n" <> duplicateShapeSource)
            displayedIdentityFree
            promotedId of
            Left ActualIdentityPromotionSourceObservationMismatch -> True
            _ -> False
        )
      alreadyIdentifiedResult =
        ( "identity promotion rejects an already identified selected Actual"
        , case prepareActualIdentityPromotion
            alignedJournal
            duplicateShapeSource
            (head newestEntries)
            promotedId of
            Left (ActualIdentityPromotionAlreadyIdentified existingId) ->
              actualTransactionIdText existingId == "actual-second"
            _ -> False
        )
      duplicateIdentityResult =
        ( "identity promotion rejects collision with an existing durable Actual identity"
        , case prepareActualIdentityPromotion
            alignedJournal
            duplicateShapeSource
            displayedIdentityFree
            (mustRight (mkActualTransactionId "actual-second")) of
            Left (ActualIdentityPromotionIdAlreadyExists existingId) ->
              actualTransactionIdText existingId == "actual-second"
            _ -> False
        )
      reverseJournal = mustRight (parseActualJournal reverseAvailabilitySource)
      reverseEntries = actualJournalTransactionEntries reverseJournal
      identityFreeEntry = reverseEntries !! 0
      targetEntry = reverseEntries !! 1
      reversalEntry = reverseEntries !! 2
      targetId = mustRight (mkActualTransactionId "actual-target")
      reversalId = mustRight (mkActualTransactionId "actual-target-reversal")
      reverseIdentityResult =
        ( "identity-free Actual is not a reverse target"
        , actualReverseAvailability reverseJournal identityFreeEntry
            == ActualReverseIdentityMissing
        )
      alreadyReversedResult =
        ( "directly reversed Actual reports its typed reversal edge"
        , actualReverseAvailability reverseJournal targetEntry
            == ActualReverseAlreadyReversed targetId reversalId
        )
      reverseOfReverseResult =
        ( "a reversal remains available as a reverse-of-reverse target"
        , actualReverseAvailability reverseJournal reversalEntry
            == ActualReverseAvailable reversalId
        )
      reconciliationJournal = mustRight (parseActualJournal reconciliationSource)
      reconciliationEntries = actualJournalTransactionEntries reconciliationJournal
      (rewardDay, purchaseDay) = case map
          (transactionDate . actualTransactionEntryTransaction)
          reconciliationEntries of
        [firstDay, secondDay] -> (firstDay, secondDay)
        _ -> error "invalid reconciliation fixture: expected two transactions"
      reconciliationLedger = actualJournalValue reconciliationJournal
      reconciliationRegistry = journalAccountRegistry reconciliationLedger
      paypay = mustJust
        (accountNamed "assets:paypay"
          (map declaredAccount (accountDeclarations reconciliationRegistry)))
      jpy = mustRight (mkCommodity "JPY")
      quantity = mustRight . parseQuantity
      external710 = singletonBalance (mkAmount jpy (quantity "710"))
      external700 = singletonBalance (mkAmount jpy (quantity "700"))
      external1000 = singletonBalance (mkAmount jpy (quantity "1000"))
      differenceObservation = observeExternalBalance
        paypay purchaseDay external710
      differenceReconciliation = reconcileAccountBalance
        reconciliationLedger differenceObservation
      matchedReconciliation = reconcileAccountBalance reconciliationLedger
        (observeExternalBalance paypay purchaseDay external700)
      historicalReconciliation = reconcileAccountBalance reconciliationLedger
        (observeExternalBalance paypay rewardDay external1000)
      differenceLawResult =
        ( "reconciliation difference is exact external minus ledger"
        , balanceEntries (reconciliationLedgerBalance differenceReconciliation)
            == [(jpy, quantity "700")]
          && balanceEntries (reconciliationDifference differenceReconciliation)
            == [(jpy, quantity "10")]
        )
      matchLawResult =
        ( "matching external observation is the unique zero difference"
        , reconciliationMatches matchedReconciliation
          && null (balanceEntries (reconciliationDifference matchedReconciliation))
        )
      observationDayResult =
        ( "reconciliation compares the ledger at the external observation day"
        , reconciliationMatches historicalReconciliation
          && externalBalanceValue
              (reconciliationExternalObservation historicalReconciliation)
            == external1000
        )
      futureActualUnavailableResult =
        ( "Home does not leak future Actual through an earlier observation horizon"
        , homeActualObservationOn rewardDay purchaseDay reconciliationJournal
            == HomeActualUnavailable
        )
      actualOwnDayAvailableResult =
        ( "Home distinguishes an available Actual day from unavailable future knowledge"
        , case homeActualObservationOn
            purchaseDay purchaseDay reconciliationJournal of
            HomeActualAvailable [transaction] ->
              transactionDate transaction == purchaseDay
            _ -> False
        )
      issueId = mustRight (mkIssueId "issue-temporal")
      issueClosedAfterHorizon = mustRight (mkHouseholdIssueWithClosed
        issueId
        rewardDay
        Resolved
        (DueOn purchaseDay)
        (ClosedOn purchaseDay)
        Nothing
        "Temporal issue"
        "")
      issueClosedAfterHorizonResult =
        ( "Issue closed after the horizon remains open as-of the earlier observation"
        , homeIssueObservationOn
            rewardDay purchaseDay [issueClosedAfterHorizon]
            == HomeIssueAvailable [issueClosedAfterHorizon]
        )
      issueClosedAtHorizonResult =
        ( "Issue closure becomes visible at its own observation day"
        , homeIssueObservationOn
            purchaseDay purchaseDay [issueClosedAfterHorizon]
            == HomeIssueAvailable []
        )
      issueUnknownClosure = mustRight (mkHouseholdIssue
        (mustRight (mkIssueId "issue-unknown-closure"))
        rewardDay
        Resolved
        (DueOn purchaseDay)
        Nothing
        "Historical closure without date"
        "")
      issueUnknownClosureResult =
        ( "unknown historical closure is unavailable rather than guessed"
        , case homeIssueObservationOn
            rewardDay purchaseDay [issueUnknownClosure] of
            HomeIssueUnavailable errors -> case NonEmpty.toList errors of
              [HomeIssueClosureUndetermined _] -> True
              _ -> False
            _ -> False
        )
      issueFutureRecorded = mustRight (mkHouseholdIssue
        (mustRight (mkIssueId "issue-future-recorded"))
        purchaseDay
        Open
        (DueOn purchaseDay)
        Nothing
        "Not known yet"
        "")
      issueFutureRecordedResult =
        ( "future-recorded Issue is absent rather than unavailable"
        , homeIssueObservationOn
            rewardDay purchaseDay [issueFutureRecorded]
            == HomeIssueAvailable []
        )
      results = fixtureResults ++
        [ alignmentResult
        , sourceEvidenceResult
        , newestFirstResult
        , promotionResult
        , staleSourceResult
        , alreadyIdentifiedResult
        , duplicateIdentityResult
        , reverseIdentityResult
        , alreadyReversedResult
        , reverseOfReverseResult
        , differenceLawResult
        , matchLawResult
        , observationDayResult
        , futureActualUnavailableResult
        , actualOwnDayAvailableResult
        , issueClosedAfterHorizonResult
        , issueClosedAtHorizonResult
        , issueUnknownClosureResult
        , issueFutureRecordedResult
        ]

  mapM_ print results
  if all snd results then exitSuccess else exitFailure

matchesAllFor
  :: Text
  -> [Account]
  -> [ActualTransactionEntry]
  -> Bool
matchesAllFor expectedName accounts transactions =
  case accountNamed expectedName accounts of
    Nothing -> False
    Just account ->
      length (transactionEntriesForAccount (Just account) transactions)
        == length transactions

matchesNoneFor
  :: Text
  -> [Account]
  -> [ActualTransactionEntry]
  -> Bool
matchesNoneFor expectedName accounts transactions =
  case accountNamed expectedName accounts of
    Nothing -> False
    Just account -> null (transactionEntriesForAccount (Just account) transactions)

accountNamed :: Text -> [Account] -> Maybe Account
accountNamed expectedName =
  find ((== expectedName) . accountName)

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Left err -> error ("invalid test setup: " ++ show err)
  Right value -> value

mustJust :: Maybe value -> value
mustJust value = case value of
  Nothing -> error "invalid test setup: expected value"
  Just found -> found

duplicateShapeSource :: Text
duplicateShapeSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2026-08-08 Same transaction"
  , "  assets:cash  -100 JPY"
  , "  expenses:food  100 JPY"
  , ""
  , "2026-08-08 Same transaction"
  , "  ; event-id: actual-second"
  , "  assets:cash  -100 JPY"
  , "  expenses:food  100 JPY"
  ]

reverseAvailabilitySource :: Text
reverseAvailabilitySource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2026-08-08 Identity free"
  , "  assets:cash  -50 JPY"
  , "  expenses:food  50 JPY"
  , ""
  , "2026-08-09 Reversible target"
  , "  ; event-id: actual-target"
  , "  assets:cash  -100 JPY"
  , "  expenses:food  100 JPY"
  , ""
  , "2026-08-10 Reverse target"
  , "  ; event-id: actual-target-reversal"
  , "  ; reverses: actual-target"
  , "  assets:cash  100 JPY"
  , "  expenses:food  -100 JPY"
  ]

reconciliationSource :: Text
reconciliationSource = T.unlines
  [ "account assets:paypay"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "account income:rewards"
  , "  type: Income"
  , "  commodity: JPY"
  , ""
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2026-08-10 Reward"
  , "  assets:paypay  1000 JPY"
  , "  income:rewards  -1000 JPY"
  , ""
  , "2026-08-15 Purchase"
  , "  assets:paypay  -300 JPY"
  , "  expenses:food  300 JPY"
  ]
