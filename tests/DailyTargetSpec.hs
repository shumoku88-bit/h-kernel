{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account
import HKernel.Household.DailyTarget
import HKernel.Household.DailyTarget.TSV
import HKernel.Journal
import HKernel.Money
import HKernel.Period
import HKernel.Plan
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
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure

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
    | otherwise -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn ("    expected diagnostic containing: " ++ T.unpack expected)
        putStrLn ("    but got: " ++ T.unpack rendered)
        exitFailure
    where
      rendered = T.unlines
        (map dailyTargetTSVErrorMessage (NonEmpty.toList errors))
  Right value -> do
    putStrLn ("  [FAIL] " ++ label ++ ": accepted " ++ show value)
    exitFailure
