{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (exitFailure, exitSuccess)

import HKernel.Account (Account, mkAccount, AccountType(..), declareAccount, declareAccountWithDefaultCommodity)
import HKernel.Money (Commodity, mkCommodity)
import HKernel.Editor.ActualAccountAppend

main :: IO ()
main = do
  let results = [ ("testValidAccountNoCommodity", testValidAccountNoCommodity)
                , ("testValidAccountWithCommodity", testValidAccountWithCommodity)
                , ("testDuplicateAccount", testDuplicateAccount)
                ]
  mapM_ print results
  if all snd results
    then exitSuccess
    else exitFailure

fixtureSource :: Text
fixtureSource = T.unlines
  [ "account equity:opening"
  , "  type: Equity"
  , ""
  , "account assets:cash"
  , "  type: Asset"
  , "  commodity: JPY"
  , ""
  , "2026-08-01 opening"
  , "  assets:cash     1000 JPY"
  , "  equity:opening  -1000 JPY"
  ]

accNew :: Account
accNew = either (error "bad account") id (mkAccount "expenses:food")

accExisting :: Account
accExisting = either (error "bad account") id (mkAccount "assets:cash")

commJPY :: Commodity
commJPY = either (error "bad comm") id (mkCommodity "JPY")

testValidAccountNoCommodity :: Bool
testValidAccountNoCommodity =
  let intent = declareAccount accNew Expense
      result = prepareActualAccountAppend fixtureSource intent
  in case result of
       Right preview ->
         let block = candidateBlock preview
         in "account expenses:food\n  type: Expense\n" == block
       Left err -> error (show err)

testValidAccountWithCommodity :: Bool
testValidAccountWithCommodity =
  let intent = declareAccountWithDefaultCommodity accNew Expense commJPY
      result = prepareActualAccountAppend fixtureSource intent
  in case result of
       Right preview ->
         let block = candidateBlock preview
         in "account expenses:food\n  type: Expense\n  commodity: JPY\n" == block
       Left err -> error (show err)

testDuplicateAccount :: Bool
testDuplicateAccount =
  let intent = declareAccount accExisting Asset
      result = prepareActualAccountAppend fixtureSource intent
  in case result of
       Left (DuplicateDeclaration acc :| []) -> acc == accExisting
       _ -> False
