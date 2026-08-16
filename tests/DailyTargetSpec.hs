{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account
import HKernel.Envelope.Config (parseCurrentEnvelopeConfiguration)
import HKernel.Household.Config
  ( householdConfigurationDailyTargetAssets
  , householdConfigurationPrimaryCommodity
  , parseHouseholdConfiguration
  )
import HKernel.Household.DailyTarget
import HKernel.Journal
import HKernel.Money
import HKernel.Period
import HKernel.Plan
import HKernel.Plan.Journal (parsePlanJournal)
import HKernel.Plan.Reservation (PlanReservationError(..))
import System.Exit (exitFailure)

main :: IO ()
main = do
  let journal = mustRight (parseJournal journalText)
      registry = journalAccountRegistry journal
      jpy = mustRight (mkCommodity "JPY")
      cash = mustRight (mkAccount "assets:cash")
      wifi = mustRight (mkAccount "expenses:wifi")
      plan = outgoingPlan registry cash wifi jpy
      (envelopePolicy, backingPolicy) = mustRight
        (parseCurrentEnvelopeConfiguration nativeEnvelopeConfig)
      householdConfiguration = mustRight
        (parseHouseholdConfiguration
          envelopePolicy backingPolicy nativeHouseholdConfig)
      preCutoverConfiguration = mustRight
        (parseHouseholdConfiguration
          envelopePolicy backingPolicy nativeHouseholdConfigWithoutMoney)
      planJournal = mustRight (parsePlanJournal nativePlanJournal)
      obligationSelections = mustRight
        (admitDailyTargetPlanJournalSelections planJournal)
      scope = mustRight
        (dailyTargetScopeFromSelections
          registry
          [plan]
          (householdConfigurationDailyTargetAssets householdConfiguration)
          obligationSelections)
      period = mustRight
        (mkPeriod (fromGregorian 2026 6 15) (fromGregorian 2026 8 14))
      target = deriveDailyTarget
        (fromGregorian 2026 7 31)
        period
        journal
        scope
        [plan]

  assertEqual "household.toml admits an explicit primary Commodity"
    (Just jpy)
    (householdConfigurationPrimaryCommodity householdConfiguration)
  assertEqual
    "household.toml remains valid without inventing a Commodity fallback"
    Nothing
    (householdConfigurationPrimaryCommodity preCutoverConfiguration)

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

  assertEqual
    "Plan Journal selection identity is retained outside core Plan identity"
    [mustRight (mkDailyTargetScopeId "wifi")]
    (map dailyTargetObligationSelectionId obligationSelections)

  characterizeNativeFailures registry plan cash wifi

characterizeNativeFailures
  :: AccountRegistry
  -> CommittedOutgoingPlan
  -> Account
  -> Account
  -> IO ()
characterizeNativeFailures registry plan cash wifi = do
  let cashId = mustRight (mkDailyTargetScopeId "cash")
      wifiId = mustRight (mkDailyTargetScopeId "wifi")
      unknownId = mustRight (mkDailyTargetScopeId "unknown")
      assetSelection = selectDailyTargetAsset cashId cash
      nonAssetSelection = selectDailyTargetAsset wifiId wifi
      unknownPlanId = mustRight (mkPlanId "plan-unknown")
      unknownObligation = selectDailyTargetObligation unknownId
        (declareDailyTargetObligation unknownPlanId Nothing)

  assertLeftSatisfies
    "eligible policy rejects non-Asset Accounts"
    (isNonAsset wifi)
    (dailyTargetScopeFromSelections registry [plan] [nonAssetSelection] [])

  assertLeftSatisfies
    "obligation scope rejects unknown Plan references"
    (isUnknownPlan unknownPlanId)
    (dailyTargetScopeFromSelections
      registry [plan] [assetSelection] [unknownObligation])

  let overReservedSelections = mustRight
        (admitDailyTargetPlanJournalSelections
          (mustRight (parsePlanJournal overReservedPlanJournal)))
  assertLeftSatisfies
    "reservation evidence remains bounded by its Plan"
    (isOverReserved (committedPlanId plan))
    (dailyTargetScopeFromSelections
      registry [plan] [assetSelection] overReservedSelections)

  let duplicateAsset = selectDailyTargetAsset wifiId cash
      normalSelections = mustRight
        (admitDailyTargetPlanJournalSelections
          (mustRight (parsePlanJournal nativePlanJournal)))
  assertLeftSatisfies
    "cross-owner Daily Target identities remain unique"
    (isDuplicateId wifiId)
    (dailyTargetScopeFromSelections
      registry [plan] [duplicateAsset] normalSelections)

  case admitDailyTargetPlanJournalSelections
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

  let detachedJournal = mustRight
        (parsePlanJournal detachedDailyTargetMetadataPlanJournal)
  assertEqual
    "canonical blank line detaches Daily Target metadata"
    []
    (mustRight
      (admitDailyTargetPlanJournalSelections detachedJournal))
  where
    isNonAsset expected err = case err of
      DailyTargetPolicySelectionError
          (DailyTargetEligibleAccountNotAsset found Expense) -> found == expected
      _ -> False

    isUnknownPlan expected err = case err of
      DailyTargetObligationSelectionError
          (UnknownDailyTargetObligation found) -> found == expected
      _ -> False

    isOverReserved expected err = case err of
      DailyTargetObligationSelectionError
          (DailyTargetReservationError
            (ReservationExceedsPlanAmount _ found _ _)) -> found == expected
      _ -> False

    isDuplicateId expected err = case err of
      DuplicateDailyTargetScopeId found -> found == expected
      _ -> False

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

nativeEnvelopeConfig :: T.Text
nativeEnvelopeConfig = T.unlines
  [ "[[backing-pools]]"
  , "id = \"operating\""
  , "asset-accounts = [\"assets:cash\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"daily\""
  , "label = \"Daily\""
  , "pacing = \"daily\""
  , "backing-pool = \"operating\""
  ]

nativeHouseholdConfig :: T.Text
nativeHouseholdConfig = T.unlines
  ( [ "[money]"
    , "primary-commodity = \"JPY\""
    , ""
    ]
      ++ T.lines nativeHouseholdConfigWithoutMoney
  )

nativeHouseholdConfigWithoutMoney :: T.Text
nativeHouseholdConfigWithoutMoney = T.unlines
  [ "[cycle]"
  , "mode = \"income-anchor\""
  , "income-account = \"income:benefit\""
  , ""
  , "[budget]"
  , "opening-accounts = [\"budget:opening\"]"
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

overReservedPlanJournal :: T.Text
overReservedPlanJournal = planDeclarations <> T.unlines
  [ "2026-08-08 Wi-Fi"
  , "    ; plan-id: plan-wifi"
  , "    ; daily-target-id: wifi-over"
  , "    ; reservation-id: reservation:wifi-over"
  , "    ; reservation-amount: 250"
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

detachedDailyTargetMetadataPlanJournal :: T.Text
detachedDailyTargetMetadataPlanJournal = planDeclarations <> T.unlines
  [ "2026-08-08 Wi-Fi"
  , "    ; plan-id: plan-wifi"
  , "    assets:cash    -200 JPY"
  , "    expenses:wifi   200 JPY"
  , ""
  , "    ; daily-target-id: wifi"
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

assertLeftSatisfies
  :: Show success
  => String
  -> (error -> Bool)
  -> Either (NonEmpty.NonEmpty error) success
  -> IO ()
assertLeftSatisfies label predicate result = case result of
  Left errors
    | any predicate (NonEmpty.toList errors) ->
        putStrLn ("  [PASS] " ++ label)
    | otherwise -> failTest label "expected typed error was not present"
  Right value -> failTest label ("accepted: " ++ show value)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
