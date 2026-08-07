-- | Compatibility import path for the Brick delivery adapter.
--
-- The interaction state itself is UI-independent and owned by
-- 'HKernel.Editor.Interaction.ActualAdd'. New delivery adapters should import
-- that module directly.
module HKernel.Editor.TUI.ActualAdd
  ( module HKernel.Editor.Interaction.ActualAdd
  ) where

import HKernel.Editor.Interaction.ActualAdd
