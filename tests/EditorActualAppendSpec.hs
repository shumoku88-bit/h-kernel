{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (Account, mkAccount)
import HKernel.Editor.ActualAppend
import HKernel.Money (Commodity, Quantity, mkCommodity, parseQuantity)

main :: IO ()
main = do
  let results = [ ("testOrdinaryTwoPosting", testOrdinaryTwoPosting)
                , ("testUndeclaredAccount", testUndeclaredAccount)
                , ("testZeroAmount", testZeroAmount)
                , ("testUnbalanced", testUnbalanced)
                ]
  mapM_ print results
  if all snd results
    then exitSuccess
    else exitFailure

fixtureSource :: Text
fixtureSource = T.unlines
  [ "account assets:bank"
  , "  type: Asset"
  , "  commodity: JPY"
  , "account equity:opening"
  , "  type: Equity"
  , "  commodity: JPY"
  , ""
  , "2023-01-01 opening"
  , "  assets:bank  100 JPY"
  , "  equity:opening  -100 JPY"
  ]

accBank :: Account
accBank = either (error "bad account") id (mkAccount "assets:bank")

accOpening :: Account
accOpening = either (error "bad account") id (mkAccount "equity:opening")

accUnknown :: Account
accUnknown = either (error "bad account") id (mkAccount "assets:unknown")

qty :: Text -> Quantity
qty = either (error "bad qty") id . parseQuantity

comm :: Text -> Commodity
comm = either (error "bad comm") id . mkCommodity

testOrdinaryTwoPosting :: Bool
testOrdinaryTwoPosting =
  let intent = ActualEditIntent
        { intentDate = fromGregorian 2023 1 2
        , intentDescription = "test"
        , intentPostings = IntentPosting accBank (qty "50") (Just (comm "JPY"))
                        :| [IntentPosting accOpening (qty "-50") (Just (comm "JPY"))]
        }
      result = prepareActualAppend fixtureSource intent
  in case result of
       Right _ -> True
       Left err -> error (show err)

testUndeclaredAccount :: Bool
testUndeclaredAccount =
  let intent = ActualEditIntent
        { intentDate = fromGregorian 2023 1 2
        , intentDescription = "test"
        , intentPostings = IntentPosting accUnknown (qty "50") (Just (comm "JPY"))
                        :| [IntentPosting accOpening (qty "-50") (Just (comm "JPY"))]
        }
      result = prepareActualAppend fixtureSource intent
  in case result of
       Left (UndeclaredAccount _ :| _) -> True
       _ -> False

testZeroAmount :: Bool
testZeroAmount =
  let intent = ActualEditIntent
        { intentDate = fromGregorian 2023 1 2
        , intentDescription = "test"
        , intentPostings = IntentPosting accBank (qty "0") (Just (comm "JPY"))
                        :| [IntentPosting accOpening (qty "0") (Just (comm "JPY"))]
        }
      result = prepareActualAppend fixtureSource intent
  in case result of
       Left (ZeroAmount _ :| _) -> True
       _ -> False

testUnbalanced :: Bool
testUnbalanced =
  let intent = ActualEditIntent
        { intentDate = fromGregorian 2023 1 2
        , intentDescription = "test"
        , intentPostings = IntentPosting accBank (qty "50") (Just (comm "JPY"))
                        :| [IntentPosting accOpening (qty "-40") (Just (comm "JPY"))]
        }
      result = prepareActualAppend fixtureSource intent
  in case result of
       Left (ValidationError _ :| _) -> True
       _ -> False
