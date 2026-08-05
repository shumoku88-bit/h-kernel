{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.SourceAppend
  ( appendSourceBlock
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Append one already-rendered source block with a single blank separator.
--
-- The caller owns the block syntax and complete-source admission. This helper
-- owns only the physical placement rule shared by the current append editors.
appendSourceBlock :: Text -> Text -> Text
appendSourceBlock existing block
  | T.null existing = block
  | "\n" `T.isSuffixOf` existing = existing <> "\n" <> block
  | otherwise = existing <> "\n\n" <> block
