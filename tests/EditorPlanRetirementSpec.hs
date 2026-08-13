{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (Account, mkAccount)
import HKernel.Editor.PlanLifecycle
  ( PlanAddIntent(..)
  , PlanCancelIntent(..)
  , PlanRetirementWriteError(..)
  , PlanSupersedeIntent(..)
  , cancelCandidateCompleteSource
  , cancelRetiredBlock
  , preparePlanCancel
  , preparePlanCancelFromResolvedJournals
  , preparePlanSupersede
  , preparePlanSupersedeFromResolvedJournals
  , supersedeCandidateCompleteSource
  , supersedeReplacementPlanId
  , supersedeRetiredBlock
  )
import HKernel.Editor.TransactionBlock (IntentPosting(..))
import HKernel.Journal (Journal, parseJournal)
import HKernel.Ledger (Transaction)
import HKernel.Money
  ( Commodity
  , Quantity
  , mkCommodity
  , parseQuantity
  )
import HKernel.Plan
  ( PlanRetirement
  , planIdText
  , planRetiredOn
  , planRetirementSuccessor
  , retiredPlanId
  )
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , admitPlanRetirements
  , identifiedPlanId
  , identifiedPlanTransaction
  , parsePlanJournal
  , planJournalTransactions
  )

main :: IO ()
main = do
  let results =
        [ ("cancel preserves Plan transaction and source metadata"
          , testPlanCancelPreservesTransactionAndMetadata)
        , ("cancel rejects completed Plan"
          , testPlanCancelCompletedRejected)
        , ("cancel rejects already retired Plan"
          , testPlanCancelAlreadyRetiredRejected)
        , ("supersede preserves old Plan and appends fresh replacement"
          , testPlanSupersedePreservesOldAndAppendsReplacement)
        , ("supersede reuses Plan Add collision handling"
          , testPlanSupersedeCollisionSuffix)
        , ("supersede rejects completed Plan"
          , testPlanSupersedeCompletedRejected)
        , ("resolved cancel preserves include-shaped root"
          , testResolvedPlanCancelWithInclude)
        , ("resolved supersede preserves include-shaped root"
          , testResolvedPlanSupersedeWithInclude)
        ]
  mapM_ print results
  if all snd results then exitSuccess else exitFailure

planFixture :: Text
planFixture = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  , ""
  , "2023-01-10 existing plan"
  , "  ; plan-id: plan-existing"
  , "  ; recur: monthly"
  , "  ; series: lunch-series"
  , "  ; human note retained verbatim"
  , "  assets:bank  -500 JPY"
  , "  expenses:food  500 JPY"
  , "  ; trailing human note retained verbatim"
  ]

planRootFixture :: Text
planRootFixture = T.unlines
  [ "include accounts.journal"
  , ""
  , "2023-01-10 existing plan"
  , "  ; plan-id: plan-existing"
  , "  ; recur: monthly"
  , "  ; series: lunch-series"
  , "  ; human note retained verbatim"
  , "  assets:bank  -500 JPY"
  , "  expenses:food  500 JPY"
  , "  ; trailing human note retained verbatim"
  ]

accountsFixture :: Text
accountsFixture = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account expenses:food"
  , "  type: Expense"
  , "  commodity: JPY"
  ]

actualFixture :: Text
actualFixture = accountsFixture <> T.unlines
  [ ""
  , "2023-01-01 opening"
  , "  assets:bank  1000 JPY"
  , "  expenses:food  -1000 JPY"
  ]

actualRootFixture :: Text
actualRootFixture = T.unlines
  [ "include accounts.journal"
  , ""
  , "2023-01-01 opening"
  , "  assets:bank  1000 JPY"
  , "  expenses:food  -1000 JPY"
  ]

actualClosedFixture :: Text
actualClosedFixture = actualFixture <> T.unlines
  [ ""
  , "2023-01-02 completed"
  , "  ; plan-id: plan-existing"
  , "  assets:bank  -500 JPY"
  , "  expenses:food  500 JPY"
  ]

retiredPlanFixture :: Text
retiredPlanFixture = T.replace
  "  ; plan-id: plan-existing\n"
  (T.unlines
    [ "  ; plan-id: plan-existing"
    , "  ; cancelled-on: 2023-01-02"
    ])
  planFixture

collisionPlanFixture :: Text
collisionPlanFixture = planFixture <> T.unlines
  [ ""
  , "2023-01-03 reserved replacement identity"
  , "  ; plan-id: plan-2023-01-03-test-dinner"
  , "  assets:bank  -100 JPY"
  , "  expenses:food  100 JPY"
  ]

accBank :: Account
accBank = either (error "bad account") id (mkAccount "assets:bank")

accFood :: Account
accFood = either (error "bad account") id (mkAccount "expenses:food")

qty :: Text -> Quantity
qty = either (error "bad quantity") id . parseQuantity

comm :: Text -> Commodity
comm = either (error "bad commodity") id . mkCommodity

replacementIntent :: PlanAddIntent
replacementIntent = PlanAddIntent
  { addDate = fromGregorian 2023 1 3
  , addDescription = "Test Dinner"
  , addPostings =
      IntentPosting accBank (qty "-300") (Just (comm "JPY"))
      :| [IntentPosting accFood (qty "300") (Just (comm "JPY"))]
  , addRequestedId = Nothing
  , addSeries = Nothing
  }

cancelIntent :: PlanCancelIntent
cancelIntent = PlanCancelIntent
  { cancelPlanId = "plan-existing"
  , cancelOn = fromGregorian 2023 1 2
  }

supersedeIntent :: PlanSupersedeIntent
supersedeIntent = PlanSupersedeIntent
  { supersedePlanId = "plan-existing"
  , supersedeOn = fromGregorian 2023 1 2
  , supersedeReplacement = replacementIntent
  }

testPlanCancelPreservesTransactionAndMetadata :: Bool
testPlanCancelPreservesTransactionAndMetadata =
  case preparePlanCancel planFixture actualFixture cancelIntent of
    Left err -> error (show err)
    Right preview ->
      let candidate = cancelCandidateCompleteSource preview
          oldJournal = mustParsePlan planFixture
          newJournal = mustParsePlan candidate
          oldTransaction = exactlyOneTransaction "plan-existing" oldJournal
          newTransaction = exactlyOneTransaction "plan-existing" newJournal
          retirement = exactlyOneRetirement (mustRetirements newJournal)
          block = cancelRetiredBlock preview
      in oldTransaction == newTransaction
          && "; plan-id: plan-existing\n  ; cancelled-on: 2023-01-02\n"
            `T.isInfixOf` block
          && "; recur: monthly" `T.isInfixOf` block
          && "; series: lunch-series" `T.isInfixOf` block
          && "; human note retained verbatim" `T.isInfixOf` block
          && "; trailing human note retained verbatim" `T.isInfixOf` block
          && planIdText (retiredPlanId retirement) == "plan-existing"
          && planRetiredOn retirement == fromGregorian 2023 1 2
          && planRetirementSuccessor retirement == Nothing

testPlanCancelCompletedRejected :: Bool
testPlanCancelCompletedRejected =
  case preparePlanCancel planFixture actualClosedFixture cancelIntent of
    Left (RetirePlanAlreadyCompleted _ :| []) -> True
    _ -> False

testPlanCancelAlreadyRetiredRejected :: Bool
testPlanCancelAlreadyRetiredRejected =
  case preparePlanCancel retiredPlanFixture actualFixture cancelIntent of
    Left (RetirePlanAlreadyRetired _ :| []) -> True
    _ -> False

testPlanSupersedePreservesOldAndAppendsReplacement :: Bool
testPlanSupersedePreservesOldAndAppendsReplacement =
  case preparePlanSupersede planFixture actualFixture supersedeIntent of
    Left err -> error (show err)
    Right preview ->
      let candidate = supersedeCandidateCompleteSource preview
          oldJournal = mustParsePlan planFixture
          newJournal = mustParsePlan candidate
          oldTransaction = exactlyOneTransaction "plan-existing" oldJournal
          retainedTransaction = exactlyOneTransaction "plan-existing" newJournal
          successorId = supersedeReplacementPlanId preview
          successorTransaction = exactlyOneTransaction
            (planIdText successorId) newJournal
          retirement = exactlyOneRetirement (mustRetirements newJournal)
          block = supersedeRetiredBlock preview
      in oldTransaction == retainedTransaction
          && length (planJournalTransactions newJournal)
            == length (planJournalTransactions oldJournal) + 1
          && planIdText successorId == "plan-2023-01-03-test-dinner"
          && successorTransaction /= retainedTransaction
          && "; superseded-on: 2023-01-02" `T.isInfixOf` block
          && ("; superseded-by: " <> planIdText successorId)
            `T.isInfixOf` block
          && "; recur: monthly" `T.isInfixOf` block
          && "; trailing human note retained verbatim" `T.isInfixOf` block
          && planIdText (retiredPlanId retirement) == "plan-existing"
          && planRetirementSuccessor retirement == Just successorId

testPlanSupersedeCollisionSuffix :: Bool
testPlanSupersedeCollisionSuffix =
  case preparePlanSupersede collisionPlanFixture actualFixture supersedeIntent of
    Left err -> error (show err)
    Right preview ->
      planIdText (supersedeReplacementPlanId preview)
        == "plan-2023-01-03-test-dinner-02"

testPlanSupersedeCompletedRejected :: Bool
testPlanSupersedeCompletedRejected =
  case preparePlanSupersede planFixture actualClosedFixture supersedeIntent of
    Left (RetirePlanAlreadyCompleted _ :| []) -> True
    _ -> False

testResolvedPlanCancelWithInclude :: Bool
testResolvedPlanCancelWithInclude =
  case preparePlanCancelFromResolvedJournals
      resolvedPlanJournal
      resolvedActualJournal
      planRootFixture
      actualRootFixture
      cancelIntent of
    Left err -> error (show err)
    Right preview ->
      let candidate = cancelCandidateCompleteSource preview
      in "include accounts.journal" `T.isPrefixOf` candidate
          && "; cancelled-on: 2023-01-02" `T.isInfixOf` candidate
          && "; recur: monthly" `T.isInfixOf` candidate

testResolvedPlanSupersedeWithInclude :: Bool
testResolvedPlanSupersedeWithInclude =
  case preparePlanSupersedeFromResolvedJournals
      resolvedPlanJournal
      resolvedActualJournal
      planRootFixture
      actualRootFixture
      supersedeIntent of
    Left err -> error (show err)
    Right preview ->
      let candidate = supersedeCandidateCompleteSource preview
          successorId = supersedeReplacementPlanId preview
      in "include accounts.journal" `T.isPrefixOf` candidate
          && "; superseded-on: 2023-01-02" `T.isInfixOf` candidate
          && ("; superseded-by: " <> planIdText successorId)
            `T.isInfixOf` candidate
          && "2023-01-03 Test Dinner" `T.isInfixOf` candidate

resolvedPlanJournal :: Journal
resolvedPlanJournal = mustParseJournal planFixture

resolvedActualJournal :: Journal
resolvedActualJournal = mustParseJournal actualFixture

mustParseJournal :: Text -> Journal
mustParseJournal = either (error . show) id . parseJournal

mustParsePlan text = either (error . show) id (parsePlanJournal text)

mustRetirements journal = either (error . show) id (admitPlanRetirements journal)

exactlyOneTransaction rawPlanId journal =
  case [ identifiedPlanTransaction identified
       | identified <- planJournalTransactions journal
       , planIdText (identifiedPlanId identified) == rawPlanId
       ] of
    [transaction] -> transaction
    values -> error ("expected one transaction, got " ++ show (length values))

exactlyOneRetirement :: [PlanRetirement] -> PlanRetirement
exactlyOneRetirement [retirement] = retirement
exactlyOneRetirement values =
  error ("expected one retirement, got " ++ show (length values))
