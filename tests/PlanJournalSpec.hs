{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Journal
  ( journalMetadataKey
  , journalMetadataValue
  , journalTransactionSourceMetadata
  , journalTransactions
  , parseJournal
  )
import HKernel.Ledger (transactionPostings)
import HKernel.Plan
  ( committedPlanId
  , mkPlanId
  , planIdText
  , planRetiredOn
  , planRetirementSuccessor
  , retiredPlanId
  )
import HKernel.Plan.Journal
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeWholePlanTransactions
  retainCanonicalPlanSourceEvidence
  characterizeResolvedJournalAdmission
  rejectResolvedJournalTransactionDrift
  rejectResolvedJournalEqualCountTransactionDrift
  rejectMissingPlanIdentity
  rejectDuplicatePlanMetadata
  rejectInvalidPlanIdentity
  rejectDuplicatePlanIdentity
  retainAccountingValidation
  characterizePlanRetirementMetadata
  rejectPartialSupersessionMetadata
  rejectConflictingRetirementMetadata
  rejectUnknownSupersessionTarget
  rejectSelfSupersession
  rejectSupersessionCycle
  rejectDuplicateLifecycleMetadata
  rejectInvalidLifecycleDate
  classifyIncomingAndOutgoingPlans
  preserveWholeSourceOrderedTransactions
  admitMultipleOutgoingPostingCoordinates
  rejectUnsupportedRoleFlows
  accumulateClassificationFailures
  projectBinaryOutgoingPlans
  rejectMultiPostingReportProjection

characterizeWholePlanTransactions :: IO ()
characterizeWholePlanTransactions = do
  let admitted = mustRight (parsePlanJournal planJournal)
      identified = planJournalTransactions admitted

  assertEqual "Plan identities preserve source order"
    ["plan-wifi", "plan-shared"]
    (map (planIdText . identifiedPlanId) identified)
  assertEqual "the whole validated transaction is retained"
    (journalTransactions (planJournalValue admitted))
    (map identifiedPlanTransaction identified)
  assertEqual "a multi-posting Plan is not flattened at source admission"
    [2, 3]
    (map (NonEmpty.length . transactionPostings . identifiedPlanTransaction)
      identified)

retainCanonicalPlanSourceEvidence :: IO ()
retainCanonicalPlanSourceEvidence = do
  let admitted = mustRight (parsePlanJournal planJournal)
  assertEqual
    "PlanJournal retains canonical source metadata without assigning its meaning"
    (Just
      [ ("plan-id", "plan-wifi")
      , ("note", "unrelated metadata remains unrelated")
      ])
    (sourceMetadataPairs "plan-wifi" admitted)

characterizeResolvedJournalAdmission :: IO ()
characterizeResolvedJournalAdmission = do
  let resolvedJournal = mustRight (parseJournal resolvedAccountingJournal)
      admitted = mustRight
        (admitPlanJournalFromResolvedJournal resolvedJournal resolvedPlanRoot)
      direct = mustRight (parsePlanJournal resolvedAccountingJournal)

  assertEqual
    "resolved Account includes preserve the complete Plan semantic projection"
    direct
    admitted
  assertEqual
    "resolved admission retains the same canonical metadata values"
    (sourceMetadataPairs "plan-wifi" direct)
    (sourceMetadataPairs "plan-wifi" admitted)

rejectResolvedJournalTransactionDrift :: IO ()
rejectResolvedJournalTransactionDrift =
  assertLeftSatisfies
    "resolved admission rejects transactions not represented by the Plan root"
    (any isAlignmentMismatch . NonEmpty.toList)
    (admitPlanJournalFromResolvedJournal driftedJournal resolvedPlanRoot)
  where
    driftedJournal = mustRight (parseJournal driftedResolvedAccountingJournal)
    isAlignmentMismatch err = case err of
      PlanJournalTransactionMetadataAlignmentMismatch 2 1 -> True
      _ -> False

rejectResolvedJournalEqualCountTransactionDrift :: IO ()
rejectResolvedJournalEqualCountTransactionDrift =
  assertLeftSatisfies
    "resolved admission rejects equal-count source evidence for a different Plan transaction"
    (any isSourceMismatch . NonEmpty.toList)
    (admitPlanJournalFromResolvedJournal
      resolvedJournal
      equalCountDifferentPlanRoot)
  where
    resolvedJournal = mustRight (parseJournal resolvedAccountingJournal)
    isSourceMismatch err = case err of
      PlanJournalTransactionSourceAlignmentMismatch 1 -> True
      _ -> False

rejectMissingPlanIdentity :: IO ()
rejectMissingPlanIdentity =
  assertLeftSatisfies "every Plan transaction requires plan-id"
    (any isMissing . NonEmpty.toList)
    (parsePlanJournal (declarations <> T.unlines
      [ "2026-08-08 Missing identity"
      , "    expenses:food  200 JPY"
      , "    assets:cash"
      ]))
  where
    isMissing err = case err of
      MissingPlanId _ -> True
      _ -> False

rejectDuplicatePlanMetadata :: IO ()
rejectDuplicatePlanMetadata =
  assertLeftSatisfies "duplicate plan-id metadata is rejected"
    (any isDuplicate . NonEmpty.toList)
    (parsePlanJournal (declarations <> T.unlines
      [ "2026-08-08 Duplicate metadata"
      , "    ; plan-id: plan-first"
      , "    ; plan-id: plan-second"
      , "    expenses:food  200 JPY"
      , "    assets:cash"
      ]))
  where
    isDuplicate err = case err of
      DuplicatePlanJournalMetadataKey _ "plan-id" -> True
      _ -> False

rejectInvalidPlanIdentity :: IO ()
rejectInvalidPlanIdentity =
  assertLeftSatisfies "invalid Plan identity is rejected"
    (any isInvalid . NonEmpty.toList)
    (parsePlanJournal (declarations <> T.unlines
      [ "2026-08-08 Invalid identity"
      , "    ; plan-id: plan with spaces"
      , "    expenses:food  200 JPY"
      , "    assets:cash"
      ]))
  where
    isInvalid err = case err of
      InvalidPlanJournalPlanId _ _ -> True
      _ -> False

rejectDuplicatePlanIdentity :: IO ()
rejectDuplicatePlanIdentity =
  assertLeftSatisfies "one Plan identity cannot name two transactions"
    (any isDuplicate . NonEmpty.toList)
    (parsePlanJournal (declarations <> T.unlines
      [ "2026-08-08 First definition"
      , "    ; plan-id: plan-duplicate"
      , "    expenses:food  200 JPY"
      , "    assets:cash"
      , ""
      , "2026-08-09 Second definition"
      , "    ; plan-id: plan-duplicate"
      , "    expenses:food  300 JPY"
      , "    assets:cash"
      ]))
  where
    isDuplicate err = case err of
      DuplicatePlanJournalPlanId _ lines' -> NonEmpty.length lines' == 2
      _ -> False

retainAccountingValidation :: IO ()
retainAccountingValidation =
  assertLeftSatisfies "Plan Journal inherits accounting validation"
    (any isSyntax . NonEmpty.toList)
    (parsePlanJournal (declarations <> T.unlines
      [ "2026-08-08 Unbalanced"
      , "    ; plan-id: plan-unbalanced"
      , "    expenses:food  200 JPY"
      , "    assets:cash  -100 JPY"
      ]))
  where
    isSyntax err = case err of
      PlanJournalSyntaxError _ -> True
      _ -> False

characterizePlanRetirementMetadata :: IO ()
characterizePlanRetirementMetadata = do
  let source = mustParse lifecyclePlanJournal
      retirements = mustRight (admitPlanRetirements source)

  assertEqual
    "Plan lifecycle keeps cancellation and supersession as typed evidence"
    [ ("plan-old", fromGregorian 2026 8 13, Just "plan-new")
    , ("plan-cancelled", fromGregorian 2026 8 12, Nothing)
    ]
    [ ( planIdText (retiredPlanId retirement)
      , planRetiredOn retirement
      , fmap planIdText (planRetirementSuccessor retirement)
      )
    | retirement <- retirements
    ]
  assertEqual
    "retirement is observation-time evidence rather than destructive Plan removal"
    ["plan-cancelled"]
    (map planIdText (Set.toAscList
      (retiredPlanIdsAt (fromGregorian 2026 8 12) retirements)))
  assertEqual
    "superseded Plan retires on its declared day"
    ["plan-cancelled", "plan-old"]
    (map planIdText (Set.toAscList
      (retiredPlanIdsAt (fromGregorian 2026 8 13) retirements)))
  assertEqual
    "retirement admission preserves every original Plan transaction"
    ["plan-old", "plan-new", "plan-cancelled"]
    (map (planIdText . identifiedPlanId) (planJournalTransactions source))

rejectPartialSupersessionMetadata :: IO ()
rejectPartialSupersessionMetadata =
  assertLeftSatisfies "superseded-on requires superseded-by"
    (any isMissingSuccessor . NonEmpty.toList)
    (admitPlanRetirements (mustParse missingSuccessorPlanJournal))
  where
    isMissingSuccessor err = case err of
      SupersededOnMissingSuccessor _ _ -> True
      _ -> False

rejectConflictingRetirementMetadata :: IO ()
rejectConflictingRetirementMetadata =
  assertLeftSatisfies "cancellation cannot coexist with supersession"
    (any isConflict . NonEmpty.toList)
    (admitPlanRetirements (mustParse conflictingRetirementPlanJournal))
  where
    isConflict err = case err of
      CancellationConflictsWithSupersession _ _ -> True
      _ -> False

rejectUnknownSupersessionTarget :: IO ()
rejectUnknownSupersessionTarget =
  assertLeftSatisfies "supersession successor must name an admitted Plan"
    (any isUnknown . NonEmpty.toList)
    (admitPlanRetirements (mustParse unknownSuccessorPlanJournal))
  where
    isUnknown err = case err of
      UnknownPlanSuccessor old successor ->
        planIdText old == "plan-old" && planIdText successor == "plan-missing"
      _ -> False

rejectSelfSupersession :: IO ()
rejectSelfSupersession =
  assertLeftSatisfies "a Plan cannot supersede itself"
    (any isSelf . NonEmpty.toList)
    (admitPlanRetirements (mustParse selfSupersessionPlanJournal))
  where
    isSelf err = case err of
      InvalidPlanRetirement _ _ -> True
      _ -> False

rejectSupersessionCycle :: IO ()
rejectSupersessionCycle =
  assertLeftSatisfies "supersession graph cannot contain a cycle"
    (any isCycle . NonEmpty.toList)
    (admitPlanRetirements (mustParse cyclicSupersessionPlanJournal))
  where
    isCycle err = case err of
      SupersessionCycle _ -> True
      _ -> False

rejectDuplicateLifecycleMetadata :: IO ()
rejectDuplicateLifecycleMetadata =
  assertLeftSatisfies "duplicate lifecycle metadata fails closed"
    (any isDuplicate . NonEmpty.toList)
    (admitPlanRetirements (mustParse duplicateLifecyclePlanJournal))
  where
    isDuplicate err = case err of
      DuplicatePlanLifecycleMetadataKey _ "cancelled-on" -> True
      _ -> False

rejectInvalidLifecycleDate :: IO ()
rejectInvalidLifecycleDate =
  assertLeftSatisfies "lifecycle date must be an explicit valid day"
    (any isInvalidDate . NonEmpty.toList)
    (admitPlanRetirements (mustParse invalidLifecycleDatePlanJournal))
  where
    isInvalidDate err = case err of
      InvalidPlanLifecycleDate _ "cancelled-on" -> True
      _ -> False

classifyIncomingAndOutgoingPlans :: IO ()
classifyIncomingAndOutgoingPlans = do
  let classified = mustClassify supportedPlanJournal

  assertEqual "classifies source-ordered incoming and outgoing Plans"
    ["incoming:plan-income", "outgoing:plan-shared", "outgoing:plan-card"]
    (map classificationLabel classified)
  assertEqual "publishes incoming Plans"
    ["plan-income"]
    (map (planIdText . identifiedPlanId)
      (classifiedIncomingPlanTransactions classified))
  assertEqual "publishes outgoing Plans"
    ["plan-shared", "plan-card"]
    (map (planIdText . identifiedPlanId)
      (classifiedOutgoingPlanTransactions classified))

preserveWholeSourceOrderedTransactions :: IO ()
preserveWholeSourceOrderedTransactions = do
  let source = mustParse supportedPlanJournal
      classified = mustRight (classifyPlanJournal source)

  assertEqual "classification does not replace or reorder transactions"
    (planJournalTransactions source)
    (map classifiedValue classified)

admitMultipleOutgoingPostingCoordinates :: IO ()
admitMultipleOutgoingPostingCoordinates =
  assertEqual "multiple Asset sources remain one outgoing whole transaction"
    ["plan-multiple-assets"]
    (map (planIdText . identifiedPlanId)
      (classifiedOutgoingPlanTransactions
        (mustClassify multipleFundingPlanJournal)))

rejectUnsupportedRoleFlows :: IO ()
rejectUnsupportedRoleFlows =
  assertLeftSatisfies "Asset transfers are not mislabeled as household Plans"
    ((== ["plan-transfer"]) . unsupportedPlanIds)
    (classifyPlanJournal (mustParse assetTransferPlanJournal))

accumulateClassificationFailures :: IO ()
accumulateClassificationFailures =
  assertLeftSatisfies "classification reports every unsupported Plan"
    ((== ["plan-zero", "plan-equity"]) . unsupportedPlanIds)
    (classifyPlanJournal (mustParse unsupportedPlansJournal))

projectBinaryOutgoingPlans :: IO ()
projectBinaryOutgoingPlans = do
  let source = mustParse binaryProjectionPlanJournal
      classified = mustRight (classifyPlanJournal source)
      outgoing = classifiedOutgoingPlanTransactions classified
      projected = mustRight (projectCommittedOutgoingPlans source classified)

  assertEqual "binary outgoing Plans project in source order"
    ["plan-food", "plan-card"]
    (map
      (planIdText . committedPlanId . projectedCommittedOutgoingPlan)
      projected)
  assertEqual "report projection retains every complete source transaction"
    outgoing
    (map projectedPlanSource projected)

rejectMultiPostingReportProjection :: IO ()
rejectMultiPostingReportProjection = do
  let source = mustParse supportedPlanJournal
      classified = mustRight (classifyPlanJournal source)

  assertLeftSatisfies
    "multi-posting outgoing Plans remain valid source but fail narrow projection"
    ((== ["plan-shared"]) . projectionErrorPlanIds)
    (projectCommittedOutgoingPlans source classified)

sourceMetadataPairs :: T.Text -> PlanJournal -> Maybe [(T.Text, T.Text)]
sourceMetadataPairs rawPlanId planJournalValue' = do
  source <- planJournalTransactionSourceFor
    (mustRight (mkPlanId rawPlanId))
    planJournalValue'
  pure
    [ (journalMetadataKey entry, journalMetadataValue entry)
    | entry <- journalTransactionSourceMetadata source
    ]

unsupportedPlanIds
  :: NonEmpty.NonEmpty PlanClassificationError
  -> [T.Text]
unsupportedPlanIds = map planId . NonEmpty.toList
  where
    planId (UnsupportedPlanRoleFlow value) = planIdText value

projectionErrorPlanIds
  :: NonEmpty.NonEmpty PlanReportProjectionError
  -> [T.Text]
projectionErrorPlanIds = map planId . NonEmpty.toList
  where
    planId (PlanReportProjectionRequiresBinaryOutgoing value) = planIdText value

classificationLabel :: ClassifiedPlanTransaction -> T.Text
classificationLabel classified = case classified of
  IncomingPlanTransaction plan ->
    "incoming:" <> planIdText (identifiedPlanId plan)
  OutgoingPlanTransaction plan ->
    "outgoing:" <> planIdText (identifiedPlanId plan)

classifiedValue :: ClassifiedPlanTransaction -> IdentifiedPlanTransaction
classifiedValue classified = case classified of
  IncomingPlanTransaction plan -> plan
  OutgoingPlanTransaction plan -> plan

mustClassify :: T.Text -> [ClassifiedPlanTransaction]
mustClassify = mustRight . classifyPlanJournal . mustParse

mustParse :: T.Text -> PlanJournal
mustParse = mustRight . parsePlanJournal

planJournal :: T.Text
planJournal = declarations <> T.unlines
  [ "2026-08-08 Wi-Fi payment"
  , "    ; plan-id: plan-wifi"
  , "    ; note: unrelated metadata remains unrelated"
  , "    expenses:food  200 JPY"
  , "    assets:cash"
  , ""
  , "2026-08-12 Shared purchase"
  , "    ; plan-id: plan-shared"
  , "    expenses:food   600 JPY"
  , "    expenses:books  400 JPY"
  , "    assets:cash    -1000 JPY"
  ]

lifecyclePlanJournal :: T.Text
lifecyclePlanJournal = declarations <> T.unlines
  [ "2026-08-20 Original commitment"
  , "    ; plan-id: plan-old"
  , "    ; superseded-on: 2026-08-13"
  , "    ; superseded-by: plan-new"
  , "    expenses:food  500 JPY"
  , "    assets:cash   -500 JPY"
  , ""
  , "2026-08-20 Replacement commitment"
  , "    ; plan-id: plan-new"
  , "    expenses:food  300 JPY"
  , "    assets:cash   -300 JPY"
  , ""
  , "2026-08-18 Cancelled commitment"
  , "    ; plan-id: plan-cancelled"
  , "    ; cancelled-on: 2026-08-12"
  , "    expenses:books  200 JPY"
  , "    assets:cash    -200 JPY"
  ]

missingSuccessorPlanJournal :: T.Text
missingSuccessorPlanJournal = declarations <> T.unlines
  [ "2026-08-20 Original commitment"
  , "    ; plan-id: plan-old"
  , "    ; superseded-on: 2026-08-13"
  , "    expenses:food  500 JPY"
  , "    assets:cash   -500 JPY"
  ]

conflictingRetirementPlanJournal :: T.Text
conflictingRetirementPlanJournal = declarations <> T.unlines
  [ "2026-08-20 Original commitment"
  , "    ; plan-id: plan-old"
  , "    ; cancelled-on: 2026-08-13"
  , "    ; superseded-on: 2026-08-13"
  , "    ; superseded-by: plan-new"
  , "    expenses:food  500 JPY"
  , "    assets:cash   -500 JPY"
  , ""
  , "2026-08-20 Replacement"
  , "    ; plan-id: plan-new"
  , "    expenses:food  300 JPY"
  , "    assets:cash   -300 JPY"
  ]

unknownSuccessorPlanJournal :: T.Text
unknownSuccessorPlanJournal = declarations <> T.unlines
  [ "2026-08-20 Original commitment"
  , "    ; plan-id: plan-old"
  , "    ; superseded-on: 2026-08-13"
  , "    ; superseded-by: plan-missing"
  , "    expenses:food  500 JPY"
  , "    assets:cash   -500 JPY"
  ]

selfSupersessionPlanJournal :: T.Text
selfSupersessionPlanJournal = declarations <> T.unlines
  [ "2026-08-20 Original commitment"
  , "    ; plan-id: plan-old"
  , "    ; superseded-on: 2026-08-13"
  , "    ; superseded-by: plan-old"
  , "    expenses:food  500 JPY"
  , "    assets:cash   -500 JPY"
  ]

cyclicSupersessionPlanJournal :: T.Text
cyclicSupersessionPlanJournal = declarations <> T.unlines
  [ "2026-08-20 First commitment"
  , "    ; plan-id: plan-first"
  , "    ; superseded-on: 2026-08-13"
  , "    ; superseded-by: plan-second"
  , "    expenses:food  500 JPY"
  , "    assets:cash   -500 JPY"
  , ""
  , "2026-08-21 Second commitment"
  , "    ; plan-id: plan-second"
  , "    ; superseded-on: 2026-08-14"
  , "    ; superseded-by: plan-first"
  , "    expenses:food  300 JPY"
  , "    assets:cash   -300 JPY"
  ]

duplicateLifecyclePlanJournal :: T.Text
duplicateLifecyclePlanJournal = declarations <> T.unlines
  [ "2026-08-20 Commitment"
  , "    ; plan-id: plan-old"
  , "    ; cancelled-on: 2026-08-13"
  , "    ; cancelled-on: 2026-08-14"
  , "    expenses:food  500 JPY"
  , "    assets:cash   -500 JPY"
  ]

invalidLifecycleDatePlanJournal :: T.Text
invalidLifecycleDatePlanJournal = declarations <> T.unlines
  [ "2026-08-20 Commitment"
  , "    ; plan-id: plan-old"
  , "    ; cancelled-on: 2026-02-30"
  , "    expenses:food  500 JPY"
  , "    assets:cash   -500 JPY"
  ]

resolvedPlanRoot :: T.Text
resolvedPlanRoot = T.unlines
  [ "include accounts.journal"
  , ""
  , "2026-08-08 Wi-Fi payment"
  , "    ; plan-id: plan-wifi"
  , "    ; note: unrelated metadata remains unrelated"
  , "    expenses:food  200 JPY"
  , "    assets:cash"
  ]

equalCountDifferentPlanRoot :: T.Text
equalCountDifferentPlanRoot = T.unlines
  [ "include accounts.journal"
  , ""
  , "2026-08-08 Different payment"
  , "    ; plan-id: plan-wrong-source"
  , "    expenses:food  201 JPY"
  , "    assets:cash"
  ]

resolvedAccountingJournal :: T.Text
resolvedAccountingJournal = declarations <> T.unlines
  [ "2026-08-08 Wi-Fi payment"
  , "    ; plan-id: plan-wifi"
  , "    ; note: unrelated metadata remains unrelated"
  , "    expenses:food  200 JPY"
  , "    assets:cash"
  ]

driftedResolvedAccountingJournal :: T.Text
driftedResolvedAccountingJournal = resolvedAccountingJournal <> T.unlines
  [ ""
  , "2026-08-09 Included transaction must not hide here"
  , "    expenses:food  100 JPY"
  , "    assets:cash"
  ]

supportedPlanJournal :: T.Text
supportedPlanJournal = declarations <> T.unlines
  [ "2026-08-15 Pension income"
  , "    ; plan-id: plan-income"
  , "    income:pension  -2000 JPY"
  , "    assets:bank      2000 JPY"
  , ""
  , "2026-08-12 Shared purchase"
  , "    ; plan-id: plan-shared"
  , "    expenses:food    600 JPY"
  , "    expenses:books   400 JPY"
  , "    assets:cash    -1000 JPY"
  , ""
  , "2026-08-20 Card payment"
  , "    ; plan-id: plan-card"
  , "    liabilities:card   500 JPY"
  , "    assets:bank       -500 JPY"
  ]

binaryProjectionPlanJournal :: T.Text
binaryProjectionPlanJournal = declarations <> T.unlines
  [ "2026-08-15 Pension income"
  , "    ; plan-id: plan-income"
  , "    income:pension  -2000 JPY"
  , "    assets:bank      2000 JPY"
  , ""
  , "2026-08-18 Food payment"
  , "    ; plan-id: plan-food"
  , "    expenses:food   300 JPY"
  , "    assets:cash    -300 JPY"
  , ""
  , "2026-08-20 Card payment"
  , "    ; plan-id: plan-card"
  , "    liabilities:card   500 JPY"
  , "    assets:bank       -500 JPY"
  ]

multipleFundingPlanJournal :: T.Text
multipleFundingPlanJournal = declarations <> T.unlines
  [ "2026-08-18 Multiple funding accounts"
  , "    ; plan-id: plan-multiple-assets"
  , "    expenses:food  1000 JPY"
  , "    assets:cash    -400 JPY"
  , "    assets:bank    -600 JPY"
  ]

assetTransferPlanJournal :: T.Text
assetTransferPlanJournal = declarations <> T.unlines
  [ "2026-08-19 Asset transfer"
  , "    ; plan-id: plan-transfer"
  , "    assets:cash  -100 JPY"
  , "    assets:bank   100 JPY"
  ]

unsupportedPlansJournal :: T.Text
unsupportedPlansJournal = declarations <> T.unlines
  [ "2026-08-21 Zero coordinate"
  , "    ; plan-id: plan-zero"
  , "    expenses:food   200 JPY"
  , "    expenses:books    0 JPY"
  , "    assets:cash     -200 JPY"
  , ""
  , "2026-08-23 Equity movement"
  , "    ; plan-id: plan-equity"
  , "    equity:opening  -100 JPY"
  , "    assets:bank      100 JPY"
  ]

declarations :: T.Text
declarations = T.unlines
  [ "account assets:cash"
  , "    type: asset"
  , "    commodity: JPY"
  , "account assets:bank"
  , "    type: asset"
  , "    commodity: JPY"
  , "account income:pension"
  , "    type: income"
  , "    commodity: JPY"
  , "account expenses:food"
  , "    type: expense"
  , "    commodity: JPY"
  , "account expenses:books"
  , "    type: expense"
  , "    commodity: JPY"
  , "account liabilities:card"
  , "    type: liability"
  , "    commodity: JPY"
  , "account equity:opening"
  , "    type: equity"
  , "    commodity: JPY"
  ]

assertLeftSatisfies
  :: (Show error, Show value)
  => String
  -> (NonEmpty.NonEmpty error -> Bool)
  -> Either (NonEmpty.NonEmpty error) value
  -> IO ()
assertLeftSatisfies label predicate result = case result of
  Left errors
    | predicate errors -> putStrLn ("  [PASS] " ++ label)
    | otherwise -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn ("    errors did not satisfy predicate: " ++ show errors)
        exitFailure
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly accepted: " ++ show value)
    exitFailure
