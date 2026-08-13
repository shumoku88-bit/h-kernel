{-# LANGUAGE OverloadedStrings #-}

-- | Explicit retirement evidence for admitted Plans.
--
-- Plan Journal owns the durable Plan identities and parser-produced source
-- metadata. This module assigns meaning only to the narrow lifecycle keys that
-- retire a Plan without rewriting its original transaction:
--
-- * @cancelled-on@ retires a Plan without a successor;
-- * @superseded-on@ together with @superseded-by@ retires a Plan in favour of
--   another admitted Plan identity.
--
-- Unrelated metadata remains unrelated. Lifecycle resolution is collection-wide
-- so unknown successors and supersession cycles fail closed.
module HKernel.Plan.Lifecycle
  ( PlanLifecycleError(..)
  , planLifecycleErrorLine
  , admitPlanRetirements
  , planRetiredAt
  , retiredPlanIdsAt
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)

import HKernel.Journal
  ( JournalMetadata
  , journalMetadataKey
  , journalMetadataLine
  , journalMetadataValue
  , journalTransactionSourceMetadata
  )
import HKernel.Plan
  ( PlanId
  , PlanIdError
  , PlanRetirement
  , PlanRetirementError
  , declarePlanCancellation
  , declarePlanSupersession
  , mkPlanId
  , planRetiredOn
  , planRetirementSuccessor
  , retiredPlanId
  )
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , PlanJournal
  , identifiedPlanId
  , planJournalTransactionSourceFor
  , planJournalTransactions
  )

-- | Failure to admit Plan lifecycle meaning from parser-owned Plan metadata.
data PlanLifecycleError
  = MissingPlanLifecycleSource PlanId
  | DuplicatePlanLifecycleMetadataKey Int Text
  | InvalidPlanLifecycleDate Int Text
  | InvalidSupersessionPlanId Int PlanIdError
  | InvalidPlanRetirement Int PlanRetirementError
  | CancellationConflictsWithSupersession Int PlanId
  | SupersededOnMissingSuccessor Int PlanId
  | SupersededByMissingDate Int PlanId
  | UnknownPlanSuccessor PlanId PlanId
  | SupersessionCycle PlanId
  deriving (Eq, Show)

planLifecycleErrorLine :: PlanLifecycleError -> Int
planLifecycleErrorLine err = case err of
  MissingPlanLifecycleSource _ -> 0
  DuplicatePlanLifecycleMetadataKey lineNumber _ -> lineNumber
  InvalidPlanLifecycleDate lineNumber _ -> lineNumber
  InvalidSupersessionPlanId lineNumber _ -> lineNumber
  InvalidPlanRetirement lineNumber _ -> lineNumber
  CancellationConflictsWithSupersession lineNumber _ -> lineNumber
  SupersededOnMissingSuccessor lineNumber _ -> lineNumber
  SupersededByMissingDate lineNumber _ -> lineNumber
  UnknownPlanSuccessor _ _ -> 0
  SupersessionCycle _ -> 0

-- | Admit cancellation/supersession evidence for every Plan in one admitted
-- Plan Journal.
--
-- Source order is retained in the result. The old Plan transaction is never
-- replaced or mutated by this projection.
admitPlanRetirements
  :: PlanJournal
  -> Either (NonEmpty PlanLifecycleError) [PlanRetirement]
admitPlanRetirements planJournal =
  case NonEmpty.nonEmpty allErrors of
    Just errors -> Left errors
    Nothing -> Right retirements
  where
    identifiedPlans = planJournalTransactions planJournal
    knownPlanIds = Set.fromList (map identifiedPlanId identifiedPlans)
    (localFailures, localValues) = partitionEithers
      (map (retirementForPlan planJournal) identifiedPlans)
    localErrors = concatMap NonEmpty.toList localFailures
    retirements = [retirement | Just retirement <- localValues]
    unknownTargetErrors =
      [ UnknownPlanSuccessor (retiredPlanId retirement) successor
      | retirement <- retirements
      , Just successor <- [planRetirementSuccessor retirement]
      , successor `Set.notMember` knownPlanIds
      ]
    successorByPlan = Map.fromList
      [ (retiredPlanId retirement, successor)
      | retirement <- retirements
      , Just successor <- [planRetirementSuccessor retirement]
      , successor `Set.member` knownPlanIds
      ]
    cycleErrors =
      [ SupersessionCycle start
      | start <- Map.keys successorByPlan
      , supersessionCycleFrom successorByPlan start
      ]
    allErrors = localErrors ++ unknownTargetErrors ++ cycleErrors

-- | Whether retirement evidence is effective for one observation date.
planRetiredAt :: Day -> PlanRetirement -> Bool
planRetiredAt observation retirement = planRetiredOn retirement <= observation

retiredPlanIdsAt :: Day -> [PlanRetirement] -> Set.Set PlanId
retiredPlanIdsAt observation = Set.fromList
  . map retiredPlanId
  . filter (planRetiredAt observation)

retirementForPlan
  :: PlanJournal
  -> IdentifiedPlanTransaction
  -> Either (NonEmpty PlanLifecycleError) (Maybe PlanRetirement)
retirementForPlan planJournal identified = do
  source <- maybe
    (Left (MissingPlanLifecycleSource planId NonEmpty.:| []))
    Right
    (planJournalTransactionSourceFor planId planJournal)
  let metadata = journalTransactionSourceMetadata source
      (cancelErrors, maybeCancelledOn) = singleMetadata "cancelled-on" metadata
      (supersededOnErrors, maybeSupersededOn) =
        singleMetadata "superseded-on" metadata
      (supersededByErrors, maybeSupersededBy) =
        singleMetadata "superseded-by" metadata
      duplicateErrors =
        cancelErrors ++ supersededOnErrors ++ supersededByErrors
  case NonEmpty.nonEmpty duplicateErrors of
    Just errors -> Left errors
    Nothing ->
      buildRetirement planId maybeCancelledOn maybeSupersededOn maybeSupersededBy
  where
    planId = identifiedPlanId identified

buildRetirement
  :: PlanId
  -> Maybe JournalMetadata
  -> Maybe JournalMetadata
  -> Maybe JournalMetadata
  -> Either (NonEmpty PlanLifecycleError) (Maybe PlanRetirement)
buildRetirement planId maybeCancelled maybeSupersededOn maybeSupersededBy =
  case (maybeCancelled, maybeSupersededOn, maybeSupersededBy) of
    (Nothing, Nothing, Nothing) -> Right Nothing
    (Just cancelledEntry, Nothing, Nothing) -> do
      cancelledOn <- parseLifecycleDay "cancelled-on" cancelledEntry
      Right (Just (declarePlanCancellation planId cancelledOn))
    (Nothing, Just supersededOnEntry, Just supersededByEntry) -> do
      supersededOn <- parseLifecycleDay "superseded-on" supersededOnEntry
      successor <- mapLeft
        (\err -> InvalidSupersessionPlanId
          (journalMetadataLine supersededByEntry) err NonEmpty.:| [])
        (mkPlanId (journalMetadataValue supersededByEntry))
      retirement <- mapLeft
        (\err -> InvalidPlanRetirement
          (journalMetadataLine supersededByEntry) err NonEmpty.:| [])
        (declarePlanSupersession planId supersededOn successor)
      Right (Just retirement)
    (Just entry, _, _) -> Left
      (CancellationConflictsWithSupersession
        (journalMetadataLine entry) planId NonEmpty.:| [])
    (Nothing, Just entry, Nothing) -> Left
      (SupersededOnMissingSuccessor
        (journalMetadataLine entry) planId NonEmpty.:| [])
    (Nothing, Nothing, Just entry) -> Left
      (SupersededByMissingDate
        (journalMetadataLine entry) planId NonEmpty.:| [])

singleMetadata
  :: Text
  -> [JournalMetadata]
  -> ([PlanLifecycleError], Maybe JournalMetadata)
singleMetadata key metadata = case filter ((== key) . journalMetadataKey) metadata of
  [] -> ([], Nothing)
  [entry] -> ([], Just entry)
  firstEntry : duplicates ->
    ( [ DuplicatePlanLifecycleMetadataKey (journalMetadataLine entry) key
      | entry <- duplicates
      ]
    , Just firstEntry
    )

parseLifecycleDay
  :: Text
  -> JournalMetadata
  -> Either (NonEmpty PlanLifecycleError) Day
parseLifecycleDay key entry =
  maybe
    (Left (InvalidPlanLifecycleDate
      (journalMetadataLine entry) key NonEmpty.:| []))
    Right
    (parseTimeM True defaultTimeLocale "%Y-%m-%d"
      (T.unpack (journalMetadataValue entry)))

supersessionCycleFrom :: Map.Map PlanId PlanId -> PlanId -> Bool
supersessionCycleFrom successorByPlan start = go (Set.singleton start) start
  where
    go seen current = case Map.lookup current successorByPlan of
      Nothing -> False
      Just successor
        | successor `Set.member` seen -> True
        | otherwise -> go (Set.insert successor seen) successor

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value
