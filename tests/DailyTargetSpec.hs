{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account
import HKernel.Budget.Config (parseBudgetPolicy)
import HKernel.Household.Config
  ( householdConfigurationDailyTargetAssets
  , parseHouseholdConfiguration
  )
import HKernel.Household.DailyTarget
import HKernel.Household.DailyTarget.TSV
import HKernel.Journal
import HKernel.Money
import HKernel.Period
import HKernel.Plan
import HKernel.Plan.Journal (parsePlanJournal)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let journal = mustRight (parseJournal journalText)
      registry = journalAccountRegistry journal
      jpy = mustRight (mkCommodity "JPY")
      cash = mustRight (mkAccount "assets:cash")
      wifi = mustRight (mkAccount "expenses:wifi")
      plan = outgoingPlan registry cash wifi jpy
      scope = mustRight
        (parseDailyTargetScope registry [plan] validScope)
      period = mustRight
        (mkPeriod (fromGregorian 2026 6 15) (fromGregorian 2026 8 14))
      target = deriveDailyTarget
        (fromGregorian 2026 7 31)
        period
        journal
        scope
        [plan]

  assertEqual "eligible Asset policy is distinct from Plan obligations"
    (Set.singleton cash)
    (dailyTargetEligibleAccounts (dailyTargetScopePolicy scope))
  assertEqual "current-cycle obligation selection retains Plan identity"
    (Set.singleton (committedPlanId plan))
    (dailyTargetObligationPlanIds (dailyTargetScopeObligations scope))
  assertEqual "eligible assets use the Balance monoid"
    (one jpy 1900)
    (dailyTargetEligibleAssets target)
  assertEqual "open obligations remain separately observable"
    (one jpy 200)
    (dailyTargetOpenObligations target)
  assertEqual "bounded reservation evidence is retained"
    (one jpy 50)
    (dailyTargetAlreadyExcluded target)
  assertEqual "capacity subtracts only the unreserved obligation"
    (one jpy 1750)
    (dailyTargetCapacity target)
  assertEqual "rate preserves exact rational arithmetic"
    [(jpy, 125)]
    (dailyTargetRate target)

  assertLeftContaining "eligible policy rejects non-Asset Accounts"
    "DailyTargetEligibleAccountNotAsset"
    (parseDailyTargetScope registry [plan] nonAssetScope)
  assertLeftContaining "obligation scope rejects unknown Plan references"
    "UnknownDailyTargetObligation"
    (parseDailyTargetScope registry [plan] unknownPlanScope)
  assertLeftContaining "reservation evidence remains bounded by its Plan"
    "ReservationExceedsPlanAmount"
    (parseDailyTargetScope registry [plan] overReservedScope)
  assertLeftContaining "physical scope identities remain unique"
    "duplicate scope_id"
    (parseDailyTargetScope registry [plan] duplicateScopeId)

  characterizeNativeSourceParity registry plan scope

characterizeNativeSourceParity
  :: AccountRegistry
  -> CommittedOutgoingPlan
  -> DailyTargetScope
  -> IO ()
characterizeNativeSourceParity registry plan retainedScope = do
  let budgetPolicy = mustRight (parseBudgetPolicy nativeBudgetConfig)
      householdConfiguration = mustRight
        (parseHouseholdConfiguration budgetPolicy nativeHouseholdConfig)
      planJournal = mustRight (parsePlanJournal nativePlanJournal)
      obligationSelections = mustRight
        (parseDailyTargetPlanJournalSelections nativePlanJournal planJournal)
      nativeScope = mustRight
        (dailyTargetScopeFromSelections
          registry
          [plan]
          (householdConfigurationDailyTargetAssets householdConfiguration)
          obligationSelections)

  assertEqual
    "household.toml + plan.journal reproduce retained Daily Target semantics"
    retainedScope
    nativeScope

  assertEqual
    "Plan Journal selection identity is retained outside core Plan identity"
    [mustRight (mkDailyTargetScopeId "wifi")]
    (map dailyTargetObligationSelectionId obligationSelections)

  case parseDailyTargetPlanJournalSelections partialReservationPlanJournal
      (mustRight (parsePlanJournal partialReservationPlanJournal)) of
    Left errors
      | IncompleteDailyTargetReservation 1 `elem` NonEmpty.toList errors ->
          putStrLn "  [PASS] native Plan metadata rejects partial reservation evidence"
      | otherwise -> failTest
          "native Plan metadata rejects partial reservation evidence"
          ("unexpected errors: " ++ show errors)
    Right value -> failTest
      "native Plan metadata rejects partial reservation evidence"
      ("unexpectedly accepted: " ++ show value)

  let duplicateId = mustRight (mkDailyTargetScopeId "wifi")
      duplicateAsset = selectDailyTargetAsset duplicateId
        (mustRight (mkAccount "assets:cash"))
  case dailyTargetScopeFromSelections
      registry [plan] [duplicateAsset] obligationSelections of
    Left errors
      | DuplicateDailyTargetScopeId duplicateId `elem` NonEmpty.toList errors ->
          putStrLn "  [PASS] native sources preserve cross-owner selection identity uniqueness"
      | otherwise -> failTest
          "native sources preserve cross-owner selection identity uniqueness"
          ("unexpected errors: " ++ show errors)
    Right value -> failTest
      "native sources preserve cross-owner selection identity uniqueness"
      ("unexpectedly accepted: " ++ show value)

journalText :: T.Text
journalText = T.unlines
  [ "account assets:cash"
  , "    type: asset"
  , "    commodity: JPY"
  , "account expenses:wifi"
  , "    type: expense"
  , "    commodity: JPY"
  , "account equity:opening"
  , "    type: equity"
  , "    commodity: JPY"
  , "2026-06-15 Opening"
  , "    assets:cash  1900 JPY"
  , "    equity:opening"
  ]

outgoingPlan
  :: AccountRegistry
  -> Account
  -> Account
  -> Commodity
  -> CommittedOutgoingPlan
outgoingPlan registry fromAccount toAccount commodity =
  mustRight (mkCommittedOutgoingPlan
    (mustRight (mkPlanId "plan-wifi"))
    (fromGregorian 2026 8 8)
    "Wi-Fi"
    (mustRight (mkPositiveAmount
      (mkAmount commodity (quantityFromInteger 200))))
    direction)
  where
    localDirection = mustRight
      (mkPaymentDirection fromAccount toAccount)
    declaredDirection = mustRight
      (admitPaymentDirection registry localDirection)
    direction = mustRight
      (admitOutgoingPaymentDirection declaredDirection)

validScope :: T.Text
validScope = T.unlines
  [ header
  , "asset\tcash\tassets:cash\t\t\t\t"
  , "obligation\twifi\t\tplan-wifi\t50\tJPY\treservation:wifi"
  ]

nonAssetScope :: T.Text
nonAssetScope = T.unlines
  [ header
  , "asset\twifi-account\texpenses:wifi\t\t\t\t"
  , "obligation\twifi\t\tplan-wifi\t\t\t"
  ]

unknownPlanScope :: T.Text
unknownPlanScope = T.unlines
  [ header
  , "asset\tcash\tassets:cash\t\t\t\t"
  , "obligation\tunknown\t\tplan-unknown\t\t\t"
  ]

overReservedScope :: T.Text
overReservedScope = T.unlines
  [ header
  , "asset\tcash\tassets:cash\t\t\t\t"
  , "obligation\twifi\t\tplan-wifi\t250\tJPY\treservation:wifi"
  ]

duplicateScopeId :: T.Text
duplicateScopeId = T.unlines
  [ header
  , "asset\tshared\tassets:cash\t\t\t\t"
  , "obligation\tshared\t\tplan-wifi\t\t\t"
  ]

header :: T.Text
header =
  "kind\tscope_id\taccount_key\tplan_id\texcluded_amount\tcurrency\treservation_ref"

nativeBudgetConfig :: T.Text
nativeBudgetConfig = T.unlines
  [ "[[backing-pools]]"
  , "id = \"operating\""
  , "asset-accounts = [\"assets:cash\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"daily\""
  , "label = \"Daily\""
  , "pacing = \"daily\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"expenses:wifi\"]"
  ]

nativeHouseholdConfig :: T.Text
nativeHouseholdConfig = T.unlines
  [ "[cycle]"
  , "mode = \"income-anchor\""
  , "income-account = \"income:benefit\""
  , ""
  , "[budget]"
  , "unassigned-accounts = [\"budget:unassigned\"]"
  , ""
  , "[[budget.envelopes]]"
  , "id = \"daily\""
  , "allocation-account = \"budget:daily\""
  , ""
  , "[daily-target]"
  , ""
  , "[[daily-target.assets]]"
  , "id = \"cash\""
  , "account = \"assets:cash\""
  ]

nativePlanJournal :: T.Text
nativePlanJournal = planDeclarations <> T.unlines
  [ "2026-08-08 Wi-Fi"
  , "    ; plan-id: plan-wifi"
  , "    ; daily-target-id: wifi"
  , "    ; reservation-id: reservation:wifi"
  , "    ; reservation-amount: 50"
  , "    ; reservation-commodity: JPY"
  , "    assets:cash    -200 JPY"
  , "    expenses:wifi   200 JPY"
  ]

partialReservationPlanJournal :: T.Text
partialReservationPlanJournal = planDeclarations <> T.unlines
  [ "2026-08-08 Wi-Fi"
  , "    ; plan-id: plan-wifi"
  , "    ; daily-target-id: wifi"
  , "    ; reservation-id: reservation:wifi"
  , "    ; reservation-amount: 50"
  , "    assets:cash    -200 JPY"
  , "    expenses:wifi   200 JPY"
  ]

planDeclarations :: T.Text
planDeclarations = T.unlines
  [ "account assets:cash"
  , "    type: asset"
  , "    commodity: JPY"
  , "account expenses:wifi"
  , "    type: expense"
  , "    commodity: JPY"
  ]

one :: Commodity -> Integer -> Balance
one commodity value =
  singletonBalance (mkAmount commodity (quantityFromInteger value))

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("invalid Daily Target fixture: " ++ show err)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = failTest label
      ("expected: " ++ show expected ++ ", but got: " ++ show actual)

assertLeftContaining
  :: Show success
  => String
  -> T.Text
  -> Either (NonEmpty.NonEmpty DailyTargetTSVError) success
  -> IO ()
assertLeftContaining label expected result = case result of
  Left errors
    | expected `T.isInfixOf` rendered ->
        putStrLn ("  [PASS] " ++ label)
    | otherwise -> failTest label
        ("expected diagnostic containing: " ++ T.unpack expected
          ++ ", but got: " ++ T.unpack rendered)
    where
      rendered = T.unlines
        (map dailyTargetTSVErrorMessage (NonEmpty.toList errors))
  Right value -> failTest label ("accepted: " ++ show value)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
