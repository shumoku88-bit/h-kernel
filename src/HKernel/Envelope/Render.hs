{-# LANGUAGE OverloadedStrings #-}

-- | Pure Text rendering for the envelope extension.
module HKernel.Envelope.Render
  ( renderEnvelopeBudget
  , renderEnvelopePolicyErrors
  , renderEnvelopeBudgetErrors
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)
import HKernel.Account
import HKernel.Engine (rangeEnd, rangeStart)
import HKernel.Envelope
import HKernel.Money
import HKernel.Render.TerminalStyle

renderEnvelopeBudget :: EnvelopeBudgetReport -> Text
renderEnvelopeBudget report = T.intercalate "\n"
  [ terminalHeader "Envelope & Backing"
  , terminalMeta ("Horizon: " <> renderDay (rangeStart dateRange)
      <> ".." <> renderDay (rangeEnd dateRange))
  , terminalMeta ("Observed through: " <> renderDay (rangeEnd dateRange))
  , ""
  , renderTerminalTable envelopeColumns envelopeRows Nothing
  , renderAccountBalances
      "Unassigned expense accounts"
      (envelopeBudgetUnassignedExpenses report)
  , renderAccountBalances
      "Unclassified accounts"
      (envelopeBudgetUnclassifiedAccounts report)
  , ""
  ]
  where
    dateRange = envelopeBudgetRange report
    envelopeRows =
      [ [ plainCell (envelopeNameText (envelopeBudgetEnvelope line))
        , plainBalanceCell (envelopeBudgetEntitlement line)
        , plainBalanceCell (envelopeBudgetConsumption line)
        , signedBalanceCell (envelopeBudgetRemaining line)
        ]
      | line <- envelopeBudgetLines report
      ]

renderAccountBalances :: Text -> [EnvelopeAccountBalance] -> Text
renderAccountBalances _ [] = ""
renderAccountBalances title balances = T.intercalate "\n"
  [ terminalYellow title
  , renderTerminalTable accountColumns rows Nothing
  ]
  where
    rows =
      [ [ plainCell (accountName (envelopeAccount accountBalance))
        , signedBalanceCell (envelopeAccountBalance accountBalance)
        ]
      | accountBalance <- balances
      ]

envelopeColumns :: [(Text, Alignment)]
envelopeColumns =
  [ ("Envelope", AlignLeft)
  , ("Entitlement", AlignRight)
  , ("Consumption", AlignRight)
  , ("Remaining", AlignRight)
  ]

accountColumns :: [(Text, Alignment)]
accountColumns =
  [ ("Account", AlignLeft)
  , ("Balance", AlignRight)
  ]

renderEnvelopePolicyErrors :: NonEmpty EnvelopePolicyError -> Text
renderEnvelopePolicyErrors =
  T.unlines . map renderPolicyError . NonEmpty.toList
  where
    renderPolicyError err =
      "line " <> tshow (envelopePolicyErrorLine err) <> ": "
        <> renderPolicyReason (envelopePolicyErrorReason err)

renderPolicyReason :: EnvelopePolicyErrorReason -> Text
renderPolicyReason reason = case reason of
  InvalidEnvelopePolicyRow row ->
    "invalid envelope policy row: " <> quoted row
  InvalidEnvelopePolicyEnvelope err ->
    "invalid envelope name: " <> renderEnvelopeNameError err
  InvalidEnvelopePolicyAccount err ->
    "invalid account: " <> renderAccountError err
  InvalidEnvelopePolicyQuantity (InvalidQuantity value) ->
    "invalid quantity: " <> quoted value
  InvalidEnvelopePolicyCommodity err ->
    "invalid commodity: " <> renderCommodityError err
  NegativeEnvelopeAllocation envelope amount ->
    "negative allocation for " <> envelopeNameText envelope
      <> ": " <> renderAmount amount
  DuplicateEnvelopeAllocation envelope commodity ->
    "duplicate allocation for " <> envelopeNameText envelope
      <> " in " <> commodityCode commodity
  DuplicateEnvelopeAssignment account ->
    "account is assigned more than once: " <> accountName account
  AssignmentToUnallocatedEnvelope envelope ->
    "assignment refers to an unallocated envelope: "
      <> envelopeNameText envelope

renderEnvelopeBudgetErrors :: NonEmpty EnvelopeBudgetError -> Text
renderEnvelopeBudgetErrors =
  T.unlines . map renderBudgetError . NonEmpty.toList
  where
    renderBudgetError err =
      "line " <> tshow (envelopeBudgetErrorLine err) <> ": "
        <> renderBudgetReason (envelopeBudgetErrorReason err)

renderBudgetReason :: EnvelopeBudgetErrorReason -> Text
renderBudgetReason reason = case reason of
  EnvelopeAssignedAccountUndeclared account ->
    "envelope policy assigns an undeclared account: " <> accountName account
  EnvelopeAssignedAccountNotExpense account accountType ->
    "envelope policy assigns non-expense account " <> accountName account
      <> " with type " <> T.toLower (tshow accountType)

renderEnvelopeNameError :: EnvelopeNameError -> Text
renderEnvelopeNameError err = case err of
  EmptyEnvelopeName -> "name is empty"
  EnvelopeNameHasSurroundingWhitespace name ->
    "name has surrounding whitespace: " <> quoted name
  EnvelopeNameContainsControlCharacter name ->
    "name contains a control character: " <> quoted name

renderAccountError :: AccountError -> Text
renderAccountError err = case err of
  EmptyAccount -> "account name is empty"
  AccountHasSurroundingWhitespace name ->
    "account has surrounding whitespace: " <> quoted name
  AccountContainsControlCharacter name ->
    "account contains a control character: " <> quoted name

renderCommodityError :: CommodityError -> Text
renderCommodityError err = case err of
  EmptyCommodity -> "commodity code is empty"
  CommodityContainsWhitespace code ->
    "commodity contains whitespace: " <> quoted code

renderAmount :: Amount -> Text
renderAmount amount =
  renderQuantity (amountQuantity amount)
    <> " " <> commodityCode (amountCommodity amount)

renderDay :: Day -> Text
renderDay = T.pack . formatTime defaultTimeLocale "%Y-%m-%d"

quoted :: Text -> Text
quoted value = "‘" <> value <> "’"

tshow :: Show value => value -> Text
tshow = T.pack . show
