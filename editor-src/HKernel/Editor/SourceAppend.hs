{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.SourceAppend
  ( SourceBlock(..)
  , appendSourceBlock
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | One already-rendered payload intended for placement into a complete source.
--
-- This is a semantic coordinate rather than a validation claim: the producer
-- still owns block syntax and admission. Distinguishing it from complete source
-- text prevents the placement boundary from accepting those roles interchangeably.
newtype SourceBlock = SourceBlock Text
  deriving (Eq, Show)

-- | Append one already-rendered source block with a single blank separator.
--
-- The caller owns the block syntax and complete-source admission. This helper
-- owns only the physical placement rule shared by the current append editors.
appendSourceBlock :: Text -> SourceBlock -> Text
appendSourceBlock existing (SourceBlock block)
  | T.null existing = block
  | "\n" `T.isSuffixOf` existing = existing <> "\n" <> block
  | otherwise = existing <> "\n\n" <> block
