{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (IOException, catch)
import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (fromGregorian)
import System.Directory (doesFileExist)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (Account, mkAccount)
import HKernel.Actual.Journal (ActualJournal, parseActualJournal)
import HKernel.Editor.ActualAppend (ActualEditIntent(..))
import HKernel.Editor.HouseholdWorkspace
  ( IssueRealizeError(..)
  , IssueRealizeIntent(..)
  , IssueRealizePreview(..)
  , IssueRealizeWriteError(..)
  , IssueRealizeWriteIntent(..)
  , admitIssueRelationSource
  , prepareIssueRealize
  , publishIssueRealize
  )
import HKernel.Editor.SourcePublication
  ( WriterFileSystem(..)
  , defaultWriterFileSystem
  )
import HKernel.Editor.TransactionBlock (IntentPosting(..))
import HKernel.Household.Issue.TSV
  ( householdIssuesHeader
  , parseHouseholdIssues
  )
import HKernel.HouseholdIssue
  ( IssueClosed(..)
  , IssueStatus(..)
  , householdIssueClosed
  , householdIssueId
  , householdIssueStatus
  , issueIdText
  , mkIssueId
  )
import HKernel.Money (Commodity, Quantity, mkCommodity, parseQuantity)
import HKernel.Plan.Completion (actualTransactionIdText)
import HKernel.Plan.Journal (PlanJournal, parsePlanJournal)

main :: IO ()
main = do
  let pureResults =
        [ ("realize creates one durable Actual relation and Issue closure", testPreparedRealization)
        , ("realize rejects an already closed Issue", testClosedIssueRejected)
        , ("realize owns the new Actual event-id", testCallerEventIdRejected)
        , ("relation time cannot precede Issue recording", testRelationBeforeIssueRejected)
        , ("Issue close cannot precede relation recording", testCloseBeforeRelationRejected)
        ]
  ioResults <- sequence
    [ fmap ((,) "publication writes all three sources") testPublicationSuccess
    , fmap ((,) "post-admission failure restores all three sources") testPublicationRollback
    ]
  let results = pureResults ++ ioResults
  mapM_ print results
  if all snd results then exitSuccess else exitFailure

actualSource :: Text
actualSource = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:books"
  , "  type: Expense"
  , "  commodity: JPY"
  ]

planSource :: Text
planSource = actualSource

issuesSource :: Text
issuesSource = T.unlines
  [ householdIssuesHeader
  , "ISSUE-ALG\topen\t2026-08-01\tnone\tnone\tculture\t代数学の歴史を買う\t1800\tJPY\t購入を検討"
  ]

actualJournal :: ActualJournal
actualJournal = mustRight (parseActualJournal actualSource)

planJournal :: PlanJournal
planJournal = mustRight (parsePlanJournal planSource)

realizeIntent :: IssueRealizeIntent
realizeIntent = IssueRealizeIntent
  { realizeIssueId = mustIssueId "ISSUE-ALG"
  , realizeRecordedOn = fromGregorian 2026 8 17
  , realizeClosedOn = fromGregorian 2026 8 17
  , realizeActualIntent = ActualEditIntent
      { intentDate = fromGregorian 2026 8 16
      , intentDescription = "代数学の歴史"
      , intentPostings =
          IntentPosting accBank (qty "-1800") (Just jpy)
            :| [IntentPosting accBooks (qty "1800") (Just jpy)]
      , intentMetadata = []
      }
  , realizeDecisionMemo = "購入した"
  }

testPreparedRealization :: Bool
testPreparedRealization = case prepared of
  Left err -> error (show err)
  Right preview ->
    let actualId = actualTransactionIdText (realizedActualId preview)
        candidateActual = mustRight
          (parseActualJournal (realizedActualCandidateSource preview))
        candidateIssues = mustRight
          (parseHouseholdIssues (realizedIssuesCandidateSource preview))
        targetIssue = head
          [ issue
          | issue <- candidateIssues
          , issueIdText (householdIssueId issue) == "ISSUE-ALG"
          ]
        admittedRelations = admitIssueRelationSource
          candidateActual
          planJournal
          candidateIssues
          (realizedRelationCandidateSource preview)
    in actualId == "ISSUE-ALG-actual"
      && "; event-id: ISSUE-ALG-actual" `T.isInfixOf` realizedActualBlock preview
      && "\trealized-as\tISSUE-ALG-actual\t購入した" `T.isInfixOf`
          realizedRelationBlock preview
      && "ISSUE-ALG\tresolved\t2026-08-01\tnone\t2026-08-17\t" `T.isPrefixOf`
          realizedIssueBlock preview
      && householdIssueStatus targetIssue == Resolved
      && householdIssueClosed targetIssue == ClosedOn (fromGregorian 2026 8 17)
      && either (const False) ((== 1) . length) admittedRelations

testClosedIssueRejected :: Bool
testClosedIssueRejected = case prepared of
  Left err -> error (show err)
  Right preview -> case prepareIssueRealize
      (mustRight (parseActualJournal (realizedActualCandidateSource preview)))
      planJournal
      (realizedActualCandidateSource preview)
      (realizedRelationCandidateSource preview)
      (realizedIssuesCandidateSource preview)
      realizeIntent of
    Left errors -> RealizeIssueNotOpen Resolved `elem` NonEmpty.toList errors
    Right _ -> False

testCallerEventIdRejected :: Bool
testCallerEventIdRejected = case prepareIssueRealize
    actualJournal planJournal actualSource "" issuesSource
    realizeIntent
      { realizeActualIntent = (realizeActualIntent realizeIntent)
          { intentMetadata = [("event-id", "caller-owned")]
          }
      } of
  Left errors -> RealizeActualMetadataOwnsEventId `elem` NonEmpty.toList errors
  Right _ -> False

testRelationBeforeIssueRejected :: Bool
testRelationBeforeIssueRejected = case prepareIssueRealize
    actualJournal planJournal actualSource "" issuesSource
    realizeIntent { realizeRecordedOn = fromGregorian 2026 7 31 } of
  Left errors -> any isChronology (NonEmpty.toList errors)
  Right _ -> False
  where
    isChronology (RealizeRelationBeforeIssueRecorded recorded relationDay) =
      recorded == fromGregorian 2026 8 1
        && relationDay == fromGregorian 2026 7 31
    isChronology _ = False

testCloseBeforeRelationRejected :: Bool
testCloseBeforeRelationRejected = case prepareIssueRealize
    actualJournal planJournal actualSource "" issuesSource
    realizeIntent { realizeClosedOn = fromGregorian 2026 8 16 } of
  Left errors -> any isChronology (NonEmpty.toList errors)
  Right _ -> False
  where
    isChronology (RealizeCloseBeforeRelation relationDay closedDay) =
      relationDay == fromGregorian 2026 8 17
        && closedDay == fromGregorian 2026 8 16
    isChronology _ = False

prepared :: Either (NonEmpty IssueRealizeError) IssueRealizePreview
prepared = prepareIssueRealize
  actualJournal planJournal actualSource "" issuesSource realizeIntent

testPublicationSuccess :: IO Bool
testPublicationSuccess = do
  cleanupPublicationFiles
  TIO.writeFile actualPath actualSource
  TIO.writeFile issuesPath issuesSource
  result <- case prepared of
    Left err -> print err >> pure False
    Right preview -> do
      writeResult <- publishIssueRealize
        (pure (Right ()))
        (writeIntent False "" preview)
      relationExists <- doesFileExist relationPath
      actualAfter <- TIO.readFile actualPath
      issuesAfter <- TIO.readFile issuesPath
      relationAfter <- if relationExists then TIO.readFile relationPath else pure ""
      pure
        ( writeResult == Right ()
          && relationExists
          && actualAfter == realizedActualCandidateSource preview
          && relationAfter == realizedRelationCandidateSource preview
          && issuesAfter == realizedIssuesCandidateSource preview
        )
  cleanupPublicationFiles
  pure result

testPublicationRollback :: IO Bool
testPublicationRollback = do
  cleanupPublicationFiles
  TIO.writeFile actualPath actualSource
  TIO.writeFile issuesPath issuesSource
  result <- case prepared of
    Left err -> print err >> pure False
    Right preview -> do
      writeResult <- publishIssueRealize
        (pure (Left "synthetic post-admission failure"))
        (writeIntent False "" preview)
      relationExists <- doesFileExist relationPath
      actualAfter <- TIO.readFile actualPath
      issuesAfter <- TIO.readFile issuesPath
      pure $ case writeResult of
        Left (IssueRealizePostAdmissionFailed _ actualSafe relationSafe issuesSafe) ->
          actualSafe && relationSafe && issuesSafe
            && actualAfter == actualSource
            && issuesAfter == issuesSource
            && not relationExists
        _ -> False
  cleanupPublicationFiles
  pure result

writeIntent :: Bool -> Text -> IssueRealizePreview -> IssueRealizeWriteIntent
writeIntent relationExists relationBefore preview = IssueRealizeWriteIntent
  { writeRealizeActualPath = actualPath
  , writeRealizeExpectedActual = actualSource
  , writeRealizeCandidateActual = realizedActualCandidateSource preview
  , writeRealizeRelationPath = relationPath
  , writeRealizeExpectedRelationExists = relationExists
  , writeRealizeExpectedRelation = relationBefore
  , writeRealizeCandidateRelation = realizedRelationCandidateSource preview
  , writeRealizeIssuesPath = issuesPath
  , writeRealizeExpectedIssues = issuesSource
  , writeRealizeCandidateIssues = realizedIssuesCandidateSource preview
  }

actualPath, relationPath, issuesPath :: FilePath
actualPath = "tests/fixtures/test_issue_realize_actual.journal"
relationPath = "tests/fixtures/test_issue_realize_relations.tsv"
issuesPath = "tests/fixtures/test_issue_realize_issues.tsv"

cleanupPublicationFiles :: IO ()
cleanupPublicationFiles = mapM_ cleanup
  [ actualPath, relationPath, issuesPath ]
  where
    cleanup path = do
      removeIfPresent path
      mapM_ (removeIfPresent . (path <>))
        [ ".issue-realize.backup.tmp"
        , ".issue-realize.new.tmp"
        ]

removeIfPresent :: FilePath -> IO ()
removeIfPresent path =
  catch
    (removeTextFile defaultWriterFileSystem path)
    (\(_ :: IOException) -> pure ())

accBank, accBooks :: Account
accBank = mustRight (mkAccount "assets:bank")
accBooks = mustRight (mkAccount "expenses:books")

qty :: Text -> Quantity
qty = mustRight . parseQuantity

jpy :: Commodity
jpy = mustRight (mkCommodity "JPY")

mustIssueId value = mustRight (mkIssueId value)

mustRight :: Show error => Either error value -> value
mustRight = either (error . show) id
