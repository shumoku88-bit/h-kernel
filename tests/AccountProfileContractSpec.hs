{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Text as T
import HKernel.Account (mkAccount)
import HKernel.Backing.Identity (mkBackingPoolId)
import HKernel.Backing.Policy
  ( assignEnvelopeBackingPool
  , defineBackingPool
  , mkBackingPolicy
  )
import HKernel.Envelope
  ( Pacing(..)
  , defineEnvelope
  , mkCurrentEnvelopePolicy
  , mkEnvelopeLabel
  )
import HKernel.Envelope.Identity (mkEnvelopeId)
import HKernel.Household.Config (parseHouseholdConfiguration)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let foodId = mustRight (mkEnvelopeId "food")
      poolId = mustRight (mkBackingPoolId "cash")
      cash = mustRight (mkAccount "assets:cash")
      envelopePolicy = mustRight (mkCurrentEnvelopePolicy
        [defineEnvelope foodId (mustRight (mkEnvelopeLabel "Food")) Daily])
      backingPolicy = mustRight (mkBackingPolicy
        [defineBackingPool poolId [cash]]
        [assignEnvelopeBackingPool foodId poolId])

  assertRight "clean Household source is admitted"
    (parseHouseholdConfiguration envelopePolicy backingPolicy cleanSource)
  assertLeft "retired plan-destination compatibility is rejected"
    (parseHouseholdConfiguration envelopePolicy backingPolicy planDestinationSource)
  assertLeft "retired account-policy section is rejected"
    (parseHouseholdConfiguration envelopePolicy backingPolicy accountPolicySource)

cleanSource :: T.Text
cleanSource = T.unlines
  [ "[cycle]"
  , "mode = \"income-anchor\""
  , "income-account = \"income:pension\""
  , ""
  , "[budget]"
  , "opening-accounts = [\"budget:opening\"]"
  , "unassigned-accounts = [\"budget:unassigned\"]"
  , ""
  , "[[budget.envelopes]]"
  , "id = \"food\""
  , "allocation-account = \"budget:food\""
  ]

planDestinationSource :: T.Text
planDestinationSource = cleanSource <> T.unlines
  [ "plan-destination-accounts = [\"assets:cash\"]" ]

accountPolicySource :: T.Text
accountPolicySource = cleanSource <> T.unlines
  [ ""
  , "[account-policy.budget.kind]"
  , "opening = [\"budget:opening\"]"
  , "unassigned = [\"budget:unassigned\"]"
  , "spent = []"
  , "envelope = [\"budget:food\"]"
  ]

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

assertRight :: Show error => String -> Either error value -> IO ()
assertRight label result = case result of
  Right _ -> putStrLn ("  [PASS] " ++ label)
  Left err -> failTest label ("unexpected rejection: " ++ show err)

assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> putStrLn ("  [PASS] " ++ label)
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
