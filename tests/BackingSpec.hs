{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import HKernel.Account
import HKernel.Backing
import HKernel.Backing.Identity
import HKernel.Backing.Policy
import HKernel.Envelope.Identity
  ( EnvelopeId
  , mkEnvelopeId
  , mkEnvelopeRegistry
  )
import HKernel.Money
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeMatchingEnvelopeCommitment
  characterizeExternalFundingCommitment
  preservePoolLocalShortage
  preserveCommodityCoordinates
  rejectDuplicateEnvelopeClaim
  characterizePoolIdentity
  characterizeBackingPolicy
  characterizeBackingPolicyReferences
  characterizeBackingPolicyAccounts

characterizeMatchingEnvelopeCommitment :: IO ()
characterizeMatchingEnvelopeCommitment = do
  let jpy = commodity "JPY"
      position = mustRight (deriveBackingPoolPosition
        (pool "living")
        (one jpy 200)
        (one jpy 30)
        [ claim "food" (one jpy 100) (one jpy 70)
        , claim "overspent" (one jpy (-20)) (one jpy (-20))
        ])

  equal "gross funding remains recorded independently"
    (one jpy 200)
    (backingPoolFundingBalance position)
  equal "open source-Asset Plan reduces available funding"
    (one jpy 170)
    (backingPoolAvailableFunding position)
  equal "negative Envelope evidence does not offset another positive gross claim"
    (one jpy 100)
    (backingPoolGrossEnvelopeRequired position)
  equal "matching Envelope commitment reduces available claim"
    (one jpy 70)
    (backingPoolAvailableEnvelopeRequired position)
  equal "matching funding/Envelope commitment is not double-counted in surplus"
    (one jpy 100)
    (backingPoolAvailableSurplus position)
  equal "gross and available surplus agree for a matching same-pool commitment"
    (backingPoolGrossSurplus position)
    (backingPoolAvailableSurplus position)

characterizeExternalFundingCommitment :: IO ()
characterizeExternalFundingCommitment = do
  let jpy = commodity "JPY"
      position = mustRight (deriveBackingPoolPosition
        (pool "living")
        (one jpy 200)
        (one jpy 50)
        [claim "food" (one jpy 100) (one jpy 100)])

  equal "non-Envelope outgoing Plan can reduce funding without reducing claim"
    (one jpy 50)
    (backingPoolAvailableSurplus position)
  equal "gross position remains separate from future funding commitment"
    (one jpy 100)
    (backingPoolGrossSurplus position)

preservePoolLocalShortage :: IO ()
preservePoolLocalShortage = do
  let jpy = commodity "JPY"
      shortPool = mustRight (deriveBackingPoolPosition
        (pool "cash")
        (one jpy 60)
        emptyBalance
        [claim "daily" (one jpy 80) (one jpy 80)])
      richPool = mustRight (deriveBackingPoolPosition
        (pool "savings")
        (one jpy 200)
        emptyBalance
        [claim "reserve" (one jpy 100) (one jpy 100)])

  equal "one pool's shortage remains explicit"
    (one jpy (-20))
    (backingPoolGrossSurplus shortPool)
  equal "another pool's surplus does not erase the local shortage"
    (one jpy 100)
    (backingPoolGrossSurplus richPool)

preserveCommodityCoordinates :: IO ()
preserveCommodityCoordinates = do
  let jpy = commodity "JPY"
      usd = commodity "USD"
      position = mustRight (deriveBackingPoolPosition
        (pool "mixed")
        (balances [(jpy, 100), (usd, 50)])
        (balances [(jpy, 10), (usd, 5)])
        [ BackedEnvelopeClaim
            (envelope "travel")
            (balances [(jpy, 40), (usd, 20)])
            (balances [(jpy, 30), (usd, 15)])
        ])

  equal "pool arithmetic keeps commodities independent"
    (balances [(jpy, 60), (usd, 30)])
    (backingPoolAvailableSurplus position)

rejectDuplicateEnvelopeClaim :: IO ()
rejectDuplicateEnvelopeClaim = do
  let jpy = commodity "JPY"
      poolId = pool "living"
      food = claim "food" (one jpy 10) (one jpy 10)

  leftSatisfies
    "same Envelope cannot be counted twice inside one pool"
    (any (== DuplicateBackedEnvelopeClaim poolId (envelope "food"))
      . NonEmpty.toList)
    (deriveBackingPoolPosition poolId (one jpy 100) emptyBalance [food, food])

characterizePoolIdentity :: IO ()
characterizePoolIdentity = do
  left "empty BackingPoolId is rejected" (mkBackingPoolId "")
  left "whitespace inside BackingPoolId is rejected" (mkBackingPoolId "cash pool")
  equal "stable BackingPoolId round-trips exact text"
    "living"
    (backingPoolIdText (pool "living"))

characterizeBackingPolicy :: IO ()
characterizeBackingPolicy = do
  let operating = pool "operating"
      reserve = pool "reserve"
      food = envelope "food"
      savings = envelope "savings"
      cash = account "assets:cash"
      bank = account "assets:bank"
      pools =
        [ defineBackingPool operating [cash]
        , defineBackingPool reserve [bank]
        ]
      assignments =
        [ assignEnvelopeBackingPool food operating
        , assignEnvelopeBackingPool savings reserve
        ]
      policy = mustRight (mkBackingPolicy pools assignments)

  equal "Envelope backing lookup is owned by Backing policy"
    (Just operating)
    (backingPolicyPoolForEnvelope food policy)
  equal "Asset membership lookup is owned by Backing policy"
    (Just reserve)
    (backingPolicyPoolForAsset bank policy)
  equal "source-order pool definitions remain available"
    pools
    (backingPolicyPoolDefinitions policy)
  equal "source-order Envelope assignments remain available"
    assignments
    (backingPolicyEnvelopeAssignments policy)

  right "empty Backing policy is valid before household policy requires funding"
    (mkBackingPolicy [] [])

  leftSatisfies "duplicate pool definition fails closed"
    (any isDuplicatePool . NonEmpty.toList)
    (mkBackingPolicy
      [ defineBackingPool operating [cash]
      , defineBackingPool operating [bank]
      ]
      [])

  leftSatisfies "declared pool without Asset members fails closed"
    (any isEmptyPool . NonEmpty.toList)
    (mkBackingPolicy [defineBackingPool operating []] [])

  leftSatisfies "one Asset cannot silently belong to two pools"
    (any isDuplicateAsset . NonEmpty.toList)
    (mkBackingPolicy
      [ defineBackingPool operating [cash]
      , defineBackingPool reserve [cash]
      ]
      [])

  leftSatisfies "one Envelope cannot silently receive two current backing pools"
    (any isDuplicateEnvelope . NonEmpty.toList)
    (mkBackingPolicy
      pools
      [ assignEnvelopeBackingPool food operating
      , assignEnvelopeBackingPool food reserve
      ])

  leftSatisfies "Envelope assignment to unknown pool fails locally"
    (any isUnknownPool . NonEmpty.toList)
    (mkBackingPolicy
      [defineBackingPool operating [cash]]
      [assignEnvelopeBackingPool food reserve])
  where
    isDuplicatePool err = case err of
      DuplicateBackingPoolDefinition actual -> actual == pool "operating"
      _ -> False
    isEmptyPool err = case err of
      BackingPoolHasNoAssetAccounts actual -> actual == pool "operating"
      _ -> False
    isDuplicateAsset err = case err of
      DuplicateAssetAccountMembership actualAccount firstPool repeatedPool ->
        actualAccount == account "assets:cash"
          && firstPool == pool "operating"
          && repeatedPool == pool "reserve"
      _ -> False
    isDuplicateEnvelope err = case err of
      DuplicateEnvelopeBackingAssignment actualEnvelope firstPool repeatedPool ->
        actualEnvelope == envelope "food"
          && firstPool == pool "operating"
          && repeatedPool == pool "reserve"
      _ -> False
    isUnknownPool err = case err of
      EnvelopeReferencesUnknownBackingPool actualEnvelope actualPool ->
        actualEnvelope == envelope "food" && actualPool == pool "reserve"
      _ -> False

characterizeBackingPolicyReferences :: IO ()
characterizeBackingPolicyReferences = do
  let operating = pool "operating"
      historical = envelope "historical"
      missing = envelope "missing"
      cash = account "assets:cash"
      registry = mustRight (mkEnvelopeRegistry [historical])
      knownPolicy = mustRight (mkBackingPolicy
        [defineBackingPool operating [cash]]
        [assignEnvelopeBackingPool historical operating])
      missingPolicy = mustRight (mkBackingPolicy
        [defineBackingPool operating [cash]]
        [assignEnvelopeBackingPool missing operating])

  right "registered historical Envelope remains a valid Backing coordinate"
    (validateBackingPolicyEnvelopeReferences registry knownPolicy)
  equal "unknown Envelope assignment is rejected by stable Registry"
    (Left (UnknownBackingPolicyEnvelope missing operating NonEmpty.:| []))
    (validateBackingPolicyEnvelopeReferences registry missingPolicy)

characterizeBackingPolicyAccounts :: IO ()
characterizeBackingPolicyAccounts = do
  let operating = pool "operating"
      cash = account "assets:cash"
      foodExpense = account "expenses:food"
      missing = account "assets:missing"
      validPolicy = mustRight (mkBackingPolicy
        [defineBackingPool operating [cash]] [])
      wrongRolePolicy = mustRight (mkBackingPolicy
        [defineBackingPool operating [foodExpense]] [])
      missingPolicy = mustRight (mkBackingPolicy
        [defineBackingPool operating [missing]] [])
      registry = mustRight
        ( registerAccount (declareAccount foodExpense Expense)
        =<< registerAccount (declareAccount cash Asset) emptyAccountRegistry
        )

  right "declared Asset member qualifies Backing policy"
    (validateBackingPolicyAccounts registry validPolicy)
  equal "declared non-Asset member fails with its actual role"
    (Left
      ( BackingPolicyAssetAccountNotAsset operating foodExpense Expense
        NonEmpty.:| []
      ))
    (validateBackingPolicyAccounts registry wrongRolePolicy)
  equal "undeclared funding Account fails closed"
    (Left
      ( BackingPolicyAssetAccountUndeclared operating missing
        NonEmpty.:| []
      ))
    (validateBackingPolicyAccounts registry missingPolicy)

claim :: Text -> Balance -> Balance -> BackedEnvelopeClaim
claim name remaining headroom = BackedEnvelopeClaim
  { backedEnvelopeId = envelope name
  , backedEnvelopeRemaining = remaining
  , backedEnvelopeHeadroom = headroom
  }

account :: Text -> Account
account = mustRight . mkAccount

pool :: Text -> BackingPoolId
pool = mustRight . mkBackingPoolId

envelope :: Text -> EnvelopeId
envelope = mustRight . mkEnvelopeId

commodity :: Text -> Commodity
commodity = mustRight . mkCommodity

one :: Commodity -> Integer -> Balance
one unit quantity = singletonBalance
  (mkAmount unit (quantityFromInteger quantity))

balances :: [(Commodity, Integer)] -> Balance
balances = balanceFromAmounts
  . map (\(unit, quantity) -> mkAmount unit (quantityFromInteger quantity))

left :: Show value => String -> Either error value -> IO ()
left label result = case result of
  Left _ -> pass label
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

leftSatisfies
  :: Show value
  => String
  -> (error -> Bool)
  -> Either error value
  -> IO ()
leftSatisfies label predicate result = case result of
  Left err
    | predicate err -> pass label
    | otherwise -> failTest label "rejected for the wrong reason"
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

right :: Show error => String -> Either error value -> IO ()
right label result = case result of
  Right _ -> pass label
  Left err -> failTest label ("unexpectedly rejected: " ++ show err)

equal :: (Eq value, Show value) => String -> value -> value -> IO ()
equal label expected actual
  | expected == actual = pass label
  | otherwise = failTest label
      ("expected " ++ show expected ++ ", but got " ++ show actual)

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

pass :: String -> IO ()
pass label = putStrLn ("  [PASS] " ++ label)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
