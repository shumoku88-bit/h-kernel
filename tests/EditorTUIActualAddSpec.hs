{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (accountName)
import HKernel.Editor.ActualAppend (ActualEditIntent(..))
import HKernel.Editor.ActualWriter (WriteError(..))
import HKernel.Editor.TUI.ActualAdd
import HKernel.Editor.TransactionBlock (IntentPosting(..))
import HKernel.Money (renderQuantity)

main :: IO ()
main = do
  source <- TIO.readFile "tests/fixtures/editor/actual-add.journal"
  let results =
        [ ("positive magnitude builds balanced typed intent", testPositiveMagnitude)
        , ("negative magnitude is rejected", testNegativeMagnitude)
        , ("zero magnitude is rejected", testZeroMagnitude)
        , ("amount shape is explicit", testAmountShape)
        , ("from Account selection updates input", testFromSelection source)
        , ("cancelled selection preserves input", testCancelSelection source)
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

testFromSelection :: T.Text -> Bool
testFromSelection source =
  let selecting = transitionActualAdd
        source
        (BeginAccountSelection SelectFromAccount)
        initialActualAddState
      selected = transitionActualAdd source (ChooseAccount "assets:cash") selecting
  in addFromAccountText (actualAddInput selected) == "assets:cash"
      && actualAddMode selected == EditingActualAdd

testCancelSelection :: T.Text -> Bool
testCancelSelection source =
  let initial = ActualAddState validInput EditingActualAdd
      selecting = transitionActualAdd
        source
        (BeginAccountSelection SelectToAccount)
        initial
      cancelled = transitionActualAdd source CancelAccountSelection selecting
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
  let initial = ActualAddState
        (validInput { addAmountText = "0 JPY" })
        EditingActualAdd
      rejected = transitionActualAdd source RequestActualAddPreview initial
      confirmation =
        transitionActualAdd source RequestActualAddConfirmation rejected
  in confirmation == rejected

testReadyPreviewEntersConfirmation :: T.Text -> Bool
testReadyPreviewEntersConfirmation source =
  let confirmation =
        transitionActualAdd
          source
          RequestActualAddConfirmation
          (readyPreviewState source)
  in actualAddMode confirmation == ConfirmingActualAdd expectedBlock

testConfirmationCancellation :: T.Text -> Bool
testConfirmationCancellation source =
  let confirmation =
        transitionActualAdd
          source
          RequestActualAddConfirmation
          (readyPreviewState source)
      cancelled =
        transitionActualAdd source CancelActualAddConfirmation confirmation
  in actualAddMode cancelled
      == ShowingActualAddPreview (ActualAddCandidateReady expectedBlock)

testConfirmationAccepted :: T.Text -> Bool
testConfirmationAccepted source =
  let confirmation =
        transitionActualAdd
          source
          RequestActualAddConfirmation
          (readyPreviewState source)
      accepted = transitionActualAdd source ConfirmActualAdd confirmation
      stateRendering = T.pack (show accepted)
  in actualAddMode accepted == ActualAddConfirmed expectedBlock
      && not ("Opening Balance" `T.isInfixOf` stateRendering)

readyPreviewState :: T.Text -> ActualAddState
readyPreviewState source =
  transitionActualAdd
    source
    RequestActualAddPreview
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
    == ActualAddWriteFailed (ActualAddFileIOFailure "synthetic")
