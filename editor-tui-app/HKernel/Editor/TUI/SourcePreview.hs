{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.SourcePreview
  ( renderSourcePreview
  , sourcePreviewText
  ) where

import Brick (Widget, txtWrap)
import Data.Text (Text)
import Data.Text qualified as T

-- | Vty cannot account for terminal tab expansion when measuring a text image.
-- Replace source separators before wrapping so a preview cannot overwrite its
-- surrounding border. The source candidate itself remains unchanged.
sourcePreviewText :: Text -> Text
sourcePreviewText = T.replace "\t" "  "

renderSourcePreview :: Text -> Widget name
renderSourcePreview = txtWrap . sourcePreviewText
