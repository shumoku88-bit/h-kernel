{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Text as T
import System.Exit (exitFailure, exitSuccess)

import HKernel.Editor.TUI.OperationHub

main :: IO ()
main = do
  let results =
        [ ("operation order is deterministic", testDeterministicOrder)
        , ("initial selection is Actual add", testInitialSelection)
        , ("navigation moves selection", testNavigation)
        , ("navigation respects boundaries", testNavigationBoundaries)
        , ("Actual add and Actual browse are enabled", testEnabledOperations)
        , ("disabled operations have explicit typed reasons", testDisabledOperations)
        , ("hub state contains no private source or path", testNoPrivateDataInHubState)
        ]
  mapM_ print results
  if all snd results then exitSuccess else exitFailure

testDeterministicOrder :: Bool
testDeterministicOrder =
  allDailyOperations ==
    [ OperationActualAdd
    , OperationActualBrowse
    , OperationActualMultiPosting
    , OperationActualReverse
    , OperationReports
    , OperationAccountDeclaration
    , OperationPlan
    , OperationBudgetMovement
    , OperationIssue
    ]

testInitialSelection :: Bool
testInitialSelection =
  hubSelectedIndex initialOperationHubState == 0
    && selectedOperation initialOperationHubState == OperationActualAdd

testNavigation :: Bool
testNavigation =
  let state0 = initialOperationHubState
      state1 = transitionOperationHub HubMoveDown state0
      state2 = transitionOperationHub HubMoveDown state1
      back1  = transitionOperationHub HubMoveUp state2
  in selectedOperation state1 == OperationActualBrowse
      && selectedOperation state2 == OperationActualMultiPosting
      && selectedOperation back1 == OperationActualBrowse

testNavigationBoundaries :: Bool
testNavigationBoundaries =
  let atTop = transitionOperationHub HubMoveUp initialOperationHubState
      maxMove = foldr ($) initialOperationHubState (replicate 20 (transitionOperationHub HubMoveDown))
      atBottomPlus = transitionOperationHub HubMoveDown maxMove
  in atTop == initialOperationHubState
      && selectedOperation maxMove == OperationIssue
      && atBottomPlus == maxMove

testEnabledOperations :: Bool
testEnabledOperations =
  operationAvailability OperationActualAdd == OperationEnabled
    && operationAvailability OperationActualBrowse == OperationEnabled

testDisabledOperations :: Bool
testDisabledOperations =
  operationAvailability OperationActualMultiPosting == OperationDisabled OperationNotConnected
    && operationAvailability OperationActualReverse == OperationDisabled OperationNotConnected
    && operationAvailability OperationReports == OperationDisabled OperationNotConnected
    && operationAvailability OperationAccountDeclaration == OperationDisabled OperationNotConnected
    && operationAvailability OperationPlan == OperationDisabled OperationAuthorityUnresolved
    && operationAvailability OperationBudgetMovement == OperationDisabled OperationAuthorityUnchanged
    && operationAvailability OperationIssue == OperationDisabled OperationAuthorityUnchanged

testNoPrivateDataInHubState :: Bool
testNoPrivateDataInHubState =
  let state = initialOperationHubState
      rendered = show state
  in not ("journal" `T.isInfixOf` T.pack rendered)
      && not ("/" `T.isInfixOf` T.pack rendered)
