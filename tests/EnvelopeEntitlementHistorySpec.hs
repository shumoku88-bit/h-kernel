{-# LANGUAGE OverloadedStrings #-}

module EnvelopeEntitlementHistorySpec (main) where

import Test.Support (mustRight)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Time.Calendar (Day, addDays, fromGregorian)
import HKernel.Envelope.Identity (mkEnvelopeId)
import HKernel.Envelope.EntitlementHistory
import HKernel.Envelope.EntitlementTransfer
import HKernel.Envelope.StockOrigin (StockOrigin(..), stockOrigin)
import HKernel.Money
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
          (day 15) Unallocated (Spendable food) amount "initial")
      moved = mustRight
        (mkEnvelopeEntitlementTransfer
          (day 16) (Spendable food) (Spendable stock) amount "move")
  equal "Unallocated is an endpoint, not an EnvelopeId"
    Unallocated
    (entitlementTransferFrom allocation)
  equal "Envelope-to-Envelope move stays atomic"
    (Spendable food, Spendable stock)
    (entitlementTransferFrom moved, entitlementTransferTo moved)
  left "same endpoint is rejected"
    (mkEnvelopeEntitlementTransfer
      (day 16) (Spendable food) (Spendable food) amount "same")
  left "zero amount is rejected"
    (mkEnvelopeEntitlementTransfer
      (day 16) Unallocated (Spendable food) (jpy 0) "zero")
  left "negative amount is rejected"
    (mkEnvelopeEntitlementTransfer
      (day 16) Unallocated (Spendable food) (jpy (-1)) "negative")

historyLaws :: IO ()
historyLaws = do
  let food = mustRight (mkEnvelopeId "food")
      stock = mustRight (mkEnvelopeId "stock-food")
      origins = Map.singleton jpyCommodity
        (StockOrigin (day 1) jpyCommodity "JPY opening stock")
      grant n effectiveDay note = mustRight
        (mkEnvelopeEntitlementTransfer
          effectiveDay Unallocated (Spendable food) (jpy n) note)
      move n effectiveDay note = mustRight
        (mkEnvelopeEntitlementTransfer
          effectiveDay (Spendable food) (Spendable stock) (jpy n) note)
      initial = grant 10000 (day 15) "initial"
      laterMove = move 5000 (day 32) "later"
      sourceOrder = [laterMove, initial]
      admitted = mustRight (mkEnvelopeEntitlementHistory origins sourceOrder)
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
  equal "history preserves explicit origins with note"
    origins
    (envelopeEntitlementHistoryOrigins admitted)
  right "effective date, not source order, governs admission"
    (mkEnvelopeEntitlementHistory origins sourceOrder)
  right "same-day deltas combine before validation"
    (mkEnvelopeEntitlementHistory origins sameDay)
  right "Unallocated has no stored balance in history"
    (mkEnvelopeEntitlementHistory origins [grant 1000000 (day 15) "large claim"])

  -- Missing origin law
  case mkEnvelopeEntitlementHistory Map.empty [initial] of
    Left errors -> case NonEmpty.toList errors of
      [EnvelopeEntitlementOriginMissing actualCommodity actualDay] -> do
        equal "missing origin retains commodity" jpyCommodity actualCommodity
        equal "missing origin retains transfer day" (day 15) actualDay
      other -> failTest ("unexpected missing origin errors: " ++ show other)
    Right value -> failTest ("unexpectedly accepted missing origin: " ++ show value)

  -- Origin after transfer law
  let lateOrigin = Map.singleton jpyCommodity (StockOrigin (day 20) jpyCommodity "late origin")
  case mkEnvelopeEntitlementHistory lateOrigin [initial] of
    Left errors -> case NonEmpty.toList errors of
      [EnvelopeEntitlementOriginAfterTransfer actualCommodity originDay transferDay] -> do
        equal "origin after transfer commodity" jpyCommodity actualCommodity
        equal "origin date" (day 20) originDay
        equal "transfer date" (day 15) transferDay
      other -> failTest ("unexpected origin after transfer errors: " ++ show other)
    Right value -> failTest ("unexpectedly accepted origin after transfer: " ++ show value)

  -- Overdrawn negative state law
  case mkEnvelopeEntitlementHistory origins overdrawn of
    Left errors -> case NonEmpty.toList errors of
      [EnvelopeEntitlementBecameNegative actualEnvelope actualCommodity actualDay actualQuantity] -> do
        equal "negative error retains Envelope" food actualEnvelope
        equal "negative error retains commodity" jpyCommodity actualCommodity
        equal "negative error retains effective date" (day 32) actualDay
        equal "later restoration does not hide negative state"
          (quantityFromInteger (-5000)) actualQuantity
      other -> failTest ("unexpected errors: " ++ show other)
    Right value -> failTest ("unexpectedly accepted: " ++ show value)

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
