-- | Brick-local compatibility import path.
--
-- The interaction state itself is UI-independent and owned by
-- 'HKernel.Editor.Interaction.ActualAdd'. New delivery adapters should import
-- that module directly. This shim remains local to the Brick executable until
-- its current monolithic Main module is split.
module HKernel.Editor.TUI.ActualAdd
  ( module HKernel.Editor.Interaction.ActualAdd
  ) where

import HKernel.Editor.Interaction.ActualAdd
