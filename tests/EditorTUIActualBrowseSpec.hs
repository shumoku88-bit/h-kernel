{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure, exitSuccess)

import HKernel.Actual.Journal
  ( ActualJournal
  , parseActualJournal
  )
import HKernel.Editor.TUI.ActualBrowse
  ( ActualBrowseAction(..)
  , ActualBrowseRow(..)
  , ActualBrowseState(..)
  , ActualIdentityStatus(..)
  , buildActualBrowseRows
  , initialActualBrowseState
  , initialActualBrowseStateFromSnapshot
  , selectedBrowseRow
  , transitionActualBrowse
  )
import HKernel.Editor.TUI.ActualSourceSnapshot (admitActualSourceSnapshot)
import HKernel.Plan (planIdText)
import HKernel.Plan.Completion (actualTransactionIdText)

main :: IO ()
main = do
  source <- TIO.readFile "tests/fixtures/editor/actual-browse.journal"
  journal <- case parseActualJournal source of
    Left errs -> error ("Failed to parse fixture: " ++ show errs)
    Right j -> pure j

  let rows = buildActualBrowseRows journal
      results =
        [ ("admitted count matches record count", length rows == 7)
        , ("source order is preserved", testSourceOrder rows)
        , ("ordinary transaction retains no identity", testOrdinaryNoIdentity rows)
        , ("explicit event-id is explicit durable identity", testExplicitEventId rows)
        , ("plan completion derived identity is plan-derived runtime identity", testPlanDerivedIdentity rows)
        , ("both event-id and plan-id yields explicit event identity", testBothEventAndPlanId rows)
        , ("reversal relation is aligned and distinct from identity origin", testReversalRelation rows)
        , ("identical contents remain separate records", testIdenticalContentsSeparate rows)
        , ("pure browser initial selection and navigation", testNavigation journal)
        , ("initial state from admitted snapshot matches row count", testInitialStateFromSnapshot source)
        , ("state contains no complete source or path", testNoPrivateDataInState journal)
        ]

  mapM_ print results
  if all snd results then exitSuccess else exitFailure

testSourceOrder :: [ActualBrowseRow] -> Bool
testSourceOrder rows =
  length rows == 7
    && rowIdentityStatus (head rows) == ActualHasNoIdentity

testOrdinaryNoIdentity :: [ActualBrowseRow] -> Bool
testOrdinaryNoIdentity rows =
  rowIdentityStatus (rows !! 0) == ActualHasNoIdentity
    && rowReverses (rows !! 0) == Nothing

testExplicitEventId :: [ActualBrowseRow] -> Bool
testExplicitEventId rows = case rowIdentityStatus (rows !! 1) of
  ActualHasExplicitDurableIdentity actualId ->
    actualTransactionIdText actualId == "evt-20260802-rent"
  _ -> False

testPlanDerivedIdentity :: [ActualBrowseRow] -> Bool
testPlanDerivedIdentity rows = case rowIdentityStatus (rows !! 4) of
  ActualHasPlanDerivedRuntimeIdentity planId actualId ->
    planIdText planId == "plan-lunch-001"
      && actualTransactionIdText actualId == "plan-completion-plan-lunch-001"
  _ -> False

testBothEventAndPlanId :: [ActualBrowseRow] -> Bool
testBothEventAndPlanId rows = case rowIdentityStatus (rows !! 6) of
  ActualHasExplicitDurableIdentity actualId ->
    actualTransactionIdText actualId == "evt-20260806-dinner"
  _ -> False

testReversalRelation :: [ActualBrowseRow] -> Bool
testReversalRelation rows =
  let revRow = rows !! 5
  in case (rowIdentityStatus revRow, rowReverses revRow) of
    (ActualHasExplicitDurableIdentity revId, Just targetId) ->
      actualTransactionIdText revId == "evt-20260805-reversal"
        && actualTransactionIdText targetId == "evt-20260802-rent"
    _ -> False

testIdenticalContentsSeparate :: [ActualBrowseRow] -> Bool
testIdenticalContentsSeparate rows =
  let row3 = rows !! 2
      row4 = rows !! 3
  in rowTransaction row3 == rowTransaction row4
      && rowIdentityStatus row3 == ActualHasNoIdentity
      && rowIdentityStatus row4 == ActualHasNoIdentity

testNavigation :: ActualJournal -> Bool
testNavigation journal =
  let state0 = initialActualBrowseState journal
      state1 = transitionActualBrowse BrowseMoveDown state0
      state2 = transitionActualBrowse BrowseMoveDown state1
      back1  = transitionActualBrowse BrowseMoveUp state2
      atTop  = transitionActualBrowse BrowseMoveUp state0
      maxMove = foldr ($) state0 (replicate 20 (transitionActualBrowse BrowseMoveDown))
  in browseSelectedIndex state0 == 0
      && fmap rowIdentityStatus (selectedBrowseRow state0) == Just ActualHasNoIdentity
      && browseSelectedIndex state1 == 1
      && browseSelectedIndex state2 == 2
      && browseSelectedIndex back1 == 1
      && browseSelectedIndex atTop == 0
      && browseSelectedIndex maxMove == 6

testInitialStateFromSnapshot :: T.Text -> Bool
testInitialStateFromSnapshot source =
  case admitActualSourceSnapshot source of
    Right snapshot ->
      let state = initialActualBrowseStateFromSnapshot snapshot
      in length (browseRows state) == 7
    Left _ -> False

testNoPrivateDataInState :: ActualJournal -> Bool
testNoPrivateDataInState journal =
  let state = initialActualBrowseState journal
      rendered = show state
  in not ("journal" `T.isInfixOf` T.pack rendered)
      && not ("/" `T.isInfixOf` T.pack rendered)
