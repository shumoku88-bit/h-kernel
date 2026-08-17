{-# LANGUAGE OverloadedStrings #-}

-- | Historical Envelope identity and routing admission from the shared
-- canonical @household.toml@ source.
module HKernel.Household.EnvelopeHistory
  ( HouseholdEnvelopeHistory(..)
  , HouseholdEnvelopeHistoryReferenceError(..)
  , parseHouseholdEnvelopeHistory
  , admitHouseholdEnvelopeHistoryReferences
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.Account (AccountRegistry, mkAccount)
import HKernel.Envelope
  ( currentEnvelopePolicyDefinitions
  , envelopeDefinitionId
  )
import HKernel.Envelope.ExpenseRouting
  ( ExpenseRoute(..)
  , ExpenseRoutingDecision(..)
  , ExpenseRoutingHistory
  , ExpenseRoutingHistoryError(..)
  , ExpenseRoutingReferenceError
  , InitialExpenseRoutingDecision(..)
  , admitExpenseRoutingReferences
  , mkExpenseRoutingHistoryWithInitial
  )
import HKernel.Envelope.FulfillmentRouting
  ( FulfillmentRoute(..)
  , FulfillmentRoutingDecision(..)
  , FulfillmentRoutingHistory
  , FulfillmentRoutingHistoryError(..)
  , FulfillmentRoutingReferenceError
  , admitFulfillmentRoutingReferences
  , mkFulfillmentRoutingHistory
  )
import HKernel.Envelope.Identity
  ( EnvelopeId
  , EnvelopeRegistry
  , EnvelopeRegistryError(..)
  , envelopeIdText
  , envelopeRegistryContains
  , mkEnvelopeId
  , mkEnvelopeRegistry
  )
import HKernel.Household.Policy
  ( HouseholdPolicy
  , householdEnvelopePolicy
  )
import HKernel.Plan (PlanId, mkPlanId)
import Toml (Value, decode)
import Toml.Schema
  ( FromValue(..)
  , Result(..)
  , optKey
  , parseTableFromValue
  , reqKey
  )

data HouseholdEnvelopeHistory = HouseholdEnvelopeHistory
  { householdEnvelopeRegistry            :: EnvelopeRegistry
  , householdExpenseRoutingHistory       :: ExpenseRoutingHistory
  , householdFulfillmentRoutingHistory   :: FulfillmentRoutingHistory
  } deriving (Eq, Show)

data HouseholdEnvelopeHistoryReferenceError
  = CurrentPolicyEnvelopeMissingFromRegistry EnvelopeId
  | HouseholdExpenseRoutingReferenceError ExpenseRoutingReferenceError
  | HouseholdFulfillmentRoutingReferenceError FulfillmentRoutingReferenceError
  deriving (Eq, Show)

data RawSharedHouseholdRoot = RawSharedHouseholdRoot
  Value (Maybe Value) (Maybe Value) (Maybe RawEnvelopeHistory)

data RawEnvelopeHistory = RawEnvelopeHistory
  [Text]
  [RawExpenseRoutingDecision]
  (Maybe [RawFulfillmentRoutingDecision])

data RawExpenseRoutingDecision = RawExpenseRoutingDecision
  Text Text Text (Maybe Text) Text

data RawFulfillmentRoutingDecision = RawFulfillmentRoutingDecision
  Text Text Text (Maybe Text) Text

data ParsedExpenseRoutingDecision
  = ParsedInitial InitialExpenseRoutingDecision
  | ParsedDated ExpenseRoutingDecision

instance FromValue RawSharedHouseholdRoot where
  fromValue = parseTableFromValue
    (RawSharedHouseholdRoot
      <$> reqKey "cycle"
      <*> optKey "money"
      <*> optKey "daily-target"
      <*> optKey "envelope-history")

instance FromValue RawEnvelopeHistory where
  fromValue = parseTableFromValue
    (RawEnvelopeHistory
      <$> reqKey "identities"
      <*> reqKey "expense-routing"
      <*> optKey "fulfillment-routing")

instance FromValue RawExpenseRoutingDecision where
  fromValue = parseTableFromValue
    (RawExpenseRoutingDecision
      <$> reqKey "effective-from"
      <*> reqKey "expense-account"
      <*> reqKey "route"
      <*> optKey "target"
      <*> reqKey "note")

instance FromValue RawFulfillmentRoutingDecision where
  fromValue = parseTableFromValue
    (RawFulfillmentRoutingDecision
      <$> reqKey "effective-from"
      <*> reqKey "plan-id"
      <*> reqKey "route"
      <*> optKey "target"
      <*> reqKey "note")

parseHouseholdEnvelopeHistory
  :: Text
  -> Either [Text] (Maybe HouseholdEnvelopeHistory)
parseHouseholdEnvelopeHistory input =
  case decode input :: Result String RawSharedHouseholdRoot of
    Failure errors -> Left (map T.pack errors)
    Success warnings raw
      | null warnings -> rawToEnvelopeHistory raw
      | otherwise -> Left (map T.pack warnings)

rawToEnvelopeHistory
  :: RawSharedHouseholdRoot
  -> Either [Text] (Maybe HouseholdEnvelopeHistory)
rawToEnvelopeHistory (RawSharedHouseholdRoot _ _ _ maybeRawHistory) =
  traverse parseRawEnvelopeHistory maybeRawHistory

parseRawEnvelopeHistory
  :: RawEnvelopeHistory
  -> Either [Text] HouseholdEnvelopeHistory
parseRawEnvelopeHistory
    (RawEnvelopeHistory rawIdentities rawExpenseDecisions rawFulfillmentDecisions) = do
  identities <- collect (zipWith parseIdentity [0 :: Int ..] rawIdentities)
  parsedExpense <- collect
    (zipWith parseExpenseDecision [0 :: Int ..] rawExpenseDecisions)
  parsedFulfillment <- collect
    (zipWith parseFulfillmentDecision [0 :: Int ..]
      (maybe [] id rawFulfillmentDecisions))
  registry <- case mkEnvelopeRegistry identities of
    Right value -> Right value
    Left errors -> Left (map renderRegistryError (NonEmpty.toList errors))
  expenseRouting <- case mkExpenseRoutingHistoryWithInitial
      [decision | ParsedInitial decision <- parsedExpense]
      [decision | ParsedDated decision <- parsedExpense] of
    Right value -> Right value
    Left errors -> Left (map renderExpenseRoutingHistoryError (NonEmpty.toList errors))
  fulfillmentRouting <- case mkFulfillmentRoutingHistory parsedFulfillment of
    Right value -> Right value
    Left errors -> Left
      (map renderFulfillmentRoutingHistoryError (NonEmpty.toList errors))
  Right HouseholdEnvelopeHistory
    { householdEnvelopeRegistry = registry
    , householdExpenseRoutingHistory = expenseRouting
    , householdFulfillmentRoutingHistory = fulfillmentRouting
    }

parseIdentity :: Int -> Text -> Either [Text] EnvelopeId
parseIdentity index raw =
  case mkEnvelopeId raw of
    Right value -> Right value
    Left err -> Left
      [ indexed "envelope-history.identities" index
          <> ": invalid EnvelopeId: " <> tshow err
      ]

parseExpenseDecision
  :: Int
  -> RawExpenseRoutingDecision
  -> Either [Text] ParsedExpenseRoutingDecision
parseExpenseDecision index
    (RawExpenseRoutingDecision rawEffective rawAccount rawRoute rawTarget note) =
  case (accountResult, routeResult) of
    (Right account, Right route)
      | rawEffective == "initial" -> Right
          (ParsedInitial InitialExpenseRoutingDecision
            { initialExpenseRoutingAccount = account
            , initialExpenseRoutingRoute = route
            , initialExpenseRoutingNote = note
            })
      | otherwise -> case parseDate effectivePath rawEffective of
          Right effectiveFrom -> Right
            (ParsedDated ExpenseRoutingDecision
              { expenseRoutingEffectiveFrom = effectiveFrom
              , expenseRoutingAccount = account
              , expenseRoutingRoute = route
              , expenseRoutingNote = note
              })
          Left err -> Left [err]
    _ -> Left
      ( either pure (const []) accountResult
          ++ either pure (const []) routeResult
      )
  where
    path = indexed "envelope-history.expense-routing" index
    effectivePath = path <> ".effective-from"
    accountResult = case mkAccount rawAccount of
      Right account -> Right account
      Left err -> Left
        (path <> ".expense-account: invalid Account: " <> tshow err)
    routeResult = parseExpenseRoute path rawRoute rawTarget

parseFulfillmentDecision
  :: Int
  -> RawFulfillmentRoutingDecision
  -> Either [Text] FulfillmentRoutingDecision
parseFulfillmentDecision index
    (RawFulfillmentRoutingDecision rawEffective rawPlan rawRoute rawTarget note) =
  case (dateResult, planResult, routeResult) of
    (Right effectiveFrom, Right planId, Right route) -> Right
      FulfillmentRoutingDecision
        { fulfillmentRoutingEffectiveFrom = effectiveFrom
        , fulfillmentRoutingPlanId = planId
        , fulfillmentRoutingRoute = route
        , fulfillmentRoutingNote = note
        }
    _ -> Left
      ( either pure (const []) dateResult
          ++ either pure (const []) planResult
          ++ either pure (const []) routeResult
      )
  where
    path = indexed "envelope-history.fulfillment-routing" index
    dateResult = parseDate (path <> ".effective-from") rawEffective
    planResult = case mkPlanId rawPlan of
      Right planId -> Right planId
      Left err -> Left (path <> ".plan-id: invalid PlanId: " <> tshow err)
    routeResult = parseFulfillmentRoute path rawRoute rawTarget

parseDate :: Text -> Text -> Either Text Day
parseDate path raw =
  case parseTimeM True defaultTimeLocale "%F" (T.unpack raw) :: Maybe Day of
    Just day -> Right day
    Nothing -> Left
      (path <> ": expected ISO date; got " <> quoted raw)

parseExpenseRoute :: Text -> Text -> Maybe Text -> Either Text ExpenseRoute
parseExpenseRoute path rawRoute rawTarget = case (rawRoute, rawTarget) of
  ("managed", Just target) ->
    case mkEnvelopeId target of
      Right envelope -> Right (ManagedByEnvelope envelope)
      Left err -> Left (path <> ".target: invalid EnvelopeId: " <> tshow err)
  ("managed", Nothing) -> Left
    (path <> ".target: managed routing requires a target EnvelopeId")
  ("unmanaged", Nothing) -> Right NotEnvelopeManaged
  ("unmanaged", Just _) -> Left
    (path <> ".target: unmanaged routing must not declare a target")
  _ -> Left
    (path <> ".route: expected managed or unmanaged; got " <> quoted rawRoute)

parseFulfillmentRoute
  :: Text -> Text -> Maybe Text -> Either Text FulfillmentRoute
parseFulfillmentRoute path rawRoute rawTarget = case (rawRoute, rawTarget) of
  ("fulfills", Just target) ->
    case mkEnvelopeId target of
      Right envelope -> Right (FulfillsEnvelope envelope)
      Left err -> Left (path <> ".target: invalid EnvelopeId: " <> tshow err)
  ("fulfills", Nothing) -> Left
    (path <> ".target: fulfills routing requires a target EnvelopeId")
  ("not-target", Nothing) -> Right NotFulfillmentTarget
  ("not-target", Just _) -> Left
    (path <> ".target: not-target routing must not declare a target")
  _ -> Left
    (path <> ".route: expected fulfills or not-target; got " <> quoted rawRoute)

admitHouseholdEnvelopeHistoryReferences
  :: AccountRegistry
  -> [PlanId]
  -> HouseholdPolicy
  -> HouseholdEnvelopeHistory
  -> Either
      (NonEmpty HouseholdEnvelopeHistoryReferenceError)
      HouseholdEnvelopeHistory
admitHouseholdEnvelopeHistoryReferences accountRegistry knownPlans policy history =
  case NonEmpty.nonEmpty errors of
    Nothing -> Right history
    Just found -> Left found
  where
    registry = householdEnvelopeRegistry history
    envelopePolicy = householdEnvelopePolicy policy
    currentPolicyErrors =
      [ CurrentPolicyEnvelopeMissingFromRegistry envelope
      | definition <- currentEnvelopePolicyDefinitions envelopePolicy
      , let envelope = envelopeDefinitionId definition
      , not (envelopeRegistryContains envelope registry)
      ]
    expenseRoutingErrors = case admitExpenseRoutingReferences
        accountRegistry registry (householdExpenseRoutingHistory history) of
      Right _ -> []
      Left found ->
        map HouseholdExpenseRoutingReferenceError (NonEmpty.toList found)
    fulfillmentRoutingErrors = case admitFulfillmentRoutingReferences
        knownPlans registry (householdFulfillmentRoutingHistory history) of
      Right _ -> []
      Left found ->
        map HouseholdFulfillmentRoutingReferenceError (NonEmpty.toList found)
    errors = currentPolicyErrors
      ++ expenseRoutingErrors ++ fulfillmentRoutingErrors

collect :: [Either [Text] value] -> Either [Text] [value]
collect values = case partitionEithers values of
  ([], parsed) -> Right parsed
  (errors, _) -> Left (concat errors)

renderRegistryError :: EnvelopeRegistryError -> Text
renderRegistryError err = case err of
  DuplicateEnvelopeRegistryIdentity envelope ->
    "envelope-history.identities: duplicate EnvelopeId "
      <> quoted (envelopeIdText envelope)

renderExpenseRoutingHistoryError :: ExpenseRoutingHistoryError -> Text
renderExpenseRoutingHistoryError err = case err of
  DuplicateInitialExpenseRoutingDecision account ->
    "envelope-history.expense-routing: duplicate initial Account coordinate "
      <> tshow account
  DuplicateExpenseRoutingDecision account effectiveFrom ->
    "envelope-history.expense-routing: duplicate Account/day coordinate "
      <> tshow account <> " / " <> T.pack (show effectiveFrom)

renderFulfillmentRoutingHistoryError :: FulfillmentRoutingHistoryError -> Text
renderFulfillmentRoutingHistoryError err = case err of
  DuplicateFulfillmentRoutingDecision planId effectiveFrom ->
    "envelope-history.fulfillment-routing: duplicate PlanId/day coordinate "
      <> tshow planId <> " / " <> T.pack (show effectiveFrom)

indexed :: Text -> Int -> Text
indexed path index = path <> "[" <> T.pack (show index) <> "]"

quoted :: Text -> Text
quoted value = "‘" <> value <> "’"

tshow :: Show value => value -> Text
tshow = T.pack . show