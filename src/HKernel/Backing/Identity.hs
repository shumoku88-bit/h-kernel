module HKernel.Backing.Identity
  ( BackingPoolId
  , BackingPoolIdError(..)
  , mkBackingPoolId
  , backingPoolIdText
  ) where

import Data.Char (isControl, isSpace)
import Data.Text (Text)
import qualified Data.Text as T

-- | Stable machine identity for one group of Asset funding locations that may
-- support one or more Envelope claims.
newtype BackingPoolId = BackingPoolId { backingPoolIdText :: Text }
  deriving (Eq, Ord, Show)

data BackingPoolIdError
  = EmptyBackingPoolId
  | BackingPoolIdHasSurroundingWhitespace Text
  | BackingPoolIdContainsControlCharacter Text
  | BackingPoolIdContainsWhitespace Text
  deriving (Eq, Show)

mkBackingPoolId :: Text -> Either BackingPoolIdError BackingPoolId
mkBackingPoolId value
  | T.null value = Left EmptyBackingPoolId
  | T.strip value /= value =
      Left (BackingPoolIdHasSurroundingWhitespace value)
  | T.any isControl value =
      Left (BackingPoolIdContainsControlCharacter value)
  | T.any isSpace value = Left (BackingPoolIdContainsWhitespace value)
  | otherwise = Right (BackingPoolId value)
