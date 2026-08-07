{-# LANGUAGE OverloadedStrings #-}

-- | Stable Daily Target policy and projection for one household.
--
-- Eligible Asset Accounts are long-lived household policy. Selected outgoing
-- Plans and optional reservation evidence are a separate, cycle-varying scope.
-- Keeping those meanings apart prevents one current-format source from becoming
-- one undifferentiated record in the domain model.
module HKernel.Household.DailyTarget
  ( DailyTargetScopeId
  , DailyTargetScopeIdError(..)
  , mkDailyTargetScopeId
  , dailyTargetScopeIdText
  , DailyTargetAssetSelection
  , selectDailyTargetAsset
  , dailyTargetAssetSelectionId
  , dailyTargetAssetSelectionAccount
  , DailyTargetObligationSelection
  , selectDailyTargetObligation
  , dailyTargetObligationSelectionId
  , dailyTargetObligationSelectionDeclaration
  , DailyTargetSelectionError(..)
  , dailyTargetScopeFromSelections
  , DailyTargetPolicy
  , DailyTargetPolicyError(..)
  , mkDailyTargetPolicy
  , dailyTargetEligibleAccounts
  , DailyTargetObligationDeclaration
  , declareDailyTargetObligation
  , declaredDailyTargetObligationPlanId
  , declaredDailyTargetReservation
  , DailyTargetObligationScope
  , DailyTargetObligationError(..)
  , resolveDailyTargetObligationScope
  , dailyTargetObligationPlanIds
  , dailyTargetReservationFor
  , DailyTargetScope
  , dailyTargetScope
  , dailyTargetScopePolicy
  , dailyTargetScopeObligations
  , DailyTarget(..)
  , dailyTargetCapacity
  , dailyTargetRate
  , deriveDailyTarget
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time.Calendar (Day, diffDays)
import HKernel.Account
  ( Account
  , AccountRegistry
  , AccountType(..)
  , declaredAccountType
  , lookupAccountDeclaration
  )
import HKernel.Engine
  ( accountBalance
  , accountBalancesThrough
  )
import HKernel.Journal (Journal)
import HKernel.Money
import HKernel.Period
import HKernel.Plan
import HKernel.Plan.Reservation

-- | Source-independent identity for one Daily Target selection declaration.
--
-- The retained TSV required only non-emptiness. Native sources preserve that
-- exact semantic boundary instead of silently tightening accepted identities
-- during migration.
newtype DailyTargetScopeId = DailyTargetScopeId
  { dailyTargetScopeIdText :: Text
  } deriving (Eq, Ord, Show)

data DailyTargetScopeIdError = EmptyDailyTargetScopeId
  deriving (Eq, Show)

mkDailyTargetScopeId :: Text -> Either DailyTargetScopeIdError DailyTargetScopeId
mkDailyTargetScopeId value
  | value == "" = Left EmptyDailyTargetScopeId
  | otherwise = Right (DailyTargetScopeId value)

-- | Long-lived selection of one Asset Account for Daily Target capacity.
data DailyTargetAssetSelection = DailyTargetAssetSelection
  { dailyTargetAssetSelectionId      :: DailyTargetScopeId
  , dailyTargetAssetSelectionAccount :: Account
  } deriving (Eq, Show)

selectDailyTargetAsset
  :: DailyTargetScopeId
  -> Account
  -> DailyTargetAssetSelection
selectDailyTargetAsset = DailyTargetAssetSelection

-- | Current-cycle selection of one Plan, retaining its selection identity and
-- optional reservation declaration.
data DailyTargetObligationSelection = DailyTargetObligationSelection
  { dailyTargetObligationSelectionId          :: DailyTargetScopeId
  , dailyTargetObligationSelectionDeclaration :: DailyTargetObligationDeclaration
  } deriving (Eq, Show)

selectDailyTargetObligation
  :: DailyTargetScopeId
  -> DailyTargetObligationDeclaration
  -> DailyTargetObligationSelection
selectDailyTargetObligation = DailyTargetObligationSelection

-- | Cross-source semantic failures after individual source syntax has already
-- been admitted.
data DailyTargetSelectionError
  = DuplicateDailyTargetScopeId DailyTargetScopeId
  | DailyTargetPolicySelectionError DailyTargetPolicyError
  | DailyTargetObligationSelectionError DailyTargetObligationError
  deriving (Eq, Show)

-- | Assemble the same stable 'DailyTargetScope' from source-independent
-- selections regardless of whether they came from retained TSV or the native
-- household.toml + plan.journal pair.
dailyTargetScopeFromSelections
  :: AccountRegistry
  -> [CommittedOutgoingPlan]
  -> [DailyTargetAssetSelection]
  -> [DailyTargetObligationSelection]
  -> Either (NonEmpty DailyTargetSelectionError) DailyTargetScope
dailyTargetScopeFromSelections registry plans assetSelections obligationSelections =
  case NonEmpty.nonEmpty allErrors of
    Just errors -> Left errors
    Nothing -> case (policyResult, obligationResult) of
      (Right policy, Right obligations) -> Right (dailyTargetScope policy obligations)
      _ -> error "Daily Target selection assembly lost a reported error"
  where
    allSelections =
      map dailyTargetAssetSelectionId assetSelections
        ++ map dailyTargetObligationSelectionId obligationSelections
    duplicateErrors =
      map DuplicateDailyTargetScopeId (duplicates allSelections)
    policyResult = mkDailyTargetPolicy registry
      (map dailyTargetAssetSelectionAccount assetSelections)
    policyErrors = either
      (map DailyTargetPolicySelectionError . NonEmpty.toList)
      (const [])
      policyResult
    obligationResult = resolveDailyTargetObligationScope plans
      (map dailyTargetObligationSelectionDeclaration obligationSelections)
    obligationErrors = either
      (map DailyTargetObligationSelectionError . NonEmpty.toList)
      (const [])
      obligationResult
    allErrors = duplicateErrors ++ policyErrors ++ obligationErrors

-- | Household policy selecting the Asset Accounts that may fund ordinary
-- day-to-day spending.
newtype DailyTargetPolicy = DailyTargetPolicy
  { dailyTargetEligibleAccounts :: Set Account
  } deriving (Eq, Show)

data DailyTargetPolicyError
  = DailyTargetPolicyHasNoEligibleAssets
  | DuplicateDailyTargetEligibleAsset Account
  | DailyTargetEligibleAssetUndeclared Account
  | DailyTargetEligibleAccountNotAsset Account AccountType
  deriving (Eq, Show)

-- | Admit eligible Asset coordinates against one canonical AccountRegistry.
-- Independent source conflicts remain visible together.
mkDailyTargetPolicy
  :: AccountRegistry
  -> [Account]
  -> Either (NonEmpty DailyTargetPolicyError) DailyTargetPolicy
mkDailyTargetPolicy registry accounts =
  case NonEmpty.nonEmpty errors of
    Just values -> Left values
    Nothing -> Right (DailyTargetPolicy (Set.fromList accounts))
  where
    errors = presenceErrors ++ duplicateErrors ++ concatMap validate accounts
    presenceErrors =
      [ DailyTargetPolicyHasNoEligibleAssets
      | null accounts
      ]
    duplicateErrors =
      [ DuplicateDailyTargetEligibleAsset account
      | account <- duplicates accounts
      ]
    validate account = case lookupAccountDeclaration account registry of
      Nothing -> [DailyTargetEligibleAssetUndeclared account]
      Just declaration
        | declaredAccountType declaration == Asset -> []
        | otherwise ->
            [ DailyTargetEligibleAccountNotAsset
                account
                (declaredAccountType declaration)
            ]

-- | One current-cycle decision that an outgoing Plan participates in Daily
-- Target. Optional reservation declaration is still unproven source evidence.
data DailyTargetObligationDeclaration = DailyTargetObligationDeclaration
  { declaredDailyTargetObligationPlanId :: PlanId
  , declaredDailyTargetReservation      :: Maybe PlanReservationDeclaration
  } deriving (Eq, Show)

declareDailyTargetObligation
  :: PlanId
  -> Maybe PlanReservationDeclaration
  -> DailyTargetObligationDeclaration
declareDailyTargetObligation = DailyTargetObligationDeclaration

-- | Resolved current-cycle obligation scope. Plan selection and reservation
-- evidence remain distinct coordinates even though one source may declare both.
newtype DailyTargetObligationScope = DailyTargetObligationScope
  { dailyTargetObligations :: Map PlanId (Maybe PlanReservationEvidence)
  } deriving (Eq, Show)

data DailyTargetObligationError
  = DuplicateDailyTargetAvailablePlan PlanId
  | DuplicateDailyTargetObligation PlanId
  | UnknownDailyTargetObligation PlanId
  | DailyTargetReservationTargetsDifferentPlan PlanId PlanId
  | DailyTargetReservationError PlanReservationError
  deriving (Eq, Show)

resolveDailyTargetObligationScope
  :: [CommittedOutgoingPlan]
  -> [DailyTargetObligationDeclaration]
  -> Either (NonEmpty DailyTargetObligationError) DailyTargetObligationScope
resolveDailyTargetObligationScope plans declarations =
  case NonEmpty.nonEmpty errors of
    Just values -> Left values
    Nothing -> Right (DailyTargetObligationScope resolvedByPlan)
  where
    planById = Map.fromList
      [ (committedPlanId plan, plan)
      | plan <- plans
      ]
    declarationPlanIds = map declaredDailyTargetObligationPlanId declarations
    reservations =
      [ reservation
      | declaration <- declarations
      , Just reservation <- [declaredDailyTargetReservation declaration]
      ]
    reservationResult = resolvePlanReservationEvidence plans reservations
    reservationErrors = case reservationResult of
      Left values -> map DailyTargetReservationError (NonEmpty.toList values)
      Right _ -> []
    reservationEvidence = case reservationResult of
      Left _ -> []
      Right values -> values
    evidenceByPlan = Map.fromList
      [ (committedPlanId (reservationEvidencePlan evidence), evidence)
      | evidence <- reservationEvidence
      ]
    resolvedByPlan = Map.fromList
      [ (planId, Map.lookup planId evidenceByPlan)
      | planId <- declarationPlanIds
      ]
    errors =
      [ DuplicateDailyTargetAvailablePlan planId
      | planId <- duplicates (map committedPlanId plans)
      ]
        ++ [ DuplicateDailyTargetObligation planId
           | planId <- duplicates declarationPlanIds
           ]
        ++ [ UnknownDailyTargetObligation planId
           | planId <- declarationPlanIds
           , Map.notMember planId planById
           ]
        ++ [ DailyTargetReservationTargetsDifferentPlan
               selectedPlanId
               (declaredReservationPlanId reservation)
           | declaration <- declarations
           , let selectedPlanId = declaredDailyTargetObligationPlanId declaration
           , Just reservation <- [declaredDailyTargetReservation declaration]
           , declaredReservationPlanId reservation /= selectedPlanId
           ]
        ++ reservationErrors

dailyTargetObligationPlanIds :: DailyTargetObligationScope -> Set PlanId
dailyTargetObligationPlanIds = Map.keysSet . dailyTargetObligations

dailyTargetReservationFor
  :: PlanId
  -> DailyTargetObligationScope
  -> Maybe PlanReservationEvidence
dailyTargetReservationFor planId scope =
  Map.lookup planId (dailyTargetObligations scope) >>= id

-- | Stable typed input assembled by source admission owners.
data DailyTargetScope = DailyTargetScope
  { dailyTargetScopePolicy      :: DailyTargetPolicy
  , dailyTargetScopeObligations :: DailyTargetObligationScope
  } deriving (Eq, Show)

dailyTargetScope
  :: DailyTargetPolicy
  -> DailyTargetObligationScope
  -> DailyTargetScope
dailyTargetScope = DailyTargetScope

-- | Derived Daily Target evidence. The aggregates remain available beside the
-- final rate so a report can explain every deduction.
data DailyTarget = DailyTarget
  { dailyTargetObservedOn       :: Day
  , dailyTargetEndExclusive     :: Day
  , dailyTargetEligibleAssets   :: Balance
  , dailyTargetOpenObligations  :: Balance
  , dailyTargetAlreadyExcluded  :: Balance
  } deriving (Eq, Show)

dailyTargetCapacity :: DailyTarget -> Balance
dailyTargetCapacity report =
  dailyTargetEligibleAssets report
    `subtractBalance` obligationDeduction
  where
    obligationDeduction = dailyTargetOpenObligations report
      `subtractBalance` dailyTargetAlreadyExcluded report

dailyTargetRate :: DailyTarget -> [(Commodity, Rational)]
dailyTargetRate report = balanceRate (dailyTargetDays report)
  (dailyTargetCapacity report)

-- | Derive Daily Target from one observation, one cycle, validated household
-- policy, current Account balances, and the open Plans selected for this cycle.
deriveDailyTarget
  :: Day
  -> Period
  -> Journal
  -> DailyTargetScope
  -> [CommittedOutgoingPlan]
  -> DailyTarget
deriveDailyTarget observation period journal scope openPlans = DailyTarget
  { dailyTargetObservedOn = observation
  , dailyTargetEndExclusive = periodEndExclusive period
  , dailyTargetEligibleAssets = foldMap
      (`accountBalance` balances)
      (Set.toAscList (dailyTargetEligibleAccounts policy))
  , dailyTargetOpenObligations = foldMap
      (singletonBalance . positiveAmountValue . committedPlanAmount)
      selectedPlans
  , dailyTargetAlreadyExcluded = foldMap
      reservationBalance
      selectedPlans
  }
  where
    policy = dailyTargetScopePolicy scope
    obligations = dailyTargetScopeObligations scope
    balances = accountBalancesThrough observation journal
    selectedPlans =
      [ plan
      | plan <- openPlans
      , Set.member
          (committedPlanId plan)
          (dailyTargetObligationPlanIds obligations)
      ]
    reservationBalance plan = maybe mempty
      (singletonBalance . positiveAmountValue . reservationEvidenceAmount)
      (dailyTargetReservationFor (committedPlanId plan) obligations)

dailyTargetDays :: DailyTarget -> Integer
dailyTargetDays report =
  max 1 (diffDays
    (dailyTargetEndExclusive report)
    (dailyTargetObservedOn report))

balanceRate :: Integer -> Balance -> [(Commodity, Rational)]
balanceRate days = map toRate . balanceEntries
  where
    toRate (commodity, quantity) =
      (commodity, quantityToRational quantity / fromInteger days)

duplicates :: Ord value => [value] -> [value]
duplicates values =
  [ value
  | (value, count) <- Map.toAscList
      (Map.fromListWith (+) [(value, 1 :: Int) | value <- values])
  , count > 1
  ]
