{-# LANGUAGE OverloadedStrings #-}

-- | Read-only presentation of admitted Household policy and report settings.
-- This owner has no source loader or writer authority.
module HKernel.Editor.TUI.Settings
  ( drawWorkspace
  , handleWorkspaceEvent
  ) where

import Brick
import Brick.Widgets.Border
import qualified Graphics.Vty as V

import qualified Data.Set as Set
import qualified Data.Text as T

import HKernel.Account (accountName)
import HKernel.Editor.TUI.Model
  ( AppContext
  , AppEvent
  , Name(..)
  , contextHouseholdState
  )
import HKernel.Household.Application (HouseholdState(..))
import HKernel.Household.Policy
  ( householdCycleIncomeAccount
  , householdEnvelopeOrder
  , householdPolicyCycle
  )
import HKernel.Report.Config
  ( reportConfigurationPlan
  , reportConfigurationPresentation
  )

drawWorkspace :: AppContext -> Widget Name
drawWorkspace context =
  vBox
    [ borderWithLabel (str "Household Settings & Policy")
        (vLimit 18
          (viewport SettingsViewport Vertical
            (vBox
              [ str "=== [envelope.toml] Envelope Policy ==="
              , str ("Envelopes count: "
                  <> show (length (householdEnvelopeOrder
                    (householdStatePolicy state))))
              , str " "
              , str "=== [household.toml] Household Policy ==="
              , txt ("Income Cycle Account: "
                  <> accountName (householdCycleIncomeAccount
                    (householdPolicyCycle (householdStatePolicy state))))
              , str " "
              , str "=== [report.toml] Report Configuration ==="
              , txt ("Report Plan: "
                  <> T.pack (show (reportConfigurationPlan
                    (householdStateReportConfig state))))
              , txt ("Presentation: "
                  <> T.pack (show (reportConfigurationPresentation
                    (householdStateReportConfig state))))
              ])))
    , str "[wheel] Scroll   [h] Home   [1-7] Switch section   [q] Quit"
    ]
  where
    state = contextHouseholdState context

handleWorkspaceEvent
  :: BrickEvent Name AppEvent
  -> EventM Name s ()
handleWorkspaceEvent event = case event of
  MouseDown SettingsViewport V.BScrollUp _ _ ->
    vScrollBy (viewportScroll SettingsViewport) (-3)
  MouseDown SettingsViewport V.BScrollDown _ _ ->
    vScrollBy (viewportScroll SettingsViewport) 3
  _ -> pure ()
