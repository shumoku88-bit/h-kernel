module HKernel.Editor.TUI.Scroll
  ( ScrollAxes(..)
  , listWheelEvent
  , standardHorizontalWheelStep
  , standardWheelStep
  , viewportWheelHandler
  ) where

import Brick
import Graphics.Vty qualified as V

-- | Presentation-only scroll capability. A surface still owns what scrolling
-- means; this module only translates common mouse input into Brick movement.
data ScrollAxes
  = VerticalOnly
  | VerticalAndHorizontal
  deriving (Eq, Show)

standardWheelStep :: Int
standardWheelStep = 3

standardHorizontalWheelStep :: Int
standardHorizontalWheelStep = 4

-- | Translate mouse wheel input over one viewport into a Brick scroll action.
-- Shift-wheel is horizontal only for two-dimensional viewports. Keeping the
-- policy here prevents individual surfaces from growing their own wheel steps.
viewportWheelHandler
  :: Ord name
  => name
  -> ScrollAxes
  -> BrickEvent name event
  -> Maybe (EventM name state ())
viewportWheelHandler target axes event = case event of
  MouseDown name V.BScrollUp modifiers _
    | name == target -> Just (scroll (-1) modifiers)
  MouseDown name V.BScrollDown modifiers _
    | name == target -> Just (scroll 1 modifiers)
  _ -> Nothing
  where
    scroller = viewportScroll target
    scroll direction modifiers
      | axes == VerticalAndHorizontal && V.MShift `elem` modifiers =
          hScrollBy scroller (direction * standardHorizontalWheelStep)
      | otherwise =
          vScrollBy scroller (direction * standardWheelStep)

-- | Convert list wheel input into the same Vty event used by keyboard
-- navigation. The list owner remains responsible for selection changes and
-- any semantic consequences of changing that selection.
listWheelEvent
  :: Eq name
  => name
  -> BrickEvent name event
  -> Maybe V.Event
listWheelEvent target event = case event of
  MouseDown name V.BScrollUp _ _
    | name == target -> Just (V.EvKey V.KUp [])
  MouseDown name V.BScrollDown _ _
    | name == target -> Just (V.EvKey V.KDown [])
  _ -> Nothing
