{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (IOException, catch)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
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
  , prepareIssueDueUpdate
  )
import HKernel.Household.Issue.TSV
  ( householdIssuesHeader
  , legacyHouseholdIssuesHeader
  , parseHouseholdIssues
  )
import HKernel.HouseholdIssue
  ( HouseholdIssue
  , IssueDue(..)
  , IssueId
  , IssueStatus(..)
  , householdIssueAmount
  , householdIssueDetails
  , householdIssueDue
  , householdIssueId
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
        , ("testValidIssueAppend", pure testValidIssueAppend)
        , ("testExplicitNoDueAppend", pure testExplicitNoDueAppend)
        , ("testExplicitKnownDueAppend", pure testExplicitKnownDueAppend)
        , ("testOptionalAmountAppend", pure testOptionalAmountAppend)
        , ("testEmptySourceAddsCurrentHeader", pure testEmptySourceAddsCurrentHeader)
        , ("testCommentOnlySourceAddsCurrentHeader", pure testCommentOnlySourceAddsCurrentHeader)
        , ("testLegacyUndeterminedAppendPreservesShape", pure testLegacyUndeterminedAppendPreservesShape)
        , ("testLegacyExplicitDueRejected", pure testLegacyExplicitDueRejected)
        , ("testOneSidedBlankAmountRejected", pure testOneSidedBlankAmountRejected)
        , ("testIssueDueUpdateChangesOnlyDue", pure testIssueDueUpdateChangesOnlyDue)
        , ("testIssueDueUpdateToKnownDate", pure testIssueDueUpdateToKnownDate)
        , ("testIssueDueUpdateRejectsUnknownIdentity", pure testIssueDueUpdateRejectsUnknownIdentity)
        , ("testIssueDueUpdateRejectsClosedIssue", pure testIssueDueUpdateRejectsClosedIssue)
        , ("testIssueDueUpdateRejectsLegacySource", pure testIssueDueUpdateRejectsLegacySource)
        , ("testResolveIssueByIdentity", pure testResolveIssueByIdentity)
        , ("testDropIssueByIdentity", pure testDropIssueByIdentity)
        , ("testIssueClosePreservesUntouchedBytesAndDue", pure testIssueClosePreservesUntouchedBytesAndDue)
        , ("testLegacyIssueClosePreservesShape", pure testLegacyIssueClosePreservesShape)
        , ("testIssueCloseRejectsUnknownIdentity", pure testIssueCloseRejectsUnknownIdentity)
        , ("testIssueCloseRejectsClosedIssue", pure testIssueCloseRejectsClosedIssue)
        , ("testIssueCloseRejectsBlankMemo", pure testIssueCloseRejectsBlankMemo)
        , ("testIssueCloseRejectsControlMemo", pure testIssueCloseRejectsControlMemo)
        , ("testIssueCommit", testIssueCommit)
        , ("testEmptyIssueCommit", testEmptyIssueCommit)
        , ("testIssueDueUpdateCommit", testIssueDueUpdateCommit)
        , ("testIssueCloseCommit", testIssueCloseCommit)
        ]
  results <- sequence [action | (_, action) <- tests]
  let namedResults = zip (map fst tests) results
  mapM_ print namedResults
  if all snd namedResults
    then exitSuccess
    else exitFailure

fixtureSource :: Text
fixtureSource = T.unlines
  [ householdIssuesHeader
  , "ISSUE-1\topen\t2026-08-01\tundetermined\tmisc\tSome title\t1000\tJPY\tsome details"
  ]

legacyFixtureSource :: Text
legacyFixtureSource = T.unlines
  [ legacyHouseholdIssuesHeader
  , "ISSUE-1\topen\t2026-08-01\tmisc\tSome title\t1000\tJPY\tsome details"
  ]

closeFixtureSource :: Text
closeFixtureSource =
  "# keep this notebook note\n"
    <> householdIssuesHeader <> "\n"
    <> "ISSUE-1\topen\t2026-08-01\t2026-08-15\tmisc\tSome title\t1000\tJPY\tsome details\n"
    <> "ISSUE-2\topen\t2026-08-02\tnone\thome\tOther title\t\t\tother details\n"

legacyCloseFixtureSource :: Text
legacyCloseFixtureSource =
  legacyHouseholdIssuesHeader <> "\n"
    <> "ISSUE-1\topen\t2026-08-01\tmisc\tSome title\t1000\tJPY\tsome details\n"

testIntent :: IssueAppendIntent
testIntent = IssueAppendIntent
  { intentIssueId = mustIssueId "ISSUE-2"
  , intentStatus = Open
  , intentDate = fromGregorian 2026 8 4
  , intentCategory = "groceries"
  , intentTitle = "Buy milk"
  , intentAmount = Just
      (mkAmount
        (mustCommodity "JPY")
        (quantityFromInteger 500))
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
  , closeDecisionMemo = "2026-08-08 fixed by provider"
  }

dropIntent :: IssueCloseIntent
dropIntent = IssueCloseIntent
  { closeIssueId = mustIssueId "ISSUE-2"
  , closeDisposition = DropIssue
  , closeDecisionMemo = "2026-08-08 no longer needed"
  }

testGeneratedIssueIdStartsAtOne :: Bool
testGeneratedIssueIdStartsAtOne =
  case generateAvailableIssueId (fromGregorian 2026 8 11) [] of
    Right identifier -> identifier == mustIssueId "ISS20260811-1"
    Left err -> error (show err)

testGeneratedIssueIdSkipsExisting :: Bool
testGeneratedIssueIdSkipsExisting =
  case generateAvailableIssueId
      (fromGregorian 2026 8 11)
      [ mustIssueId "ISS20260811-1"
      , mustIssueId "ISS20260811-2"
      , mustIssueId "ISS20260810-3"
      ] of
    Right identifier -> identifier == mustIssueId "ISS20260811-3"
    Left err -> error (show err)

testValidIssueAppend :: Bool
testValidIssueAppend =
  case prepareIssueAppend fixtureSource testIntent of
    Right preview ->
      candidateBlock preview
        == "ISSUE-2\topen\t2026-08-04\tundetermined\tgroceries\tBuy milk\t500\tJPY\tneed it for breakfast"
      && case findIssueById (mustIssueId "ISSUE-2") (candidateCompleteSource preview) of
        Just issue -> householdIssueDue issue == DueUndetermined
        Nothing -> False
    Left err -> error (show err)

testExplicitNoDueAppend :: Bool
testExplicitNoDueAppend =
  case prepareIssueAppendWithDue fixtureSource NoDueDate testIntent of
    Right preview ->
      "\tnone\tgroceries\t" `T.isInfixOf` candidateBlock preview
        && case findIssueById (mustIssueId "ISSUE-2") (candidateCompleteSource preview) of
          Just issue -> householdIssueDue issue == NoDueDate
          Nothing -> False
    Left err -> error (show err)

testExplicitKnownDueAppend :: Bool
testExplicitKnownDueAppend =
  let due = DueOn (fromGregorian 2026 8 15)
  in case prepareIssueAppendWithDue fixtureSource due testIntent of
    Right preview ->
      "\t2026-08-15\tgroceries\t" `T.isInfixOf` candidateBlock preview
        && case findIssueById (mustIssueId "ISSUE-2") (candidateCompleteSource preview) of
          Just issue -> householdIssueDue issue == due
          Nothing -> False
    Left err -> error (show err)

testOptionalAmountAppend :: Bool
testOptionalAmountAppend =
  case prepareIssueAppend fixtureSource optionalAmountIntent of
    Left err -> error (show err)
    Right preview ->
      candidateBlock preview
        == "ISSUE-3\topen\t2026-08-05\tundetermined\thome\tCheck the boiler\t\t\tcost is not known yet"
      && parsedOptionalIssueMatches preview

testEmptySourceAddsCurrentHeader :: Bool
testEmptySourceAddsCurrentHeader =
  case prepareIssueAppend "" optionalAmountIntent of
    Left err -> error (show err)
    Right preview ->
      candidateCompleteSource preview
        == householdIssuesHeader <> "\n" <> candidateBlock preview
      && "\tundetermined\thome\t" `T.isInfixOf` candidateBlock preview
      && parsedOptionalIssueMatches preview

testCommentOnlySourceAddsCurrentHeader :: Bool
testCommentOnlySourceAddsCurrentHeader =
  case prepareIssueAppend "# retained notebook note\n" optionalAmountIntent of
    Left err -> error (show err)
    Right preview ->
      householdIssuesHeader `T.isInfixOf` candidateCompleteSource preview
      && parsedOptionalIssueMatches preview

testLegacyUndeterminedAppendPreservesShape :: Bool
testLegacyUndeterminedAppendPreservesShape =
  case prepareIssueAppend legacyFixtureSource testIntent of
    Left err -> error (show err)
    Right preview ->
      candidateBlock preview
        == "ISSUE-2\topen\t2026-08-04\tgroceries\tBuy milk\t500\tJPY\tneed it for breakfast"
      && legacyHouseholdIssuesHeader `T.isPrefixOf` candidateCompleteSource preview
      && case findIssueById (mustIssueId "ISSUE-2") (candidateCompleteSource preview) of
        Just issue -> householdIssueDue issue == DueUndetermined
        Nothing -> False

testLegacyExplicitDueRejected :: Bool
testLegacyExplicitDueRejected =
  case prepareIssueAppendWithDue legacyFixtureSource NoDueDate testIntent of
    Left errors ->
      LegacyIssueSourceCannotRepresentDue NoDueDate `elem` NonEmpty.toList errors
    Right _ -> False

testOneSidedBlankAmountRejected :: Bool
testOneSidedBlankAmountRejected =
  case parseHouseholdIssues oneSidedBlankSource of
    Left _ -> True
    Right _ -> False
  where
    oneSidedBlankSource = T.unlines
      [ householdIssuesHeader
      , "ISSUE-4\topen\t2026-08-05\tnone\thome\tBroken latch\t\tJPY\tinspect first"
      ]

parsedOptionalIssueMatches :: IssueAppendPreview -> Bool
parsedOptionalIssueMatches preview =
  case parseHouseholdIssues (candidateCompleteSource preview) of
    Right issues -> case reverse issues of
      issue : _ ->
        householdIssueId issue == intentIssueId optionalAmountIntent
          && householdIssueAmount issue == Nothing
          && householdIssueDue issue == DueUndetermined
      [] -> False
    Left _ -> False

testIssueDueUpdateChangesOnlyDue :: Bool
testIssueDueUpdateChangesOnlyDue =
  let intent = IssueDueUpdateIntent
        { dueUpdateIssueId = mustIssueId "ISSUE-1"
        , dueUpdateValue = NoDueDate
        }
  in case prepareIssueDueUpdate closeFixtureSource intent of
    Left err -> error (show err)
    Right preview ->
      dueUpdateOriginalRow preview
        == "ISSUE-1\topen\t2026-08-01\t2026-08-15\tmisc\tSome title\t1000\tJPY\tsome details"
      && dueUpdateCandidateRow preview
        == "ISSUE-1\topen\t2026-08-01\tnone\tmisc\tSome title\t1000\tJPY\tsome details"
      && "# keep this notebook note\n" `T.isPrefixOf` dueUpdateCandidateCompleteSource preview
      && "ISSUE-2\topen\t2026-08-02\tnone\thome\tOther title\t\t\tother details\n"
          `T.isInfixOf` dueUpdateCandidateCompleteSource preview
      && "\n" `T.isSuffixOf` dueUpdateCandidateCompleteSource preview
      && case findIssueById (mustIssueId "ISSUE-1")
          (dueUpdateCandidateCompleteSource preview) of
        Just issue -> householdIssueDue issue == NoDueDate
        Nothing -> False

testIssueDueUpdateToKnownDate :: Bool
testIssueDueUpdateToKnownDate =
  let due = DueOn (fromGregorian 2026 8 20)
      intent = IssueDueUpdateIntent
        { dueUpdateIssueId = mustIssueId "ISSUE-2"
        , dueUpdateValue = due
        }
  in case prepareIssueDueUpdate closeFixtureSource intent of
    Left err -> error (show err)
    Right preview ->
      dueUpdateCandidateRow preview
        == "ISSUE-2\topen\t2026-08-02\t2026-08-20\thome\tOther title\t\t\tother details"
      && case findIssueById (mustIssueId "ISSUE-2")
          (dueUpdateCandidateCompleteSource preview) of
        Just issue -> householdIssueDue issue == due
        Nothing -> False

testIssueDueUpdateRejectsUnknownIdentity :: Bool
testIssueDueUpdateRejectsUnknownIdentity =
  case prepareIssueDueUpdate closeFixtureSource
      IssueDueUpdateIntent
        { dueUpdateIssueId = mustIssueId "ISSUE-MISSING"
        , dueUpdateValue = NoDueDate
        } of
    Left errors -> any isNotFound (NonEmpty.toList errors)
    Right _ -> False
  where
    isNotFound (DueUpdateIssueNotFound identifier) =
      identifier == mustIssueId "ISSUE-MISSING"
    isNotFound _ = False

testIssueDueUpdateRejectsClosedIssue :: Bool
testIssueDueUpdateRejectsClosedIssue =
  let source = T.replace "ISSUE-1\topen\t" "ISSUE-1\tresolved\t" closeFixtureSource
  in case prepareIssueDueUpdate source
      IssueDueUpdateIntent
        { dueUpdateIssueId = mustIssueId "ISSUE-1"
        , dueUpdateValue = NoDueDate
        } of
    Left errors -> DueUpdateIssueNotOpen Resolved `elem` NonEmpty.toList errors
    Right _ -> False

testIssueDueUpdateRejectsLegacySource :: Bool
testIssueDueUpdateRejectsLegacySource =
  case prepareIssueDueUpdate legacyCloseFixtureSource
      IssueDueUpdateIntent
        { dueUpdateIssueId = mustIssueId "ISSUE-1"
        , dueUpdateValue = NoDueDate
        } of
    Left errors -> DueUpdateRequiresDueAwareSource `elem` NonEmpty.toList errors
    Right _ -> False

testResolveIssueByIdentity :: Bool
testResolveIssueByIdentity =
  case prepareIssueClose closeFixtureSource resolveIntent of
    Left err -> error (show err)
    Right preview ->
      closeOriginalRow preview
        == "ISSUE-1\topen\t2026-08-01\t2026-08-15\tmisc\tSome title\t1000\tJPY\tsome details"
      && closeCandidateRow preview
        == "ISSUE-1\tresolved\t2026-08-01\t2026-08-15\tmisc\tSome title\t1000\tJPY\tsome details。Decision: 2026-08-08 fixed by provider"
      && case findIssueById (mustIssueId "ISSUE-1")
          (closeCandidateCompleteSource preview) of
        Just issue ->
          householdIssueStatus issue == Resolved
            && householdIssueDue issue == DueOn (fromGregorian 2026 8 15)
            && householdIssueDetails issue
              == "[misc] some details。Decision: 2026-08-08 fixed by provider"
        Nothing -> False

testDropIssueByIdentity :: Bool
testDropIssueByIdentity =
  case prepareIssueClose closeFixtureSource dropIntent of
    Left err -> error (show err)
    Right preview ->
      closeCandidateRow preview
        == "ISSUE-2\tdropped\t2026-08-02\tnone\thome\tOther title\t\t\tother details。Decision: 2026-08-08 no longer needed"
      && case findIssueById (mustIssueId "ISSUE-2")
          (closeCandidateCompleteSource preview) of
        Just issue ->
          householdIssueStatus issue == Dropped
            && householdIssueDue issue == NoDueDate
        Nothing -> False

testIssueClosePreservesUntouchedBytesAndDue :: Bool
testIssueClosePreservesUntouchedBytesAndDue =
  case prepareIssueClose closeFixtureSource resolveIntent of
    Left err -> error (show err)
    Right preview ->
      "# keep this notebook note\n" `T.isPrefixOf` closeCandidateCompleteSource preview
        && "ISSUE-2\topen\t2026-08-02\tnone\thome\tOther title\t\t\tother details\n"
          `T.isInfixOf` closeCandidateCompleteSource preview
        && "\t2026-08-15\tmisc\t" `T.isInfixOf` closeCandidateRow preview
        && "\n" `T.isSuffixOf` closeCandidateCompleteSource preview

testLegacyIssueClosePreservesShape :: Bool
testLegacyIssueClosePreservesShape =
  case prepareIssueClose legacyCloseFixtureSource resolveIntent of
    Left err -> error (show err)
    Right preview ->
      closeCandidateRow preview
        == "ISSUE-1\tresolved\t2026-08-01\tmisc\tSome title\t1000\tJPY\tsome details。Decision: 2026-08-08 fixed by provider"
      && length (T.splitOn "\t" (closeCandidateRow preview)) == 8

testIssueCloseRejectsUnknownIdentity :: Bool
testIssueCloseRejectsUnknownIdentity =
  case prepareIssueClose closeFixtureSource
      resolveIntent { closeIssueId = mustIssueId "ISSUE-MISSING" } of
    Left errors -> any isNotFound (NonEmpty.toList errors)
    Right _ -> False
  where
    isNotFound (CloseIssueNotFound identifier) =
      identifier == mustIssueId "ISSUE-MISSING"
    isNotFound _ = False

testIssueCloseRejectsClosedIssue :: Bool
testIssueCloseRejectsClosedIssue =
  case prepareIssueClose resolvedFixture resolveIntent of
    Left errors -> any isAlreadyClosed (NonEmpty.toList errors)
    Right _ -> False
  where
    resolvedFixture = T.replace "\topen\t" "\tresolved\t" fixtureSource
    isAlreadyClosed (CloseIssueNotOpen Resolved) = True
    isAlreadyClosed _ = False

testIssueCloseRejectsBlankMemo :: Bool
testIssueCloseRejectsBlankMemo =
  case prepareIssueClose closeFixtureSource
      resolveIntent { closeDecisionMemo = "   " } of
    Left errors -> CloseDecisionMemoBlank `elem` NonEmpty.toList errors
    Right _ -> False

testIssueCloseRejectsControlMemo :: Bool
testIssueCloseRejectsControlMemo =
  case prepareIssueClose closeFixtureSource
      resolveIntent { closeDecisionMemo = "bad\tmemo" } of
    Left errors -> CloseDecisionMemoHasControlCharacter `elem` NonEmpty.toList errors
    Right _ -> False

findIssueById :: IssueId -> Text -> Maybe HouseholdIssue
findIssueById identifier source = case parseHouseholdIssues source of
  Left _ -> Nothing
  Right issues -> findTypedIssue identifier issues

findTypedIssue :: IssueId -> [HouseholdIssue] -> Maybe HouseholdIssue
findTypedIssue identifier = go
  where
    go [] = Nothing
    go (issue : rest)
      | householdIssueId issue == identifier = Just issue
      | otherwise = go rest

testIssueCommit :: IO Bool
testIssueCommit =
  commitAndVerify
    "tests/fixtures/test_editor_issue_commit.tsv"
    fixtureSource
    testIntent
    (const True)

testEmptyIssueCommit :: IO Bool
testEmptyIssueCommit =
  commitAndVerify
    "tests/fixtures/test_editor_empty_issue_commit.tsv"
    ""
    optionalAmountIntent
    (\written -> case parseHouseholdIssues written of
      Right [issue] ->
        householdIssueId issue == intentIssueId optionalAmountIntent
          && householdIssueAmount issue == Nothing
          && householdIssueDue issue == DueUndetermined
      _ -> False)

testIssueDueUpdateCommit :: IO Bool
testIssueDueUpdateCommit = do
  let path = "tests/fixtures/test_editor_issue_due_update.tsv"
      intent = IssueDueUpdateIntent
        { dueUpdateIssueId = mustIssueId "ISSUE-1"
        , dueUpdateValue = NoDueDate
        }
  cleanup path
  TIO.writeFile path closeFixtureSource
  result <- case prepareIssueDueUpdate closeFixtureSource intent of
    Left err -> print err >> pure False
    Right preview -> do
      writeResult <- publishWithAdmission
        parseHouseholdIssues
        WriteIntent
          { targetFilePath = path
          , expectedOldBytes = ExpectedSource closeFixtureSource
          , candidateNewBytes = CandidateSource
              (dueUpdateCandidateCompleteSource preview)
          }
      case writeResult of
        Left err -> print err >> pure False
        Right () -> do
          written <- TIO.readFile path
          pure
            (written == dueUpdateCandidateCompleteSource preview
              && case findIssueById (mustIssueId "ISSUE-1") written of
                Just issue -> householdIssueDue issue == NoDueDate
                Nothing -> False)
  cleanup path
  pure result

testIssueCloseCommit :: IO Bool
testIssueCloseCommit = do
  let path = "tests/fixtures/test_editor_issue_close.tsv"
  cleanup path
  TIO.writeFile path closeFixtureSource
  result <- case prepareIssueClose closeFixtureSource resolveIntent of
    Left err -> print err >> pure False
    Right preview -> do
      writeResult <- publishWithAdmission
        parseHouseholdIssues
        WriteIntent
          { targetFilePath = path
          , expectedOldBytes = ExpectedSource closeFixtureSource
          , candidateNewBytes = CandidateSource
              (closeCandidateCompleteSource preview)
          }
      case writeResult of
        Left err -> print err >> pure False
        Right () -> do
          written <- TIO.readFile path
          pure
            (written == closeCandidateCompleteSource preview
              && case findIssueById (mustIssueId "ISSUE-1") written of
                Just issue ->
                  householdIssueStatus issue == Resolved
                    && householdIssueDue issue == DueOn (fromGregorian 2026 8 15)
                Nothing -> False)
  cleanup path
  pure result

commitAndVerify
  :: FilePath
  -> Text
  -> IssueAppendIntent
  -> (Text -> Bool)
  -> IO Bool
commitAndVerify path source intent verify = do
  cleanup path
  TIO.writeFile path source
  result <- case prepareIssueAppend source intent of
    Left err -> print err >> pure False
    Right preview -> do
      writeResult <- publishWithAdmission
        parseHouseholdIssues
        WriteIntent
          { targetFilePath = path
          , expectedOldBytes = ExpectedSource source
          , candidateNewBytes = CandidateSource (candidateCompleteSource preview)
          }
      case writeResult of
        Left err -> print err >> pure False
        Right () -> do
          written <- TIO.readFile path
          pure
            (written == candidateCompleteSource preview
              && verify written)
  cleanup path
  pure result

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