{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (assertEqual, mustRight)
import qualified Data.Text as T
import HKernel.Envelope.Config
  ( parseCurrentEnvelopeConfiguration
  , renderCurrentEnvelopeConfiguration
  )
import HKernel.Envelope.Policy
  ( currentEnvelopePolicyDefinitions
  , currentExpenseAssignmentPairs
  , envelopeDefinitionLabel
  , envelopeLabelText
  )

main :: IO ()
main = do
  let (policy, backing, currentExpenses) =
        mustRight (parseCurrentEnvelopeConfiguration source)
      rendered = renderCurrentEnvelopeConfiguration policy backing currentExpenses
      reparsed = mustRight (parseCurrentEnvelopeConfiguration rendered)

  assertEqual
    "current Envelope, Backing, and Expense assignment configuration round-trips as independent owners"
    (policy, backing, currentExpenses)
    reparsed

  case currentEnvelopePolicyDefinitions policy of
    [definition] ->
      assertEqual
        "current Envelope label stays presentation evidence"
        "Everyday"
        (envelopeLabelText (envelopeDefinitionLabel definition))
    other -> error ("expected one Envelope definition, got: " ++ show other)

  assertEqual
    "current Expense assignment is admitted by its own owner"
    1
    (length (currentExpenseAssignmentPairs currentExpenses))

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
