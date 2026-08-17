{-# LANGUAGE OverloadedStrings #-}

module EnvelopeConfigSpec (main) where

import Test.Support (assertEqual, mustRight)
import qualified Data.Text as T
import HKernel.Envelope.Config
  ( parseCurrentEnvelopeConfiguration
  , renderCurrentEnvelopeConfiguration
  )
import HKernel.Envelope.Policy
  ( currentEnvelopePolicyDefinitions
  , envelopeDefinitionLabel
  , envelopeLabelText
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
    [definition] ->
      assertEqual
        "current Envelope label stays presentation evidence"
        "Everyday"
        (envelopeLabelText (envelopeDefinitionLabel definition))
    other -> error ("expected one Envelope definition, got: " ++ show other)

  case parseCurrentEnvelopeConfiguration legacyExpenseSource of
    Left _ -> pure ()
    Right _ -> error "expense-accounts must no longer be admitted by envelope.toml"

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
  ]

legacyExpenseSource :: T.Text
legacyExpenseSource = source <>
  "expense-accounts = [\"expenses:food\"]\n"
