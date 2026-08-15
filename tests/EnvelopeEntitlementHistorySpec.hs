{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Time.Calendar (Day, addDays, fromGregorian)
import HKernel.Envelope.Identity (mkEnvelopeId)
import HKernel.Envelope.EntitlementHistory
import HKernel.Envelope.EntitlementTransfer
import HKernel.Money
import HKernel.Period (Period, mkPeriod)
import System.Exit (exitFailure)

main :: IO ()
main = do
  transferLaws
  historyLaws

transferLaws :: IO ()
transferLaws = do
  let food = mustRight (mkEnvelopeId "food")
      stock = mustRight (mkEnvelopeId "stock-food")
      amount = jpy 1000
      allocation = mustRight
        (mkEnvelopeEntitlementTransfer
          (day 15) period Unallocated (Spendable food) amount "initial")
      moved = mustRight
        (mkEnvelopeEntitlementTransfer
          (day 16) period (Spendable food) (Spendable stock) amount "move")
  equal "Unallocated is an endpoint, not an EnvelopeId"
    Unallocated
    (entitlementTransferFrom allocation)
  equal "Envelope-to-Envelope move stays atomic"
    (Spendable food, Spendable stock)
    (entitlementTransferFrom moved, entitlementTransferTo moved)
  left "same endpoint is rejected"
    (mkEnvelopeEntitlementTransfer
      (day 16) period (Spendable food) (Spendable food) amount "same")
  left "zero amount is rejected"
    (mkEnvelopeEntitlementTransfer
      (day 16) period Unallocated (Spendable food) (jpy 0) "zero")
  left "negative amount is rejected"
    (mkEnvelopeEntitlementTransfer
      (day 16) period Unallocated (Spendable food) (jpy (-1)) "negative")
  left "date outside explicit Period is rejected"
    (mkEnvelopeEntitlementTransfer
      (fromGregorian 2026 10 15) period Unallocated (Spendable food) amount "outside")

historyLaws :: IO ()
historyLaws = do
  let food = mustRight (mkEnvelopeId "food")
      stock = mustRight (mkEnvelopeId "stock-food")
      grant n effectiveDay note = mustRight
        (mkEnvelopeEntitlementTransfer
          effectiveDay period Unallocated (Spendable food) (jpy n) note)
      move n effectiveDay note = mustRight
        (mkEnvelopeEntitlementTransfer
          effectiveDay period (Spendable food) (Spendable stock) (jpy n) note)
      initial = grant 10000 (day 15) "initial"
      laterMove = move 5000 (day 32) "later"
      sourceOrder = [laterMove, initial]
      admitted = mustRight (mkEnvelopeEntitlementHistory sourceOrder)
      sameDay =
        [ move 5000 (day 20) "move"
        , grant 5000 (day 20) "grant"
        ]
      overdrawn =
        [ initial
        , move 15000 (day 32) "too much"
        , grant 10000 (day 33) "later restoration"
        ]
  equal "history preserves source order"
    sourceOrder
    (envelopeEntitlementHistoryTransfers admitted)
  right "effective date, not source order, governs admission"
    (mkEnvelopeEntitlementHistory sourceOrder)
  right "same-day deltas combine before validation"
    (mkEnvelopeEntitlementHistory sameDay)
  right "Unallocated has no stored balance in history"
    (mkEnvelopeEntitlementHistory [grant 1000000 (day 15) "large claim"])
  case mkEnvelopeEntitlementHistory overdrawn of
    Left errors -> case NonEmpty.toList errors of
      [EnvelopeEntitlementBecameNegative actualPeriod actualEnvelope actualCommodity actualDay actualQuantity] -> do
        equal "negative error retains Period" period actualPeriod
        equal "negative error retains Envelope" food actualEnvelope
        equal "negative error retains commodity" jpyCommodity actualCommodity
        equal "negative error retains effective date" (day 32) actualDay
        equal "later restoration does not hide negative state"
          (quantityFromInteger (-5000)) actualQuantity
      other -> failTest ("unexpected errors: " ++ show other)
    Right value -> failTest ("unexpectedly accepted: " ++ show value)

period :: Period
period = mustRight
  (mkPeriod (fromGregorian 2026 8 15) (fromGregorian 2026 10 15))

day :: Integer -> Day
day n = addDays n (fromGregorian 2026 8 1)

jpyCommodity :: Commodity
jpyCommodity = mustRight (mkCommodity "JPY")

jpy :: Integer -> Amount
jpy n = mkAmount jpyCommodity (quantityFromInteger n)

left :: Show value => String -> Either error value -> IO ()
left label result = case result of
  Left _ -> pass label
  Right value -> failTest (label ++ ": unexpectedly accepted " ++ show value)

right :: Show error => String -> Either error value -> IO ()
right label result = case result of
  Right _ -> pass label
  Left err -> failTest (label ++ ": unexpectedly rejected " ++ show err)

equal :: (Eq value, Show value) => String -> value -> value -> IO ()
equal label expected actual
  | expected == actual = pass label
  | otherwise = failTest
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)

pass :: String -> IO ()
pass label = putStrLn ("  [PASS] " ++ label)

failTest :: String -> IO value
failTest message = do
  putStrLn ("  [FAIL] " ++ message)
  exitFailure
