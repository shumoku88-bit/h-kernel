{-# LANGUAGE OverloadedStrings #-}

-- | Dedicated typed parser, admission, and canonical rendering for native
-- @entitlement.journal@ sources.
--
-- Entitlement history is sourced by two exact canonical fact kinds:
-- 1. explicit stock origin per Commodity: @YYYY-MM-DD origin COMMODITY [memo]@
-- 2. exact Entitlement transfer: @YYYY-MM-DD transfer <from> -> <to> QUANTITY COMMODITY [memo]@
--
-- Native transfer endpoints are 'Unallocated' or 'Spendable EnvelopeId'.
-- Arbitrary keyword prefixes and aliases are rejected.
-- This owner is decoupled from the accounting Journal parser and does not
-- depend on 'AccountRegistry'.
module HKernel.Envelope.Entitlement.Journal
  ( StockOrigin(..)
  , stockOrigin
  , EntitlementJournalEntry(..)
  , EntitlementJournal(..)
  , EntitlementJournalError(..)
  , parseEntitlementJournal
  , parseEntitlementJournalFromText
  , admitEntitlementJournal
  , renderStockOrigin
  , renderEntitlementTransfer
  , renderEntitlementJournal
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)

import HKernel.Envelope.EntitlementHistory
  ( EnvelopeEntitlementHistory
  , EnvelopeEntitlementHistoryError(..)
  , mkEnvelopeEntitlementHistory
  )
import HKernel.Envelope.EntitlementTransfer
  ( EnvelopeEndpoint(..)
  , EnvelopeEntitlementTransfer(..)
  , EnvelopeEntitlementTransferError(..)
  , mkEnvelopeEntitlementTransfer
  )
import HKernel.Envelope.Identity
  ( EnvelopeId
  , EnvelopeIdError
  , EnvelopeRegistry
  , envelopeIdText
  , envelopeRegistryContains
  , mkEnvelopeId
  )
import HKernel.Envelope.StockOrigin (StockOrigin(..), stockOrigin)
import HKernel.Money
  ( Commodity
  , CommodityError
  , amountCommodity
  , amountQuantity
  , commodityCode
  , mkAmount
  , mkCommodity
  , parseQuantity
  , renderQuantity
  )

-- | One parsed line entry in @entitlement.journal@.
data EntitlementJournalEntry
  = EntitlementOriginEntry StockOrigin
  | EntitlementTransferEntry EnvelopeEntitlementTransfer
  deriving (Eq, Show)

-- | Admitted native Entitlement source projection.
data EntitlementJournal = EntitlementJournal
  { entitlementJournalOrigins   :: Map Commodity StockOrigin
  , entitlementJournalTransfers :: [EnvelopeEntitlementTransfer]
  } deriving (Eq, Show)

-- | Strict admission failures for @entitlement.journal@.
data EntitlementJournalError
  = EntitlementJournalSyntaxError Int Text
  | EntitlementJournalInvalidDate Int Text
  | EntitlementJournalInvalidCommodity Int Text CommodityError
  | EntitlementJournalInvalidQuantity Int Text
  | EntitlementJournalInvalidEnvelopeId Int Text EnvelopeIdError
  | EntitlementJournalTransferError Int EnvelopeEntitlementTransferError
  | EntitlementJournalDuplicateOrigin Commodity Day Day
  | EntitlementJournalUnknownEnvelope Int EnvelopeId
  | EntitlementJournalHistoryError EnvelopeEntitlementHistoryError
  deriving (Eq, Show)

-- | Parse raw text into structured @entitlement.journal@ entries and validate
-- stock origin uniqueness.
parseEntitlementJournal
  :: Text
  -> Either (NonEmpty EntitlementJournalError) EntitlementJournal
parseEntitlementJournal input = do
  entries <- parseEntitlementJournalFromText input
  (origins, transfers) <- partitionAndValidateOrigins entries
  Right EntitlementJournal
    { entitlementJournalOrigins = origins
    , entitlementJournalTransfers = transfers
    }

-- | Parse line by line without stock origin uniqueness aggregation.
parseEntitlementJournalFromText
  :: Text
  -> Either (NonEmpty EntitlementJournalError) [(Int, EntitlementJournalEntry)]
parseEntitlementJournalFromText input =
  case partitionEithers (map parseLine numberedLines) of
    ([], parsed) -> Right (concat parsed)
    (errorGroups, _) -> Left (NonEmpty.fromList (concat errorGroups))
  where
    numberedLines = filter (not . isIgnored . snd) (zip [1 :: Int ..] (T.lines input))
    isIgnored line =
      let stripped = T.strip line
      in T.null stripped || "#" `T.isPrefixOf` stripped || ";" `T.isPrefixOf` stripped

parseLine
  :: (Int, Text)
  -> Either [EntitlementJournalError] [(Int, EntitlementJournalEntry)]
parseLine (lineNum, lineText) =
  case T.words (T.strip lineText) of
    [] -> Right []
    dateToken : restTokens ->
      case parseTimeM True defaultTimeLocale "%F" (T.unpack dateToken) :: Maybe Day of
        Nothing -> Left [EntitlementJournalInvalidDate lineNum dateToken]
        Just day -> parseStatement lineNum day restTokens

parseStatement
  :: Int
  -> Day
  -> [Text]
  -> Either [EntitlementJournalError] [(Int, EntitlementJournalEntry)]
parseStatement lineNum day tokens =
  case tokens of
    "origin" : commToken : memoTokens -> do
      commodity <- case mkCommodity commToken of
        Right c -> Right c
        Left err -> Left [EntitlementJournalInvalidCommodity lineNum commToken err]
      let note = cleanMemo (T.unwords memoTokens)
      Right [(lineNum, EntitlementOriginEntry (StockOrigin day commodity note))]

    "transfer" : fromToken : arrowToken : toToken : qtyToken : commToken : memoTokens
      | arrowToken == "->" -> parseTransfer fromToken toToken qtyToken commToken memoTokens

    _ -> Left
      [ EntitlementJournalSyntaxError lineNum
          ("syntax error; expected 'YYYY-MM-DD origin COMMODITY [memo]' or 'YYYY-MM-DD transfer <from> -> <to> QUANTITY COMMODITY [memo]', got: "
            <> T.unwords tokens)
      ]
  where
    parseTransfer fromToken toToken qtyToken commToken memoTokens = do
      fromEndpoint <- parseEndpoint lineNum fromToken
      toEndpoint <- parseEndpoint lineNum toToken
      qty <- case parseQuantity qtyToken of
        Right q -> Right q
        Left _ -> Left [EntitlementJournalInvalidQuantity lineNum qtyToken]
      comm <- case mkCommodity commToken of
        Right c -> Right c
        Left err -> Left [EntitlementJournalInvalidCommodity lineNum commToken err]
      let amount = mkAmount comm qty
          note = cleanMemo (T.unwords memoTokens)
      case mkEnvelopeEntitlementTransfer day fromEndpoint toEndpoint amount note of
        Right transfer -> Right [(lineNum, EntitlementTransferEntry transfer)]
        Left err -> Left [EntitlementJournalTransferError lineNum err]

parseEndpoint :: Int -> Text -> Either [EntitlementJournalError] EnvelopeEndpoint
parseEndpoint lineNum text
  | T.toCaseFold text == "unallocated" = Right Unallocated
  | otherwise = case mkEnvelopeId text of
      Right eid -> Right (Spendable eid)
      Left err -> Left [EntitlementJournalInvalidEnvelopeId lineNum text err]

cleanMemo :: Text -> Text
cleanMemo text =
  let stripped = T.strip text
  in if ";" `T.isPrefixOf` stripped
       then T.strip (T.drop 1 stripped)
       else stripped

partitionAndValidateOrigins
  :: [(Int, EntitlementJournalEntry)]
  -> Either (NonEmpty EntitlementJournalError) (Map Commodity StockOrigin, [EnvelopeEntitlementTransfer])
partitionAndValidateOrigins entries =
  case NonEmpty.nonEmpty duplicateErrors of
    Just errors -> Left errors
    Nothing -> Right (originsMap, transfers)
  where
    (duplicateErrors, originsMap, transfers) =
      foldl' collect ([], Map.empty, []) entries

    collect (errs, origins, trs) (_, EntitlementOriginEntry origin) =
      let comm = stockOriginCommodity origin
          day = stockOriginDate origin
      in case Map.lookup comm origins of
           Just firstOrigin ->
             ( EntitlementJournalDuplicateOrigin comm (stockOriginDate firstOrigin) day : errs
             , origins
             , trs
             )
           Nothing ->
             ( errs
             , Map.insert comm origin origins
             , trs
             )

    collect (errs, origins, trs) (_, EntitlementTransferEntry tr) =
      (errs, origins, trs ++ [tr])

-- | Admit a native Entitlement source against a stable 'EnvelopeRegistry'.
--
-- This guarantees:
-- - All referenced Envelope identities exist in the stable registry
-- - Exactly one explicit stock origin exists per Commodity used
-- - Every transfer occurs on or after its Commodity's stock origin
-- - Cumulative entitlement never drops below zero (after combining same-day effects)
admitEntitlementJournal
  :: EnvelopeRegistry
  -> Text
  -> Either (NonEmpty EntitlementJournalError) EnvelopeEntitlementHistory
admitEntitlementJournal registry input = do
  rawEntries <- parseEntitlementJournalFromText input
  (origins, _) <- partitionAndValidateOrigins rawEntries
  let unknownEnvelopeErrors =
        [ EntitlementJournalUnknownEnvelope lineNum envId
        | (lineNum, EntitlementTransferEntry transfer) <- rawEntries
        , envId <- transferEnvelopes transfer
        , not (envelopeRegistryContains envId registry)
        ]
  case NonEmpty.nonEmpty unknownEnvelopeErrors of
    Just errors -> Left errors
    Nothing -> do
      let transfers = [tr | (_, EntitlementTransferEntry tr) <- rawEntries]
      case mkEnvelopeEntitlementHistory origins transfers of
        Right history -> Right history
        Left historyErrors ->
          Left (fmap EntitlementJournalHistoryError historyErrors)
  where
    transferEnvelopes transfer =
      [ envId
      | Spendable envId <-
          [ entitlementTransferFrom transfer
          , entitlementTransferTo transfer
          ]
      ]

-- | Render one stock origin directive.
renderStockOrigin :: StockOrigin -> Text
renderStockOrigin origin
  | T.null (stockOriginNote origin) =
      renderDay (stockOriginDate origin)
        <> " origin " <> commodityCode (stockOriginCommodity origin)
  | otherwise =
      renderDay (stockOriginDate origin)
        <> " origin " <> commodityCode (stockOriginCommodity origin)
        <> " " <> stockOriginNote origin

-- | Render one native transfer directive.
renderEntitlementTransfer :: EnvelopeEntitlementTransfer -> Text
renderEntitlementTransfer transfer =
  renderDay (entitlementTransferDate transfer)
    <> " transfer "
    <> renderEndpoint (entitlementTransferFrom transfer)
    <> " -> " <> renderEndpoint (entitlementTransferTo transfer)
    <> " " <> renderQuantity (amountQuantity amount)
    <> " " <> commodityCode (amountCommodity amount)
    <> (if T.null (entitlementTransferNote transfer)
          then ""
          else " " <> entitlementTransferNote transfer)
  where
    amount = entitlementTransferAmount transfer
    renderEndpoint Unallocated = "unallocated"
    renderEndpoint (Spendable eid) = envelopeIdText eid

-- | Render a complete @entitlement.journal@ document.
renderEntitlementJournal :: EntitlementJournal -> Text
renderEntitlementJournal (EntitlementJournal origins transfers) =
  T.unlines (map renderStockOrigin (Map.elems origins) ++ map renderEntitlementTransfer transfers)

renderDay :: Day -> Text
renderDay = T.pack . formatTime defaultTimeLocale "%F"
