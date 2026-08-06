{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.IORef
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

import HKernel.Actual.Journal (parseActualJournal)
import HKernel.Editor.ActualWriter (publishActualBlock)
import HKernel.Editor.TUI.ActualAdd
  ( ActualAddAction(..)
  , ActualAddInput(..)
  , ActualAddMode(..)
  , ActualAddPreview(..)
  , ActualAddState(..)
  , transitionActualAdd
  )
import HKernel.Editor.TUI.ActualSourceSnapshot
  ( ActualSourceLoadFailure(..)
  , ActualSourceReader(..)
  , actualSnapshotAccountNames
  , actualSnapshotJournal
  , actualSnapshotSource
  , actualSourceStartupFailureText
  , admitActualSourceSnapshot
  , loadActualSourceSnapshotUsing
  )

main :: IO ()
main = do
  testSnapshotAdmission
  testInvalidAdmission
  testSanitizedFailures
  testSanitizedStartupFailures
  testRefreshLifecycle
  testConsecutiveActualAddEvidence
  testStableOperationSnapshot
  putStrLn "EditorTUIActualSourceSnapshotSpec: ALL PASSED"

testSnapshotAdmission :: IO ()
testSnapshotAdmission = do
  let validSource = T.unlines
        [ "account assets:cash"
        , "    type: asset"
        , "    commodity: JPY"
        , ""
        , "account expenses:food"
        , "    type: expense"
        , "    commodity: JPY"
        , ""
        , "2026-08-06 Grocery"
        , "  expenses:food  100 JPY"
        , "  assets:cash"
        ]
  case admitActualSourceSnapshot validSource of
    Left err -> assertFailure ("Expected admission success, got: " <> show err)
    Right snapshot -> do
      assertEqual "source text exact match" validSource (actualSnapshotSource snapshot)
      assertEqual "account names exact match" ["assets:cash", "expenses:food"] (actualSnapshotAccountNames snapshot)
      case parseActualJournal validSource of
        Left _ -> assertFailure "Parse journal failed unexpectedly"
        Right expectedJournal ->
          assertEqual "journal parsed from same source" (show expectedJournal) (show (actualSnapshotJournal snapshot))

testInvalidAdmission :: IO ()
testInvalidAdmission = do
  let invalidSource = "invalid journal content !!!"
  case admitActualSourceSnapshot invalidSource of
    Left ActualSourceAdmissionFailed -> pure ()
    Left err -> assertFailure ("Expected ActualSourceAdmissionFailed, got: Left " <> show err)
    Right _ -> assertFailure "Expected ActualSourceAdmissionFailed, got: Right snapshot"

testSanitizedFailures :: IO ()
testSanitizedFailures = do
  assertEqual "read failure show" "ActualSourceFileReadFailed" (show ActualSourceFileReadFailed)
  assertEqual "admission failure show" "ActualSourceAdmissionFailed" (show ActualSourceAdmissionFailed)

testSanitizedStartupFailures :: IO ()
testSanitizedStartupFailures = do
  let readMsg = actualSourceStartupFailureText ActualSourceFileReadFailed
      admissionMsg = actualSourceStartupFailureText ActualSourceAdmissionFailed
  assertEqual "read failure startup text" "Failed to read the Actual Journal." readMsg
  assertEqual "admission failure startup text" "The Actual Journal failed admission." admissionMsg
  assertBool "read failure message contains no path" (not ("/" `T.isInfixOf` readMsg))
  assertBool "admission failure message contains no path" (not ("/" `T.isInfixOf` admissionMsg))

testRefreshLifecycle :: IO ()
testRefreshLifecycle = do
  readCountRef <- newIORef (0 :: Int)
  let source1 = T.unlines
        [ "account assets:bank"
        , "    type: asset"
        , "    commodity: JPY"
        , ""
        , "account expenses:rent"
        , "    type: expense"
        , "    commodity: JPY"
        , ""
        , "2026-08-01 Rent"
        , "  expenses:rent  500 JPY"
        , "  assets:bank"
        ]
      source2 = T.unlines
        [ "account assets:bank"
        , "    type: asset"
        , "    commodity: JPY"
        , ""
        , "account expenses:rent"
        , "    type: expense"
        , "    commodity: JPY"
        , ""
        , "account expenses:books"
        , "    type: expense"
        , "    commodity: JPY"
        , ""
        , "2026-08-01 Rent"
        , "  expenses:rent  500 JPY"
        , "  assets:bank"
        , ""
        , "2026-08-02 Book"
        , "  expenses:books  30 JPY"
        , "  assets:bank"
        ]
  let mockReader = ActualSourceReader $ \_path -> do
        count <- readIORef readCountRef
        writeIORef readCountRef (count + 1)
        pure $ if count == 0 then source1 else source2

  -- First load
  res1 <- loadActualSourceSnapshotUsing mockReader "dummy.journal"
  case res1 of
    Left err -> assertFailure ("First load failed: " <> show err)
    Right snap1 -> do
      count1 <- readIORef readCountRef
      assertEqual "read count after 1st load" 1 count1
      assertEqual "1st snapshot source" source1 (actualSnapshotSource snap1)
      assertEqual "1st accounts" ["assets:bank", "expenses:rent"] (actualSnapshotAccountNames snap1)

      -- Second load
      res2 <- loadActualSourceSnapshotUsing mockReader "dummy.journal"
      case res2 of
        Left err -> assertFailure ("Second load failed: " <> show err)
        Right snap2 -> do
          count2 <- readIORef readCountRef
          assertEqual "read count after 2nd load" 2 count2
          assertEqual "2nd snapshot source" source2 (actualSnapshotSource snap2)
          assertEqual "2nd accounts updated" ["assets:bank", "expenses:books", "expenses:rent"] (actualSnapshotAccountNames snap2)
          assertBool "snapshot 1 and 2 differ" (actualSnapshotSource snap1 /= actualSnapshotSource snap2)

testConsecutiveActualAddEvidence :: IO ()
testConsecutiveActualAddEvidence = withSystemTempDirectory "consecutive-add-test" $ \tmpDir -> do
  let path = tmpDir </> "actual.journal"
      initialSource = T.unlines
        [ "account assets:cash"
        , "    type: asset"
        , "    commodity: JPY"
        , ""
        , "account expenses:food"
        , "    type: expense"
        , "    commodity: JPY"
        , ""
        , "2026-08-01 Lunch"
        , "  expenses:food  10 JPY"
        , "  assets:cash"
        ]
  TIO.writeFile path initialSource

  -- 1st operation entry: fresh load snapshot A
  Right snapA <- loadActualSourceSnapshotUsing (ActualSourceReader TIO.readFile) path

  let input1 = ActualAddInput
        { addDateText = "2026-08-02"
        , addDescriptionText = "Dinner"
        , addFromAccountText = "assets:cash"
        , addToAccountText = "expenses:food"
        , addAmountText = "15 JPY"
        }
      state1 = transitionActualAdd (actualSnapshotSource snapA) RequestActualAddPreview (ActualAddState input1 EditingActualAdd)
  block1 <- case actualAddMode state1 of
    ShowingActualAddPreview (ActualAddCandidateReady b) -> pure b
    other -> error ("Candidate 1 rejected: " <> show other)

  -- Publish 1st block to disk
  pubRes1 <- publishActualBlock path (actualSnapshotSource snapA) block1
  assertEqual "1st publish succeeded" "Right ()" (show pubRes1)

  -- 2nd operation entry: fresh load snapshot B from disk
  Right snapB <- loadActualSourceSnapshotUsing (ActualSourceReader TIO.readFile) path

  let input2 = ActualAddInput
        { addDateText = "2026-08-03"
        , addDescriptionText = "Coffee"
        , addFromAccountText = "assets:cash"
        , addToAccountText = "expenses:food"
        , addAmountText = "5 JPY"
        }

  -- Prepare 2nd candidate using snapshot B source (expectedOldSource is snapB source)
  let state2 = transitionActualAdd (actualSnapshotSource snapB) RequestActualAddPreview (ActualAddState input2 EditingActualAdd)
  block2 <- case actualAddMode state2 of
    ShowingActualAddPreview (ActualAddCandidateReady b) -> pure b
    other -> error ("Candidate 2 rejected: " <> show other)

  -- Publish 2nd block to disk using snapshot B as expectedOldSource
  pubRes2 <- publishActualBlock path (actualSnapshotSource snapB) block2
  assertEqual "2nd publish succeeded" "Right ()" (show pubRes2)

  -- Read final file from disk
  finalContent <- TIO.readFile path

  assertBool "final file contains 1st transaction (Dinner)" ("Dinner" `T.isInfixOf` finalContent)
  assertBool "final file contains 2nd transaction (Coffee)" ("Coffee" `T.isInfixOf` finalContent)
  assertBool "final file did not revert to initial source" (finalContent /= initialSource)

testStableOperationSnapshot :: IO ()
testStableOperationSnapshot = withSystemTempDirectory "tui-snapshot-test" $ \tmpDir -> do
  let path = tmpDir </> "actual.journal"
      initialSource = T.unlines
        [ "account assets:cash"
        , "    type: asset"
        , "    commodity: JPY"
        , ""
        , "account expenses:food"
        , "    type: expense"
        , "    commodity: JPY"
        , ""
        , "2026-08-01 Lunch"
        , "  expenses:food  10 JPY"
        , "  assets:cash"
        ]
  TIO.writeFile path initialSource

  -- Load operation snapshot at operation start
  Right snap <- loadActualSourceSnapshotUsing (ActualSourceReader TIO.readFile) path

  let input = ActualAddInput
        { addDateText = "2026-08-02"
        , addDescriptionText = "Snack"
        , addFromAccountText = "assets:cash"
        , addToAccountText = "expenses:food"
        , addAmountText = "3 JPY"
        }
      state = transitionActualAdd (actualSnapshotSource snap) RequestActualAddPreview (ActualAddState input EditingActualAdd)
  block <- case actualAddMode state of
    ShowingActualAddPreview (ActualAddCandidateReady b) -> pure b
    other -> error ("Preview failed: " <> show other)

  -- Now external modification occurs on disk before publication
  let externalSource = initialSource <> "\n2026-08-01 External Change\n  expenses:food  50 JPY\n  assets:cash\n"
  TIO.writeFile path externalSource

  -- Publication using snapshot's expectedOldSource should be rejected as stale
  pubResult <- publishActualBlock path (actualSnapshotSource snap) block
  assertEqual "publication rejected as stale due to external edit" "Left StaleFile" (show pubResult)

  -- Verify on-disk file was not corrupted
  currentOnDisk <- TIO.readFile path
  assertEqual "on-disk content preserved" externalSource currentOnDisk

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
  if expected == actual
    then pure ()
    else assertFailure (label <> ": expected " <> show expected <> ", got " <> show actual)

assertBool :: String -> Bool -> IO ()
assertBool label condition =
  if condition
    then pure ()
    else assertFailure (label <> ": condition was false")

assertFailure :: String -> IO a
assertFailure msg = do
  putStrLn ("FAILURE: " <> msg)
  exitFailure
