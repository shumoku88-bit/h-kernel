{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (assertEqual, mustRight)
import qualified Data.Text as T
import HKernel.Envelope.Config
  ( parseCurrentEnvelopeConfiguration
  , renderCurrentEnvelopeConfiguration
  )
import HKernel.Envelope.Policy
  ( envelopeDefinitionExpenseAccounts
  , envelopeDefinitionLabel
  , envelopeLabelText
  , currentEnvelopePolicyDefinitions
  )

main :: IO ()
main = do
  let (policy, backing) = mustRight (parseCurrentEnvelopeConfiguration source)
      rendered = renderCurrentEnvelopeConfiguration policy backing
      reparsed = mustRight (parseCurrentEnvelopeConfiguration rendered)

  assertEqual
    "current Envelope and Backing configuration round-trips as independent owners"
    (policy, backing)
    reparsed

  case currentEnvelopePolicyDefinitions policy of
    [definition] -> do
      assertEqual
        "current Envelope label stays presentation evidence"
        "Everyday"
        (envelopeLabelText (envelopeDefinitionLabel definition))
      assertEqual
        "current Expense assignment stays in the canonical policy owner"
        1
        (length (envelopeDefinitionExpenseAccounts definition))
    other -> error ("expected one Envelope definition, got: " ++ show other)

source :: T.Text
source = T.unlines
  [ "[[backing-pools]]"
  , "id = \"operating\""
  , "asset-accounts = [\"assets:cash\"]"
  , ""
  , "[[envelopes]]"
  , "id = \"everyday\""
  , "label = \"Everyday\""
  , "pacing = \"daily\""
  , "backing-pool = \"operating\""
  , "expense-accounts = [\"expenses:food\"]"
  ]
