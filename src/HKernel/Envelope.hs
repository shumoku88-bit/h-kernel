{-# LANGUAGE OverloadedStrings #-}

-- | Typed envelope policy and pure budget reporting.
--
-- Envelope policy is deliberately outside the accounting kernel. A validated
-- 'Journal' supplies accounting facts; this module supplies the separate policy
-- that assigns expense accounts to envelopes and grants exact entitlements.
module HKernel.Envelope
  ( EnvelopeName
  , EnvelopeNameError(..)
  , mkEnvelopeName
  , envelopeNameText
  , EnvelopePolicy
  , EnvelopePolicyError(..)
  , EnvelopePolicyErrorReason(..)
  , parseEnvelopePolicy
  , EnvelopeBudgetError(..)
  , EnvelopeBudgetErrorReason(..)
  , EnvelopeBudgetLine
  , envelopeBudgetEnvelope
  , envelopeBudgetEntitlement
  , envelopeBudgetConsumption
  , envelopeBudgetRemaining
  , EnvelopeAccountBalance
  , envelopeAccount
  , envelopeAccountBalance
  , EnvelopeBudgetReport
  , envelopeBudgetRange
  , envelopeBudgetLines
  , envelopeBudgetUnassignedExpenses
  , envelopeBudgetUnclassifiedAccounts
  , envelopeBudget
  ) where

import Data.Char (isControl)
import Data.Either (partitionEithers)
import qualified Data.Foldable as Foldable
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Account
import HKernel.Engine
import HKernel.Journal (Journal, journalAccountRegistry)
import HKernel.Money

-- | Human-readable envelope identity.
newtype EnvelopeName = EnvelopeName Text
  deriving (Eq, Ord, Show)

data EnvelopeNameError
  = EmptyEnvelopeName
  | EnvelopeNameHasSurroundingWhitespace Text
  | EnvelopeNameContainsControlCharacter Text
  deriving (Eq, Show)

mkEnvelopeName :: Text -> Either EnvelopeNameError EnvelopeName
mkEnvelopeName name
  | T.null name          = Left EmptyEnvelopeName
  | T.strip name /= name = Left (EnvelopeNameHasSurroundingWhitespace name)
  | T.any isControl name = Left (EnvelopeNameContainsControlCharacter name)
  | otherwise            = Right (EnvelopeName name)

envelopeNameText :: EnvelopeName -> Text
envelopeNameText (EnvelopeName name) = name

-- | Validated external policy.
--
-- Every assignment points to an allocated envelope. Each envelope may have one
-- entitlement per commodity, and each account may be assigned at most once.
-- Assignment source lines are retained for cross-checks against the Journal.
data EnvelopePolicy = EnvelopePolicy
  { policyAllocations :: Map EnvelopeName Balance
  , policyAssignments :: Map Account (Int, EnvelopeName)
  } deriving (Eq, Show)

data EnvelopePolicyError = EnvelopePolicyError
  { envelopePolicyErrorLine   :: Int
  , envelopePolicyErrorReason :: EnvelopePolicyErrorReason
  } deriving (Eq, Show)

data EnvelopePolicyErrorReason
  = InvalidEnvelopePolicyRow Text
  | InvalidEnvelopePolicyEnvelope EnvelopeNameError
  | InvalidEnvelopePolicyAccount AccountError
  | InvalidEnvelopePolicyQuantity QuantityError
  | InvalidEnvelopePolicyCommodity CommodityError
  | NegativeEnvelopeAllocation EnvelopeName Amount
  | DuplicateEnvelopeAllocation EnvelopeName Commodity
  | DuplicateEnvelopeAssignment Account
  | AssignmentToUnallocatedEnvelope EnvelopeName
  deriving (Eq, Show)

-- | Parse a small tab-separated envelope policy language.
--
-- Supported rows are:
--
-- @allocation<TAB>ENVELOPE<TAB>QUANTITY<TAB>COMMODITY@
--
-- @assignment<TAB>ACCOUNT<TAB>ENVELOPE@
--
-- Blank lines and lines beginning with @#@ are ignored.
parseEnvelopePolicy
  :: Text
  -> Either (NonEmpty EnvelopePolicyError) EnvelopePolicy
parseEnvelopePolicy input =
  case NonEmpty.nonEmpty errors of
    Just nonEmptyErrors -> Left nonEmptyErrors
    Nothing             -> Right policy
  where
    locatedLines = zip [1..] (T.lines input)
    meaningfulLines = filter (not . ignored . snd) locatedLines
    (rowErrors, entries) = partitionEithers (map parsePolicyLine meaningfulLines)
    (policyErrors, policy) = buildEnvelopePolicy entries
    errors = rowErrors ++ policyErrors

    ignored line =
      let stripped = T.strip line
      in T.null stripped || "#" `T.isPrefixOf` stripped

data ParsedPolicyEntry
  = ParsedAllocation Int EnvelopeName Amount
  | ParsedAssignment Int Account EnvelopeName

parsePolicyLine
  :: (Int, Text)
  -> Either EnvelopePolicyError ParsedPolicyEntry
parsePolicyLine (lineNumber, line) =
  case T.splitOn "\t" line of
    ["allocation", envelopeText, quantityText, commodityText] -> do
      envelope <- mapPolicyError lineNumber InvalidEnvelopePolicyEnvelope
        (mkEnvelopeName envelopeText)
      quantity <- mapPolicyError lineNumber InvalidEnvelopePolicyQuantity
        (parseQuantity quantityText)
      commodity <- mapPolicyError lineNumber InvalidEnvelopePolicyCommodity
        (mkCommodity commodityText)
      let amount = mkAmount commodity quantity
      if quantity < zeroQuantity
        then Left (atPolicyLine lineNumber
          (NegativeEnvelopeAllocation envelope amount))
        else Right (ParsedAllocation lineNumber envelope amount)
    ["assignment", accountText, envelopeText] -> do
      account <- mapPolicyError lineNumber InvalidEnvelopePolicyAccount
        (mkAccount accountText)
      envelope <- mapPolicyError lineNumber InvalidEnvelopePolicyEnvelope
        (mkEnvelopeName envelopeText)
      Right (ParsedAssignment lineNumber account envelope)
    _ -> Left (atPolicyLine lineNumber (InvalidEnvelopePolicyRow line))

mapPolicyError
  :: Int
  -> (error -> EnvelopePolicyErrorReason)
  -> Either error value
  -> Either EnvelopePolicyError value
mapPolicyError lineNumber wrap result = case result of
  Left err    -> Left (atPolicyLine lineNumber (wrap err))
  Right value -> Right value

atPolicyLine :: Int -> EnvelopePolicyErrorReason -> EnvelopePolicyError
atPolicyLine = EnvelopePolicyError

data PolicyBuild = PolicyBuild
  { buildAllocations    :: Map EnvelopeName Balance
  , buildAllocationKeys :: Set (EnvelopeName, Commodity)
  , buildAssignments    :: Map Account (Int, EnvelopeName)
  , buildErrors         :: [EnvelopePolicyError]
  }

buildEnvelopePolicy
  :: [ParsedPolicyEntry]
  -> ([EnvelopePolicyError], EnvelopePolicy)
buildEnvelopePolicy entries =
  (reverse (buildErrors built) ++ missingAllocationErrors, policy)
  where
    built = Foldable.foldl' addEntry emptyPolicyBuild entries
    allocations = buildAllocations built
    assignments = buildAssignments built
    missingAllocationErrors =
      [ atPolicyLine lineNumber (AssignmentToUnallocatedEnvelope envelope)
      | (_, (lineNumber, envelope)) <- Map.toAscList assignments
      , Map.notMember envelope allocations
      ]
    policy = EnvelopePolicy allocations assignments

    addEntry state entry = case entry of
      ParsedAllocation lineNumber envelope amount ->
        let key = (envelope, amountCommodity amount)
        in if Set.member key (buildAllocationKeys state)
          then state
            { buildErrors = atPolicyLine lineNumber
                (DuplicateEnvelopeAllocation envelope (amountCommodity amount))
                : buildErrors state
            }
          else state
            { buildAllocations = Map.alter
                (Just . addBalance (singletonBalance amount)
                  . maybe emptyBalance id)
                envelope
                (buildAllocations state)
            , buildAllocationKeys = Set.insert key (buildAllocationKeys state)
            }
      ParsedAssignment lineNumber account envelope ->
        if Map.member account (buildAssignments state)
          then state
            { buildErrors = atPolicyLine lineNumber
                (DuplicateEnvelopeAssignment account)
                : buildErrors state
            }
          else state
            { buildAssignments = Map.insert account (lineNumber, envelope)
                (buildAssignments state)
            }

emptyPolicyBuild :: PolicyBuild
emptyPolicyBuild = PolicyBuild
  { buildAllocations = Map.empty
  , buildAllocationKeys = Set.empty
  , buildAssignments = Map.empty
  , buildErrors = []
  }

data EnvelopeBudgetError = EnvelopeBudgetError
  { envelopeBudgetErrorLine   :: Int
  , envelopeBudgetErrorReason :: EnvelopeBudgetErrorReason
  } deriving (Eq, Show)

data EnvelopeBudgetErrorReason
  = EnvelopeAssignedAccountUndeclared Account
  | EnvelopeAssignedAccountNotExpense Account AccountType
  deriving (Eq, Show)

-- | Irreducible facts for one envelope. Remaining is derived.
data EnvelopeBudgetLine = EnvelopeBudgetLine
  { envelopeBudgetEnvelope    :: EnvelopeName
  , envelopeBudgetEntitlement :: Balance
  , envelopeBudgetConsumption :: Balance
  } deriving (Eq, Show)

envelopeBudgetRemaining :: EnvelopeBudgetLine -> Balance
envelopeBudgetRemaining line =
  subtractBalance
    (envelopeBudgetEntitlement line)
    (envelopeBudgetConsumption line)

data EnvelopeAccountBalance = EnvelopeAccountBalance
  { envelopeAccount        :: Account
  , envelopeAccountBalance :: Balance
  } deriving (Eq, Show)

-- | Envelope budget for one explicit date range.
--
-- Unassigned expense accounts and programmatic accounts without metadata remain
-- visible even when their activity nets to zero.
data EnvelopeBudgetReport = EnvelopeBudgetReport
  { envelopeBudgetRange                :: DateRange
  , envelopeBudgetLines                :: [EnvelopeBudgetLine]
  , envelopeBudgetUnassignedExpenses   :: [EnvelopeAccountBalance]
  , envelopeBudgetUnclassifiedAccounts :: [EnvelopeAccountBalance]
  } deriving (Eq, Show)

envelopeBudget
  :: DateRange
  -> EnvelopePolicy
  -> Journal
  -> Either (NonEmpty EnvelopeBudgetError) EnvelopeBudgetReport
envelopeBudget dateRange policy journal =
  case NonEmpty.nonEmpty assignmentErrors of
    Just errors -> Left errors
    Nothing     -> Right report
  where
    registry = journalAccountRegistry journal
    assignmentsWithLines = policyAssignments policy
    assignments = Map.map snd assignmentsWithLines
    assignmentErrors = concatMap validateAssignment
      (Map.toAscList assignmentsWithLines)

    validateAssignment (account, (lineNumber, _)) =
      case lookupAccountDeclaration account registry of
        Nothing ->
          [ EnvelopeBudgetError lineNumber
              (EnvelopeAssignedAccountUndeclared account)
          ]
        Just declaration
          | declaredAccountType declaration == Expense -> []
          | otherwise ->
              [ EnvelopeBudgetError lineNumber
                  (EnvelopeAssignedAccountNotExpense
                    account
                    (declaredAccountType declaration))
              ]

    report = EnvelopeBudgetReport
      { envelopeBudgetRange = dateRange
      , envelopeBudgetLines =
          [ EnvelopeBudgetLine
              envelope
              entitlement
              (Map.findWithDefault emptyBalance envelope consumptionByEnvelope)
          | (envelope, entitlement) <- Map.toAscList (policyAllocations policy)
          ]
      , envelopeBudgetUnassignedExpenses = map toAccountBalance
          (filter isUnassignedExpense balances)
      , envelopeBudgetUnclassifiedAccounts = map toAccountBalance
          (filter isUnclassified balances)
      }

    entries = entriesInRange dateRange journal
    consumptionByEnvelope = Foldable.foldl' addConsumption Map.empty entries
    balances = Map.toAscList
      (Foldable.foldl' addAccountBalance Map.empty entries)

    addConsumption totals entry =
      case Map.lookup (entryAccount entry) assignments of
        Nothing -> totals
        Just envelope -> Map.alter
          (Just . addBalance (singletonBalance (entryAmount entry))
            . maybe emptyBalance id)
          envelope
          totals

    addAccountBalance totals entry = Map.alter
      (Just . addBalance (singletonBalance (entryAmount entry))
        . maybe emptyBalance id)
      (entryAccount entry)
      totals

    isUnassignedExpense (account, _) =
      accountTypeFor account registry == Just Expense
        && Map.notMember account assignments

    isUnclassified (account, _) =
      accountTypeFor account registry == Nothing

    toAccountBalance (account, balance) =
      EnvelopeAccountBalance account balance
