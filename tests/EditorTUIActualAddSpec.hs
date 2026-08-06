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
import HKernel.Plan.Completion (ActualTransactionId, mkActualTransactionId)

main :: IO ()
main = do
  source <- TIO.readFile "tests/fixtures/editor/actual-add.journal"
  let results =
        [ ("positive magnitude builds balanced typed intent with event-id", testPositiveMagnitude)
        , ("negative magnitude is rejected", testNegativeMagnitude)
        , ("zero magnitude is rejected", testZeroMagnitude)
        , ("amount shape is explicit", testAmountShape)
        , ("from Account selection updates input and preserves identity", testFromSelection source)
        , ("cancelled selection preserves input and identity", testCancelSelection source)
        , ("preview transition retains candidate block only and includes event-id", testPreviewTransition source)
        , ("rejected preview cannot enter confirmation", testRejectedPreviewCannotConfirm source)
        , ("ready preview enters confirmation", testReadyPreviewEntersConfirmation source)
        , ("confirmation cancellation returns to ready preview with same identity", testConfirmationCancellation source)
        , ("accepted confirmation remains source-free until delivery", testConfirmationAccepted source)
        , ("identity remains stable across input edit and re-preview", testIdentityStabilityOnRePreview source)
        , ("successful write result is observable", testWriteSuccess)
        , ("stale write result is observable", testWriteStale)
        , ("restored admission failure is recoverable", testWriteRecovered)
        , ("failed restoration requires verification", testWriteRecoveryFailure)
        , ("filesystem failure is observable", testWriteFileIOFailure)
        ]
  mapM_ print results
  if all snd results then exitSuccess else exitFailure

syntheticId :: ActualTransactionId
syntheticId = case mkActualTransactionId "evt-synthetic-ordinary-001" of
  Right actualId -> actualId
  Left _ -> error "Invalid synthetic ID"

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
  , "    ; event-id: evt-synthetic-ordinary-001"
  , "  expenses:food  100 JPY"
  , "  assets:cash  -100 JPY"
  ]

testPositiveMagnitude :: Bool
testPositiveMagnitude = case buildActualAddIntent syntheticId validInput of
  Right intent -> case NonEmpty.toList (intentPostings intent) of
    [destination, source] ->
      accountName (intentAccount destination) == "expenses:food"
        && renderQuantity (intentQuantity destination) == "100"
        && accountName (intentAccount source) == "assets:cash"
        && renderQuantity (intentQuantity source) == "-100"
        && intentMetadata intent == [("event-id", "evt-synthetic-ordinary-001")]
    _ -> False
  Left _ -> False

testNegativeMagnitude :: Bool
testNegativeMagnitude =
  buildActualAddIntent syntheticId (validInput { addAmountText = "-100 JPY" })
    == Left ActualAddAmountMustBePositive

testZeroMagnitude :: Bool
testZeroMagnitude =
  buildActualAddIntent syntheticId (validInput { addAmountText = "0 JPY" })
    == Left ActualAddAmountMustBePositive

testAmountShape :: Bool
testAmountShape =
  buildActualAddIntent syntheticId (validInput { addAmountText = "100" })
    == Left ActualAddInvalidAmountShape

testFromSelection :: T.Text -> Bool
testFromSelection source =
  let selecting = transitionActualAdd
        source
        (BeginAccountSelection SelectFromAccount)
        (initialActualAddState syntheticId)
      selected = transitionActualAdd source (ChooseAccount "assets:cash") selecting
  in addFromAccountText (actualAddInput selected) == "assets:cash"
      && actualAddMode selected == EditingActualAdd
      && actualAddIdentity selected == syntheticId

testCancelSelection :: T.Text -> Bool
testCancelSelection source =
  let initial = ActualAddState syntheticId validInput EditingActualAdd
      selecting = transitionActualAdd
        source
        (BeginAccountSelection SelectToAccount)
        initial
      cancelled = transitionActualAdd source CancelAccountSelection selecting
  in actualAddInput cancelled == validInput
      && actualAddMode cancelled == EditingActualAdd
      && actualAddIdentity cancelled == syntheticId

testPreviewTransition :: T.Text -> Bool
testPreviewTransition source =
  let previewState = readyPreviewState source
      stateRendering = T.pack (show previewState)
  in case actualAddMode previewState of
      ShowingActualAddPreview (ActualAddCandidateReady block) ->
        block == expectedBlock
          && not ("Opening Balance" `T.isInfixOf` stateRendering)
          && actualAddIdentity previewState == syntheticId
      _ -> False

testRejectedPreviewCannotConfirm :: T.Text -> Bool
testRejectedPreviewCannotConfirm source =
  let initial = ActualAddState
        syntheticId
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
      && actualAddIdentity confirmation == syntheticId

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
      && actualAddIdentity cancelled == syntheticId

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
      && actualAddIdentity accepted == syntheticId

testIdentityStabilityOnRePreview :: T.Text -> Bool
testIdentityStabilityOnRePreview source =
  let s1 = readyPreviewState source
      s2 = transitionActualAdd source ReturnToActualAddInput s1
      s3 = s2 { actualAddInput = (actualAddInput s2) { addDescriptionText = "Updated Groceries" } }
      s4 = transitionActualAdd source RequestActualAddPreview s3
  in case actualAddMode s4 of
    ShowingActualAddPreview (ActualAddCandidateReady block) ->
      "evt-synthetic-ordinary-001" `T.isInfixOf` block
        && "Updated Groceries" `T.isInfixOf` block
        && actualAddIdentity s4 == syntheticId
    _ -> False

readyPreviewState :: T.Text -> ActualAddState
readyPreviewState source =
  transitionActualAdd
    source
    RequestActualAddPreview
    (ActualAddState syntheticId validInput EditingActualAdd)

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
