{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (IOException, catch)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day, fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Editor.SourcePublication
  ( CandidateSource(..)
  , ExpectedSource(..)
  , WriteIntent(..)
  , WriterFileSystem(..)
  , defaultWriterFileSystem
  , publishWithAdmission
  )
import HKernel.Editor.IssueAppend
  ( IssueAppendError(..)
  , IssueAppendIntent(..)
  , IssueAppendPreview(..)
  , IssueCloseDisposition(..)
  , IssueCloseError(..)
  , IssueCloseIntent(..)
  , IssueClosePreview(..)
  , IssueDueUpdateError(..)
  , IssueDueUpdateIntent(..)
  , IssueDueUpdatePreview(..)
  , generateAvailableIssueId
  , prepareIssueAppend
  , prepareIssueAppendWithDue
  , prepareIssueClose
  , prepareIssueCloseOn
  , prepareIssueDueUpdate
  )
import HKernel.Household.Issue.TSV
  ( dueAwareHouseholdIssuesHeader
  , householdIssuesHeader
  , legacyHouseholdIssuesHeader
  , parseHouseholdIssues
  )
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueClosed(..)
  , IssueDue(..)
  , IssueId
  , IssueStatus(..)
  , householdIssueAmount
  , householdIssueClosed
  , householdIssueDetails
  , householdIssueDue
  , householdIssueId
  , householdIssueRecordedOn
  , householdIssueStatus
  , mkIssueId
  )
import HKernel.Money
  ( Commodity
  , mkAmount
  , mkCommodity
  , quantityFromInteger
  )

main :: IO ()
main = do
  let tests =
        [ ("testGeneratedIssueIdStartsAtOne", pure testGeneratedIssueIdStartsAtOne)
        , ("testGeneratedIssueIdSkipsExisting", pure testGeneratedIssueIdSkipsExisting)
        , ("testCurrentAppendWritesNotClosed", pure testCurrentAppendWritesNotClosed)
        , ("testExplicitKnownDueAppend", pure testExplicitKnownDueAppend)
        , ("testOptionalAmountAppend", pure testOptionalAmountAppend)
        , ("testEmptySourceAddsCurrentHeader", pure testEmptySourceAddsCurrentHeader)
        , ("testDueAwareAppendPreservesShape", pure testDueAwareAppendPreservesShape)
        , ("testLegacyAppendPreservesShape", pure testLegacyAppendPreservesShape)
        , ("testLegacyExplicitDueRejected", pure testLegacyExplicitDueRejected)
        , ("testDueUpdateChangesOnlyDue", pure testDueUpdateChangesOnlyDue)
        , ("testDueUpdateRejectsClosedIssue", pure testDueUpdateRejectsClosedIssue)
        , ("testCloseRequiresDateForCurrentSource", pure testCloseRequiresDateForCurrentSource)
        , ("testResolveIssueRecordsClosedDate", pure testResolveIssueRecordsClosedDate)
        , ("testDropIssueRecordsClosedDate", pure testDropIssueRecordsClosedDate)
        , ("testCloseRejectsDateBeforeRecorded", pure testCloseRejectsDateBeforeRecorded)
        , ("testDueAwareClosePreservesHistoricalShape", pure testDueAwareClosePreservesHistoricalShape)
        , ("testLegacyClosePreservesHistoricalShape", pure testLegacyClosePreservesHistoricalShape)
        , ("testIssueAppendCommit", testIssueAppendCommit)
        , ("testIssueDueUpdateCommit", testIssueDueUpdateCommit)
        , ("testIssueCloseCommit", testIssueCloseCommit)
        ]
  results <- sequence [action | (_, action) <- tests]
  let namedResults = zip (map fst tests) results
  mapM_ print namedResults
  if all snd namedResults then exitSuccess else exitFailure

currentFixtureSource :: Text
currentFixtureSource =
  "# keep this notebook note\n"
    <> householdIssuesHeader <> "\n"
    <> "ISSUE-1\topen\t2026-08-01\t2026-08-15\tnone\tmisc\tSome title\t1000\tJPY\tsome details\n"
    <> "ISSUE-2\topen\t2026-08-02\tnone\tnone\thome\tOther title\t\t\tother details\n"

closedFixtureSource :: Text
closedFixtureSource =
  householdIssuesHeader <> "\n"
    <> "ISSUE-1\tresolved\t2026-08-01\t2026-08-15\t2026-08-08\tmisc\tSome title\t1000\tJPY\tsome details\n"

dueAwareFixtureSource :: Text
dueAwareFixtureSource =
  dueAwareHouseholdIssuesHeader <> "\n"
    <> "ISSUE-1\topen\t2026-08-01\t2026-08-15\tmisc\tSome title\t1000\tJPY\tsome details\n"

legacyFixtureSource :: Text
legacyFixtureSource =
  legacyHouseholdIssuesHeader <> "\n"
    <> "ISSUE-1\topen\t2026-08-01\tmisc\tSome title\t1000\tJPY\tsome details\n"

testIntent :: IssueAppendIntent
testIntent = IssueAppendIntent
  { intentIssueId = mustIssueId "ISSUE-3"
  , intentStatus = Open
  , intentDate = fromGregorian 2026 8 4
  , intentCategory = "groceries"
  , intentTitle = "Buy milk"
  , intentAmount = Just
      (mkAmount (mustCommodity "JPY") (quantityFromInteger 500))
  , intentDetails = "need it for breakfast"
  }

optionalAmountIntent :: IssueAppendIntent
optionalAmountIntent = IssueAppendIntent
  { intentIssueId = mustIssueId "ISSUE-3"
  , intentStatus = Open
  , intentDate = fromGregorian 2026 8 5
  , intentCategory = "home"
  , intentTitle = "Check the boiler"
  , intentAmount = Nothing
  , intentDetails = "cost is not known yet"
  }

resolveIntent :: IssueCloseIntent
resolveIntent = IssueCloseIntent
  { closeIssueId = mustIssueId "ISSUE-1"
  , closeDisposition = ResolveIssue
  , closeDecisionMemo = "fixed by provider"
  }

dropIntent :: IssueCloseIntent
dropIntent = IssueCloseIntent
  { closeIssueId = mustIssueId "ISSUE-2"
  , closeDisposition = DropIssue
  , closeDecisionMemo = "no longer needed"
  }

closeDay :: Day
closeDay = fromGregorian 2026 8 8

testGeneratedIssueIdStartsAtOne :: Bool
testGeneratedIssueIdStartsAtOne =
  case generateAvailableIssueId (fromGregorian 2026 8 11) [] of
    Right identifier -> identifier == mustIssueId "ISS20260811-1"
    Left err -> error (show err)

testGeneratedIssueIdSkipsExisting :: Bool
testGeneratedIssueIdSkipsExisting =
  case generateAvailableIssueId
      (fromGregorian 2026 8 11)
      [mustIssueId "ISS20260811-1", mustIssueId "ISS20260811-2"] of
    Right identifier -> identifier == mustIssueId "ISS20260811-3"
    Left err -> error (show err)

testCurrentAppendWritesNotClosed :: Bool
testCurrentAppendWritesNotClosed =
  case prepareIssueAppend currentFixtureSource testIntent of
    Left err -> error (show err)
    Right preview ->
      candidateBlock preview
        == "ISSUE-3\topen\t2026-08-04\tundetermined\tnone\tgroceries\tBuy milk\t500\tJPY\tneed it for breakfast"
      && case findIssueById (mustIssueId "ISSUE-3")
          (candidateCompleteSource preview) of
        Just issue ->
          householdIssueRecordedOn issue == fromGregorian 2026 8 4
            && householdIssueDue issue == DueUndetermined
            && householdIssueClosed issue == NotClosed
        Nothing -> False

testExplicitKnownDueAppend :: Bool
testExplicitKnownDueAppend =
  let due = DueOn (fromGregorian 2026 8 15)
  in case prepareIssueAppendWithDue currentFixtureSource due testIntent of
    Left err -> error (show err)
    Right preview ->
      "\t2026-08-15\tnone\tgroceries\t" `T.isInfixOf` candidateBlock preview
        && case findIssueById (mustIssueId "ISSUE-3")
            (candidateCompleteSource preview) of
          Just issue -> householdIssueDue issue == due
          Nothing -> False

testOptionalAmountAppend :: Bool
testOptionalAmountAppend =
  case prepareIssueAppend currentFixtureSource optionalAmountIntent of
    Left err -> error (show err)
    Right preview -> case findIssueById (mustIssueId "ISSUE-3")
        (candidateCompleteSource preview) of
      Just issue -> householdIssueAmount issue == Nothing
      Nothing -> False

testEmptySourceAddsCurrentHeader :: Bool
testEmptySourceAddsCurrentHeader =
  case prepareIssueAppend "" optionalAmountIntent of
    Left err -> error (show err)
    Right preview ->
      householdIssuesHeader `T.isPrefixOf` candidateCompleteSource preview
        && length (T.splitOn "\t" (candidateBlock preview)) == 10
        && "\tundetermined\tnone\thome\t" `T.isInfixOf` candidateBlock preview

testDueAwareAppendPreservesShape :: Bool
testDueAwareAppendPreservesShape =
  case prepareIssueAppend dueAwareFixtureSource testIntent of
    Left err -> error (show err)
    Right preview ->
      length (T.splitOn "\t" (candidateBlock preview)) == 9
        && dueAwareHouseholdIssuesHeader `T.isPrefixOf` candidateCompleteSource preview
        && case findIssueById (mustIssueId "ISSUE-3")
            (candidateCompleteSource preview) of
          Just issue -> householdIssueClosed issue == NotClosed
          Nothing -> False

testLegacyAppendPreservesShape :: Bool
testLegacyAppendPreservesShape =
  case prepareIssueAppend legacyFixtureSource testIntent of
    Left err -> error (show err)
    Right preview ->
      length (T.splitOn "\t" (candidateBlock preview)) == 8
        && legacyHouseholdIssuesHeader `T.isPrefixOf` candidateCompleteSource preview

testLegacyExplicitDueRejected :: Bool
testLegacyExplicitDueRejected =
  case prepareIssueAppendWithDue legacyFixtureSource NoDueDate testIntent of
    Left errors ->
      LegacyIssueSourceCannotRepresentDue NoDueDate `elem` NonEmpty.toList errors
    Right _ -> False

testDueUpdateChangesOnlyDue :: Bool
testDueUpdateChangesOnlyDue =
  let intent = IssueDueUpdateIntent
        { dueUpdateIssueId = mustIssueId "ISSUE-1"
        , dueUpdateValue = NoDueDate
        }
  in case prepareIssueDueUpdate currentFixtureSource intent of
    Left err -> error (show err)
    Right preview ->
      dueUpdateOriginalRow preview
        == "ISSUE-1\topen\t2026-08-01\t2026-08-15\tnone\tmisc\tSome title\t1000\tJPY\tsome details"
        && dueUpdateCandidateRow preview
          == "ISSUE-1\topen\t2026-08-01\tnone\tnone\tmisc\tSome title\t1000\tJPY\tsome details"
        && "# keep this notebook note\n" `T.isPrefixOf`
          dueUpdateCandidateCompleteSource preview

testDueUpdateRejectsClosedIssue :: Bool
testDueUpdateRejectsClosedIssue =
  case prepareIssueDueUpdate closedFixtureSource
      IssueDueUpdateIntent
        { dueUpdateIssueId = mustIssueId "ISSUE-1"
        , dueUpdateValue = NoDueDate
        } of
    Left errors -> DueUpdateIssueNotOpen Resolved `elem` NonEmpty.toList errors
    Right _ -> False

testCloseRequiresDateForCurrentSource :: Bool
testCloseRequiresDateForCurrentSource =
  case prepareIssueClose currentFixtureSource resolveIntent of
    Left errors ->
      CloseDateRequiredForClosedAwareSource `elem` NonEmpty.toList errors
    Right _ -> False

testResolveIssueRecordsClosedDate :: Bool
testResolveIssueRecordsClosedDate =
  case prepareIssueCloseOn currentFixtureSource closeDay resolveIntent of
    Left err -> error (show err)
    Right preview ->
      closeCandidateRow preview
        == "ISSUE-1\tresolved\t2026-08-01\t2026-08-15\t2026-08-08\tmisc\tSome title\t1000\tJPY\tsome details。Decision: fixed by provider"
        && case findIssueById (mustIssueId "ISSUE-1")
            (closeCandidateCompleteSource preview) of
          Just issue ->
            householdIssueStatus issue == Resolved
              && householdIssueDue issue == DueOn (fromGregorian 2026 8 15)
              && householdIssueClosed issue == ClosedOn closeDay
              && householdIssueDetails issue
                == "[misc] some details。Decision: fixed by provider"
          Nothing -> False

testDropIssueRecordsClosedDate :: Bool
testDropIssueRecordsClosedDate =
  case prepareIssueCloseOn currentFixtureSource closeDay dropIntent of
    Left err -> error (show err)
    Right preview -> case findIssueById (mustIssueId "ISSUE-2")
        (closeCandidateCompleteSource preview) of
      Just issue ->
        householdIssueStatus issue == Dropped
          && householdIssueDue issue == NoDueDate
          && householdIssueClosed issue == ClosedOn closeDay
      Nothing -> False

testCloseRejectsDateBeforeRecorded :: Bool
testCloseRejectsDateBeforeRecorded =
  case prepareIssueCloseOn currentFixtureSource
      (fromGregorian 2026 7 31) resolveIntent of
    Left errors -> any isBeforeRecorded (NonEmpty.toList errors)
    Right _ -> False
  where
    isBeforeRecorded (CloseDateBeforeRecorded recorded closed) =
      recorded == fromGregorian 2026 8 1
        && closed == fromGregorian 2026 7 31
    isBeforeRecorded _ = False

testDueAwareClosePreservesHistoricalShape :: Bool
testDueAwareClosePreservesHistoricalShape =
  case prepareIssueClose dueAwareFixtureSource resolveIntent of
    Left err -> error (show err)
    Right preview ->
      length (T.splitOn "\t" (closeCandidateRow preview)) == 9
        && case findIssueById (mustIssueId "ISSUE-1")
            (closeCandidateCompleteSource preview) of
          Just issue -> householdIssueClosed issue == ClosedUndetermined
          Nothing -> False

testLegacyClosePreservesHistoricalShape :: Bool
testLegacyClosePreservesHistoricalShape =
  case prepareIssueClose legacyFixtureSource resolveIntent of
    Left err -> error (show err)
    Right preview ->
      length (T.splitOn "\t" (closeCandidateRow preview)) == 8
        && case findIssueById (mustIssueId "ISSUE-1")
            (closeCandidateCompleteSource preview) of
          Just issue ->
            householdIssueDue issue == DueUndetermined
              && householdIssueClosed issue == ClosedUndetermined
          Nothing -> False

findIssueById :: IssueId -> Text -> Maybe HouseholdIssue
findIssueById identifier source = case parseHouseholdIssues source of
  Left _ -> Nothing
  Right issues -> go issues
  where
    go [] = Nothing
    go (issue : rest)
      | householdIssueId issue == identifier = Just issue
      | otherwise = go rest

testIssueAppendCommit :: IO Bool
testIssueAppendCommit = do
  let path = "tests/fixtures/test_editor_issue_commit.tsv"
  cleanup path
  TIO.writeFile path currentFixtureSource
  result <- case prepareIssueAppend currentFixtureSource testIntent of
    Left err -> print err >> pure False
    Right preview -> publishAndVerify path currentFixtureSource
      (candidateCompleteSource preview)
      (\written -> case findIssueById (mustIssueId "ISSUE-3") written of
        Just issue -> householdIssueClosed issue == NotClosed
        Nothing -> False)
  cleanup path
  pure result

testIssueDueUpdateCommit :: IO Bool
testIssueDueUpdateCommit = do
  let path = "tests/fixtures/test_editor_issue_due_update.tsv"
      intent = IssueDueUpdateIntent
        { dueUpdateIssueId = mustIssueId "ISSUE-1"
        , dueUpdateValue = NoDueDate
        }
  cleanup path
  TIO.writeFile path currentFixtureSource
  result <- case prepareIssueDueUpdate currentFixtureSource intent of
    Left err -> print err >> pure False
    Right preview -> publishAndVerify path currentFixtureSource
      (dueUpdateCandidateCompleteSource preview)
      (\written -> case findIssueById (mustIssueId "ISSUE-1") written of
        Just issue ->
          householdIssueDue issue == NoDueDate
            && householdIssueClosed issue == NotClosed
        Nothing -> False)
  cleanup path
  pure result

testIssueCloseCommit :: IO Bool
testIssueCloseCommit = do
  let path = "tests/fixtures/test_editor_issue_close.tsv"
  cleanup path
  TIO.writeFile path currentFixtureSource
  result <- case prepareIssueCloseOn currentFixtureSource closeDay resolveIntent of
    Left err -> print err >> pure False
    Right preview -> publishAndVerify path currentFixtureSource
      (closeCandidateCompleteSource preview)
      (\written -> case findIssueById (mustIssueId "ISSUE-1") written of
        Just issue ->
          householdIssueStatus issue == Resolved
            && householdIssueClosed issue == ClosedOn closeDay
        Nothing -> False)
  cleanup path
  pure result

publishAndVerify :: FilePath -> Text -> Text -> (Text -> Bool) -> IO Bool
publishAndVerify path expected candidate verify = do
  writeResult <- publishWithAdmission
    parseHouseholdIssues
    WriteIntent
      { targetFilePath = path
      , expectedOldBytes = ExpectedSource expected
      , candidateNewBytes = CandidateSource candidate
      }
  case writeResult of
    Left err -> print err >> pure False
    Right () -> do
      written <- TIO.readFile path
      pure (written == candidate && verify written)

cleanup :: FilePath -> IO ()
cleanup path = do
  removeIfPresent path
  removeIfPresent (path <> ".backup.tmp")
  removeIfPresent (path <> ".new.tmp")

removeIfPresent :: FilePath -> IO ()
removeIfPresent path =
  catch
    (removeTextFile defaultWriterFileSystem path)
    (\(_ :: IOException) -> pure ())

mustIssueId :: Text -> IssueId
mustIssueId value = either (error "bad IssueId") id (mkIssueId value)

mustCommodity :: Text -> Commodity
mustCommodity value = either (error "bad Commodity") id (mkCommodity value)
