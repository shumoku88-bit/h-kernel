module Main (main) where

import qualified EnvelopeCommitmentHeadroomSpec
import qualified EnvelopeConfigSpec
import qualified EnvelopeConsumptionSpec
import qualified EnvelopeEntitlementHistorySpec
import qualified EnvelopeEntitlementSpec
import qualified EnvelopeExpenseRoutingSpec
import qualified EnvelopeFulfillmentRoutingTSVSpec
import qualified EnvelopeFulfillmentSpec
import qualified EnvelopeRemainingSpec

main :: IO ()
main = do
  EnvelopeCommitmentHeadroomSpec.main
  EnvelopeConsumptionSpec.main
  EnvelopeExpenseRoutingSpec.main
  EnvelopeFulfillmentSpec.main
  EnvelopeFulfillmentRoutingTSVSpec.main
  EnvelopeEntitlementSpec.main
  EnvelopeEntitlementHistorySpec.main
  EnvelopeRemainingSpec.main
  EnvelopeConfigSpec.main
