{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (accountName, mkAccount)
import HKernel.Editor.ActualAppend
  ( ActualAddInput(..)
  , ActualAddInputError(..)
  , ActualAddPreview(..)
  , ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , ActualEditIntent(..)
  , buildActualAddIntent
  , buildActualAddIntentWithRegistry
  , classifyActualAddWriteResult
  , prepareActualAddPreview
  )
import HKernel.Editor.ActualWriter (WriteError(..))
import HKernel.Editor.Interaction.ActualAdd
  ( AccountSelectionTarget(..)
  , ActualAddAction(..)
  , ActualAddMode(..)
  , ActualAddState(..)
  , dailyAccountCandidates
  , filterDailyAccountCandidates
  , enterActualAddPreview
  , initialActualAddState
  , initialActualAddStateForDay
  , setActualAddDate
  , transitionActualAdd
  )
import HKernel.Editor.TransactionBlock (IntentPosting(..))
import HKernel.Journal
  ( journalAccountRegistry
  , journalTransactions
  , parseJournal
  )
import HKernel.Money (commodityCode, renderQuantity)

main :: IO ()
main = do
  source <- TIO.readFile "tests/fixtures/editor/actual-add.journal"
  let results =
        [ ("positive magnitude builds balanced typed intent", testPositiveMagnitude)
        , ("negative magnitude is rejected", testNegativeMagnitude)
        , ("zero magnitude is rejected", testZeroMagnitude)
        , ("amount shape is explicit without registry", testAmountShape)
        , ("daily amount infers canonical default commodity", testDefaultCommodityInference source)
        , ("conflicting defaults fail before candidate creation", testConflictingDefaults)
        , ("missing defaults fail before candidate creation", testMissingDefaults)
        , ("daily entry starts on supplied day", testInitialDay)
        , ("daily entry can switch to yesterday", testYesterday)
        , ("expense candidates are typed and recent-first", testExpenseCandidates)
        , ("payment candidates are typed, recent-first, and retain unused Accounts", testPaymentCandidates)
        , ("candidate search is case-insensitive and order-preserving", testCandidateSearch)
        , ("empty candidate search preserves recent-first list", testEmptyCandidateSearch)
        , ("from Account selection updates input", testFromSelection)
        , ("cancelled selection preserves input", testCancelSelection)
        , ("preview transition retains candidate block only", testPreviewTransition source)
        , ("rejected preview cannot enter confirmation", testRejectedPreviewCannotConfirm source)
        , ("ready preview enters confirmation", testReadyPreviewEntersConfirmation source)
        , ("confirmation cancellation returns to ready preview", testConfirmationCancellation source)
        , ("accepted confirmation remains source-free until delivery", testConfirmationAccepted source)
        , ("successful write result is observable", testWriteSuccess)
        , ("stale write result is observable", testWriteStale)
        , ("restored admission failure is recoverable", testWriteRecovered)
        , ("failed restoration requires verification", testWriteRecoveryFailure)
        , ("filesystem failure is observable", testWriteFileIOFailure)
        ]
  mapM_ print results
  if all snd results then exitSuccess else exitFailure

validInput :: ActualAddInput
validInput = ActualAddInput
  { addDateText = "2026-08-05"
  , addDescriptionText = "Groceries"
  , addFromAccountText = "assets:cash"
  , addToAccountText = "expenses:food"
  , addAmountText = "100 JPY"
  }

expectedBlock :: T.Text
expectedBlock = T.unlines
  [ "2026-08-05 Groceries"
  , "  expenses:food  100 JPY"
  , "  assets:cash  -100 JPY"
  ]

testPositiveMagnitude :: Bool
testPositiveMagnitude = case buildActualAddIntent validInput of
  Right intent -> case NonEmpty.toList (intentPostings intent) of
    [destination, source] ->
      accountName (intentAccount destination) == "expenses:food"
        && renderQuantity (intentQuantity destination) == "100"
        && accountName (intentAccount source) == "assets:cash"
        && renderQuantity (intentQuantity source) == "-100"
        && intentMetadata intent == []
    _ -> False
  Left _ -> False

testNegativeMagnitude :: Bool
testNegativeMagnitude =
  buildActualAddIntent (validInput { addAmountText = "-100 JPY" })
    == Left ActualAddAmountMustBePositive

testZeroMagnitude :: Bool
testZeroMagnitude =
  buildActualAddIntent (validInput { addAmountText = "0 JPY" })
    == Left ActualAddAmountMustBePositive

testAmountShape :: Bool
testAmountShape =
  buildActualAddIntent (validInput { addAmountText = "100" })
    == Left ActualAddInvalidAmountShape

testDefaultCommodityInference :: T.Text -> Bool
testDefaultCommodityInference source =
  case parseJournal source of
    Left _ -> False
    Right journal ->
      case buildActualAddIntentWithRegistry
          (journalAccountRegistry journal)
          (validInput { addAmountText = "100" }) of
        Left _ -> False
        Right intent -> case NonEmpty.toList (intentPostings intent) of
          [destination, sourcePosting] ->
            showCommodity destination == "JPY"
              && showCommodity sourcePosting == "JPY"
          _ -> False
  where
    showCommodity = maybe "" commodityCode . intentCommodity

testConflictingDefaults :: Bool
testConflictingDefaults =
  case parseJournal conflictingDefaultSource of
    Left _ -> False
    Right journal ->
      buildActualAddIntentWithRegistry
        (journalAccountRegistry journal)
        (validInput { addAmountText = "100" })
        == Left ActualAddConflictingDefaultCommodity

testMissingDefaults :: Bool
testMissingDefaults =
  case parseJournal missingDefaultSource of
    Left _ -> False
    Right journal ->
      buildActualAddIntentWithRegistry
        (journalAccountRegistry journal)
        (validInput { addAmountText = "100" })
        == Left ActualAddMissingDefaultCommodity

conflictingDefaultSource :: T.Text
conflictingDefaultSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: USD"
  ]

missingDefaultSource :: T.Text
missingDefaultSource = T.unlines
  [ "account assets:cash"
  , "  type: Asset"
  , "account expenses:food"
  , "  type: Expense"
  ]

testInitialDay :: Bool
testInitialDay =
  let today = read "2026-08-08"
      state = initialActualAddStateForDay today
  in addDateText (actualAddInput state) == "2026-08-08"
      && actualAddMode state == EditingActualAdd

testYesterday :: Bool
testYesterday =
  let today = read "2026-08-08"
      yesterday = read "2026-08-07"
      initial = initialActualAddStateForDay today
      changed = setActualAddDate yesterday initial
  in addDateText (actualAddInput changed) == "2026-08-07"
      && actualAddMode changed == EditingActualAdd

testExpenseCandidates :: Bool
testExpenseCandidates =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      map accountName
        (dailyAccountCandidates
          (journalAccountRegistry journal)
          (journalTransactions journal)
          SelectToAccount)
        == ["expenses:books", "expenses:food"]

testPaymentCandidates :: Bool
testPaymentCandidates =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      map accountName
        (dailyAccountCandidates
          (journalAccountRegistry journal)
          (journalTransactions journal)
          SelectFromAccount)
        == ["liabilities:card", "assets:cash", "assets:bank"]

testCandidateSearch :: Bool
testCandidateSearch =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      let candidates =
            dailyAccountCandidates
              (journalAccountRegistry journal)
              (journalTransactions journal)
              SelectToAccount
      in map accountName (filterDailyAccountCandidates "BOOK" candidates)
          == ["expenses:books"]

testEmptyCandidateSearch :: Bool
testEmptyCandidateSearch =
  case parseJournal candidateSource of
    Left _ -> False
    Right journal ->
      let candidates =
            dailyAccountCandidates
              (journalAccountRegistry journal)
              (journalTransactions journal)
              SelectFromAccount
      in filterDailyAccountCandidates "  " candidates == candidates

candidateSource :: T.Text
candidateSource = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account liabilities:card"
  , "  type: Liability"
  , "  commodity: JPY"
  , "account expenses:books"
  , "  type: Expense"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , "account income:pension"
  , "  type: Income"
  , "  commodity: JPY"
  , ""
  , "2026-08-06 groceries"
  , "  expenses:food  100 JPY"
  , "  assets:cash  -100 JPY"
  , ""
  , "2026-08-07 books"
  , "  expenses:books  200 JPY"
  , "  liabilities:card  -200 JPY"
  ]

testFromSelection :: Bool
testFromSelection = case mkAccount "assets:cash" of
  Left _ -> False
  Right account ->
    let selecting = transitionActualAdd
          (BeginAccountSelection SelectFromAccount)
          initialActualAddState
        selected = transitionActualAdd (ChooseAccount account) selecting
    in addFromAccountText (actualAddInput selected) == "assets:cash"
        && actualAddMode selected == EditingActualAdd

testCancelSelection :: Bool
testCancelSelection =
  let initial = ActualAddState validInput EditingActualAdd
      selecting = transitionActualAdd
        (BeginAccountSelection SelectToAccount)
        initial
      cancelled = transitionActualAdd CancelAccountSelection selecting
  in actualAddInput cancelled == validInput
      && actualAddMode cancelled == EditingActualAdd

testPreviewTransition :: T.Text -> Bool
testPreviewTransition source =
  let previewState = readyPreviewState source
      stateRendering = T.pack (show previewState)
  in case actualAddMode previewState of
      ShowingActualAddPreview (ActualAddCandidateReady block) ->
        block == expectedBlock
          && not ("Opening Balance" `T.isInfixOf` stateRendering)
      _ -> False

testRejectedPreviewCannotConfirm :: T.Text -> Bool
testRejectedPreviewCannotConfirm source =
  let input = validInput { addAmountText = "0 JPY" }
      initial = ActualAddState input EditingActualAdd
      rejected = enterActualAddPreview (prepareActualAddPreview source input) initial
      confirmation = transitionActualAdd RequestActualAddConfirmation rejected
  in confirmation == rejected

testReadyPreviewEntersConfirmation :: T.Text -> Bool
testReadyPreviewEntersConfirmation source =
  let confirmation =
        transitionActualAdd
          RequestActualAddConfirmation
          (readyPreviewState source)
  in actualAddMode confirmation == ConfirmingActualAdd expectedBlock

testConfirmationCancellation :: T.Text -> Bool
testConfirmationCancellation source =
  let confirmation =
        transitionActualAdd
          RequestActualAddConfirmation
          (readyPreviewState source)
      cancelled =
        transitionActualAdd CancelActualAddConfirmation confirmation
  in actualAddMode cancelled
      == ShowingActualAddPreview (ActualAddCandidateReady expectedBlock)

testConfirmationAccepted :: T.Text -> Bool
testConfirmationAccepted source =
  let confirmation =
        transitionActualAdd
          RequestActualAddConfirmation
          (readyPreviewState source)
      accepted = transitionActualAdd ConfirmActualAdd confirmation
      stateRendering = T.pack (show accepted)
  in actualAddMode accepted == ActualAddConfirmed expectedBlock
      && not ("Opening Balance" `T.isInfixOf` stateRendering)

readyPreviewState :: T.Text -> ActualAddState
readyPreviewState source =
  enterActualAddPreview
    (prepareActualAddPreview source validInput)
    (ActualAddState validInput EditingActualAdd)

testWriteSuccess :: Bool
testWriteSuccess =
  classifyActualAddWriteResult
    (Right () :: Either (WriteError ()) ())
    == ActualAddWriteSucceeded

testWriteStale :: Bool
testWriteStale =
  classifyActualAddWriteResult
    (Left StaleFile :: Either (WriteError ()) ())
    == ActualAddWriteStale

testWriteRecovered :: Bool
testWriteRecovered =
  classifyActualAddWriteResult
    (Left
      (PostAdmissionFailed
        { failedSourceError = "synthetic" NonEmpty.:| []
        , restoredFromBackup = True
        }) :: Either (WriteError String) ())
    == ActualAddWriteRecovered ActualAddPostAdmissionFailure

testWriteRecoveryFailure :: Bool
testWriteRecoveryFailure =
  classifyActualAddWriteResult
    (Left
      (PostPublishReadFailed
        { failedReadMessage = "synthetic"
        , restoredFromBackup = False
        }) :: Either (WriteError ()) ())
    == ActualAddWriteFailed ActualAddPostPublishReadFailure

testWriteFileIOFailure :: Bool
testWriteFileIOFailure =
  classifyActualAddWriteResult
    (Left (FileIOError "synthetic") :: Either (WriteError ()) ())
    == ActualAddWriteFileIOFailed