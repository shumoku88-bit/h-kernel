{-# LANGUAGE OverloadedStrings #-}

-- | Presentation-only urgency for dated workspace items.
--
-- The observation day is explicit: calendar selection and entry dates do not
-- silently change whether an item is presented as due today or overdue.
module HKernel.Editor.TUI.DateUrgency
  ( DateUrgency(..)
  , dateDueTodayAttr
  , dateOverdueAttr
  , dateUrgencyAt
  , withDateUrgency
  ) where

import Brick (AttrName, Widget, attrName, withAttr)
import Data.Time.Calendar (Day)

data DateUrgency
  = DateUpcoming
  | DateDueToday
  | DateOverdue
  deriving (Eq, Show)

dateDueTodayAttr :: AttrName
dateDueTodayAttr = attrName "dueToday"

dateOverdueAttr :: AttrName
dateOverdueAttr = attrName "dueOverdue"

dateUrgencyAt :: Day -> Day -> DateUrgency
dateUrgencyAt observedOn dueOn
  | dueOn < observedOn = DateOverdue
  | dueOn == observedOn = DateDueToday
  | otherwise = DateUpcoming

withDateUrgency :: Day -> Day -> Widget name -> Widget name
withDateUrgency observedOn dueOn widget = case dateUrgencyAt observedOn dueOn of
  DateUpcoming -> widget
  DateDueToday -> withAttr dateDueTodayAttr widget
  DateOverdue -> withAttr dateOverdueAttr widget
