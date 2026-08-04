{-# LANGUAGE OverloadedStrings #-}

-- | Exact monetary quantities and multi-commodity balances.
--
-- Constructors are intentionally hidden. In particular, 'Amount' has no
-- 'Num' instance: adding amounts of different commodities must go through a
-- 'Balance', where each commodity is kept separate.
module HKernel.Money
  ( Commodity
  , CommodityError(..)
  , mkCommodity
  , commodityCode
  , Quantity
  , QuantityError(..)
  , parseQuantity
  , quantityFromInteger
  , renderQuantity
  , quantityToRational
  , zeroQuantity
  , addQuantity
  , negateQuantity
  , isZeroQuantity
  , Amount
  , mkAmount
  , amountCommodity
  , amountQuantity
  , negateAmount
  , Balance
  , emptyBalance
  , singletonBalance
  , balanceFromAmounts
  , sumBalances
  , addBalance
  , subtractBalance
  , negateBalance
  , lookupBalance
  , balanceEntries
  , isZeroBalance
  ) where

import Data.Char (isSpace)
import qualified Data.Foldable as Foldable
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Scientific (Scientific, formatScientific, FPFormat(Fixed))
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

-- | A runtime commodity identifier such as @JPY@, @USD@, or @BTC@.
--
-- It is deliberately not restricted to ISO 4217: accounting journals often
-- contain funds, securities, and user-defined commodities as well as money.
newtype Commodity = Commodity { commodityCode :: Text }
  deriving (Eq, Ord, Show)

data CommodityError
  = EmptyCommodity
  | CommodityContainsWhitespace Text
  deriving (Eq, Show)

-- | Validate a commodity identifier.
mkCommodity :: Text -> Either CommodityError Commodity
mkCommodity code
  | T.null code        = Left EmptyCommodity
  | T.any isSpace code = Left (CommodityContainsWhitespace code)
  | otherwise          = Right (Commodity code)

-- | An exact base-10 quantity. Unlike 'Double', values such as 0.1 are not
-- approximated in binary floating point.
newtype Quantity = Quantity Scientific
  deriving (Eq, Ord)

instance Show Quantity where
  show = T.unpack . renderQuantity

data QuantityError = InvalidQuantity Text
  deriving (Eq, Show)

parseQuantity :: Text -> Either QuantityError Quantity
parseQuantity input =
  case readMaybe (T.unpack input) of
    Just value -> Right (Quantity value)
    Nothing    -> Left (InvalidQuantity input)

quantityFromInteger :: Integer -> Quantity
quantityFromInteger = Quantity . fromInteger

renderQuantity :: Quantity -> Text
renderQuantity (Quantity value)
  | value == 0 = "0"
  | otherwise = trimFractionalZeros
      (T.pack (formatScientific Fixed Nothing value))
  where
    trimFractionalZeros rendered = case T.breakOn "." rendered of
      (_, fraction) | T.null fraction -> rendered
      (whole, fraction) ->
        let trimmed = T.dropWhileEnd (== '0') (T.drop 1 fraction)
        in if T.null trimmed then whole else whole <> "." <> trimmed

-- | Expose the exact rational represented by a finite decimal quantity.
quantityToRational :: Quantity -> Rational
quantityToRational (Quantity value) = toRational value

zeroQuantity :: Quantity
zeroQuantity = quantityFromInteger 0

addQuantity :: Quantity -> Quantity -> Quantity
addQuantity (Quantity x) (Quantity y) = Quantity (x + y)

negateQuantity :: Quantity -> Quantity
negateQuantity (Quantity value) = Quantity (negate value)

isZeroQuantity :: Quantity -> Bool
isZeroQuantity quantity = quantity == zeroQuantity

-- | A quantity tagged with exactly one commodity.
data Amount = Amount
  { amountCommodity :: Commodity
  , amountQuantity  :: Quantity
  } deriving (Eq, Show)

mkAmount :: Commodity -> Quantity -> Amount
mkAmount = Amount

negateAmount :: Amount -> Amount
negateAmount (Amount commodity quantity) =
  Amount commodity (negateQuantity quantity)

-- | A canonical multi-commodity balance.
--
-- Zero entries are removed by every constructor and operation, so an empty map
-- is the unique representation of a zero balance. Balance addition is lawful
-- and context-free: it combines equal commodities independently and therefore
-- forms a commutative monoid under '<>'. 'negateBalance' supplies the additive
-- inverse without pretending that a single-commodity 'Amount' is itself
-- universally addable.
newtype Balance = Balance (Map Commodity Quantity)
  deriving (Eq, Show)

instance Semigroup Balance where
  (<>) = combineBalance

instance Monoid Balance where
  mempty = emptyBalance

emptyBalance :: Balance
emptyBalance = Balance Map.empty

singletonBalance :: Amount -> Balance
singletonBalance (Amount commodity quantity)
  | isZeroQuantity quantity = emptyBalance
  | otherwise               = Balance (Map.singleton commodity quantity)

-- | Lift every single-commodity amount into the Balance monoid and combine it.
balanceFromAmounts :: Foldable f => f Amount -> Balance
balanceFromAmounts = Foldable.foldMap singletonBalance

-- | Combine a collection of canonical balances using their lawful monoid.
sumBalances :: Foldable f => f Balance -> Balance
sumBalances = Foldable.fold

-- | Named domain spelling for Balance composition.
--
-- The operator '<>' and this function have exactly the same semantics. The
-- named form remains useful where accounting prose reads more clearly than an
-- operator.
addBalance :: Balance -> Balance -> Balance
addBalance = (<>)

subtractBalance :: Balance -> Balance -> Balance
subtractBalance left right = left <> negateBalance right

negateBalance :: Balance -> Balance
negateBalance (Balance entries) = Balance (Map.map negateQuantity entries)

lookupBalance :: Commodity -> Balance -> Quantity
lookupBalance commodity (Balance entries) =
  Map.findWithDefault zeroQuantity commodity entries

balanceEntries :: Balance -> [(Commodity, Quantity)]
balanceEntries (Balance entries) = Map.toAscList entries

isZeroBalance :: Balance -> Bool
isZeroBalance (Balance entries) = Map.null entries

combineBalance :: Balance -> Balance -> Balance
combineBalance (Balance left) (Balance right) =
  Balance
    (Map.filter
      (not . isZeroQuantity)
      (Map.unionWith addQuantity left right))
