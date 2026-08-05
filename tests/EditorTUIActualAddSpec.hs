{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (accountName)
import HKernel.Editor.ActualAppend
  ( ActualEditIntent(..)
  , IntentPosting(..)
  )
import HKernel.Editor.TUI.ActualAdd
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
  buildActualAddIntent validInput { addAmountText = "-100 JPY" }
    == Left ActualAddAmountMustBePositive

testZeroMagnitude :: Bool
testZeroMagnitude =
  buildActualAddIntent validInput { addAmountText = "0 JPY" }
    == Left ActualAddAmountMustBePositive

testAmountShape :: Bool
testAmountShape =
  buildActualAddIntent validInput { addAmountText = "100" }
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
  let initial = ActualAddState validInput EditingActualAdd
      previewState =
        transitionActualAdd source RequestActualAddPreview initial
      stateRendering = T.pack (show previewState)
  in case actualAddMode previewState of
      ShowingActualAddPreview (ActualAddCandidateReady block) ->
        block ==
          "2026-08-05 Groceries\n\
          \  expenses:food  100 JPY\n\
          \  assets:cash  -100 JPY\n"
          && not ("Opening Balance" `T.isInfixOf` stateRendering)
      _ -> False
