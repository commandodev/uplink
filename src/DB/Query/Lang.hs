{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE StandaloneDeriving #-}

module DB.Query.Lang (
  Select(..),
  Select'(..),
  SelectResult(..),
  SelectConstraints,

  lenSelectResults,

  runSelect,
  runSelectDB,

  runSelect',
  runSelectDB',

  Cond(..),
  Conj(..),
  WhereClause(..),

  HasTableName(..),

  Table(..),
  AccountsTable(..),
  AssetsTable(..),
  HoldingsTable(..),
  ContractsTable(..),
  GlobalStorageTable(..),
  LocalStorageTable(..),
  BlocksTable(..),
  TransactionsTable(..),

  HasColName(..),
  ColType,
  RowType,

  AccountCol(..),
  AssetCol(..),
  HoldingsCol(..),
  ContractCol(..),
  GlobalStorageCol(..),
  LocalStorageCol(..),
  BlockCol(..),
  TransactionCol(..),

) where

import Protolude

import Control.Monad.Base

import Data.Aeson (ToJSON)
import qualified Data.ByteString as BS
import qualified Data.List
import qualified Data.Serialize as S
import Data.Set hiding (map)
import Data.String (fromString)

import DB.PostgreSQL.Error
import DB.PostgreSQL.Account
import DB.PostgreSQL.Asset
import DB.PostgreSQL.Block
import DB.PostgreSQL.Contract
import DB.PostgreSQL.Transaction

import Account
import Address
import Asset
import Block
import Contract
import Storage
import Transaction
import qualified Key

import Consensus.Authority.Params (PoA)

import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.FromRow
import Database.PostgreSQL.Simple.ToField

import DB.Class
import DB.PostgreSQL

import Script.Pretty (Pretty(..), dquotes, squotes, (<+>))
import qualified Script.Pretty as Pretty
import qualified Script.Graph as Graph

{-

TypeSafe Subset-of-SQL DSL:

  The GADTs and type families below disallow the programmer, in Haskell land,
  to construct an ill-typed SQL expression. For instance, if the table to be
  queried is `AccountsTable`, the column values in the 'Where' clauses _must_
  be of type `AccountCol`, and the result type of `runSelect'` _will_ be `Account`.

  This results from the `ColType` and `RowType` type families, and could be
  used internally in Uplink to construct well formed SQL queries for a metrics
  process or database anayltics process.

  The main contributions of this code are to
    1) _disallow_ invalid SQL queries; i.e. the queries generated by `runSelect'`
        are guaranteed not to fail with a syntax or value error from SQL.
    2) provide a target ADT to parse query strings into, providing sql sanitization
       of text sent to Uplink by users through the RPC interface. This module provides
       a high level interface to the complex DB schema of uplink.

-}

--------------------------------------------------------------------------------
-- Tables
--------------------------------------------------------------------------------

data AccountsTable      = AccountsTable deriving (Show, Eq)
data AssetsTable        = AssetsTable deriving (Show, Eq)
data HoldingsTable      = HoldingsTable deriving (Show, Eq)
data ContractsTable     = ContractsTable deriving (Show, Eq)
data GlobalStorageTable = GlobalStorageTable deriving (Show, Eq)
data LocalStorageTable  = LocalStorageTable deriving (Show, Eq)
data BlocksTable        = BlocksTable deriving (Show, Eq)
data TransactionsTable  = TransactionsTable deriving (Show, Eq)

type family RowType r where
  RowType AccountsTable      = Account
  RowType AssetsTable        = AssetRow
  RowType HoldingsTable      = HoldingsRow
  RowType ContractsTable     = ContractRow
  RowType GlobalStorageTable = GlobalStorageRow
  RowType LocalStorageTable  = LocalStorageRow
  RowType BlocksTable        = BlockRow
  RowType TransactionsTable  = TransactionRow

class HasTableName a where
  tableName :: a -> ByteString

instance HasTableName AccountsTable where
  tableName AccountsTable      = "accounts"
instance HasTableName AssetsTable where
  tableName AssetsTable        = "assets"
instance HasTableName HoldingsTable where
  tableName HoldingsTable      = "holdings"
instance HasTableName ContractsTable where
  tableName ContractsTable     = "contracts"
instance HasTableName GlobalStorageTable where
  tableName GlobalStorageTable = "global_storage"
instance HasTableName LocalStorageTable where
  tableName LocalStorageTable  = "local_storage"
instance HasTableName BlocksTable where
  tableName BlocksTable        = "blocks"
instance HasTableName TransactionsTable where
  tableName TransactionsTable  = "transactions"

--------------------------------------------------------------------------------
-- Columns
--------------------------------------------------------------------------------

-- | Type family relating Row types to Column types
type family ColType c where
  ColType AccountsTable      = AccountCol
  ColType AssetsTable        = AssetCol
  ColType HoldingsTable      = HoldingsCol
  ColType ContractsTable     = ContractCol
  ColType GlobalStorageTable = GlobalStorageCol
  ColType LocalStorageTable  = LocalStorageCol
  ColType BlocksTable        = BlockCol
  ColType TransactionsTable  = TransactionCol

class HasColName col where
  colName :: col -> ByteString

--------------------------------------------------------------------------------

-- | Accounts Columns
data AccountCol
  = AccountPubKey   Key.PubKey
  | AccountAddress  Address
  | AccountTimezone Text
  deriving (Eq, Show)

instance HasColName AccountCol where
  colName accountCol =
    case accountCol of
      AccountPubKey   _ -> "publicKey"
      AccountAddress  _ -> "address"
      AccountTimezone _ -> "timezone"

instance ToField AccountCol where
  toField accountsCol =
    case accountsCol of
      AccountPubKey   c -> toField c
      AccountAddress  c -> toField c
      AccountTimezone c -> toField c

--------------------------------------------------------------------------------

-- | Asset Columns
data AssetCol
  = AssetName      Text
  | AssetIssuer    Address
  | AssetIssuedOn  Int64
  | AssetSupply    Int64
  | AssetReference Asset.Ref
  | AssetType      Asset.AssetType
  | AssetAddress   Address
  -- Ad Hoc "Column" to query assets by holder
  | HoldingsCol    HoldingsCol
  deriving (Eq, Ord, Show)

instance HasColName AssetCol where
  colName assetCol =
    case assetCol of
      AssetName      _ -> "name"
      AssetIssuer    _ -> "issuer"
      AssetIssuedOn  _ -> "issuedOn"
      AssetSupply    _ -> "supply"
      AssetReference _ -> "reference"
      AssetType      _ -> "assetType"
      AssetAddress   _ -> "address"
      -- Used for referring to holdings columns in a query about assets that is
      -- translated into two separate queries in a preliminary pass over the AST
      HoldingsCol    hc -> colName hc

instance ToField AssetCol where
  toField assetCol =
    case assetCol of
      AssetName      c -> toField c
      AssetIssuer    c -> toField c
      AssetIssuedOn  c -> toField c
      AssetSupply    c -> toField c
      AssetReference c -> toField c
      AssetType      c -> toField c
      AssetAddress   c -> toField c
      HoldingsCol    _ -> panic "AssetHolder is not a column of 'assets'"

--------------------------------------------------------------------------------

-- | Holdings Columns
data HoldingsCol
  = HoldingsAsset   Address
  | HoldingsHolder  Address
  | HoldingsBalance Int64
  deriving (Eq, Ord, Show)

instance HasColName HoldingsCol where
  colName holdingsCol =
    case holdingsCol of
      HoldingsAsset   _ -> "asset"
      HoldingsHolder  _ -> "holder"
      HoldingsBalance _ -> "balance"

instance ToField HoldingsCol where
  toField holdingsCol =
    case holdingsCol of
      HoldingsAsset   c -> toField c
      HoldingsHolder  c -> toField c
      HoldingsBalance c -> toField c

--------------------------------------------------------------------------------

-- | Contracts Columns
data ContractCol
  = ContractTimestamp Int64
  | ContractState     Graph.GraphState
  | ContractOwner     Address
  | ContractAddress   Address
  deriving (Eq, Ord, Show)

instance HasColName ContractCol where
  colName contractCol =
    case contractCol of
      ContractTimestamp _ -> "timestamp"
      ContractState     _ -> "state"
      ContractOwner     _ -> "owner"
      ContractAddress   _ -> "address"

instance ToField ContractCol where
  toField contractCol =
    case contractCol of
      ContractTimestamp c -> toField c
      ContractState     c -> toField c
      ContractOwner     c -> toField c
      ContractAddress   c -> toField c

data GlobalStorageCol
  = GSContract Address
  | GSKey      Key
  deriving (Eq, Ord, Show)

instance HasColName GlobalStorageCol where
  colName gsCol =
    case gsCol of
      GSContract _ -> "contract"
      GSKey      _ -> "key"

instance ToField GlobalStorageCol where
  toField gsCol =
    case gsCol of
      GSContract c -> toField c
      GSKey      c -> toField c

-- | LocalStorage Columns
data LocalStorageCol
  = LSContract Address
  | LSAccount  Address
  | LSKey      Key
  deriving (Eq, Ord, Show)

instance HasColName LocalStorageCol where
  colName lsCol =
    case lsCol of
      LSContract _ -> "contract"
      LSAccount  _ -> "account"
      LSKey      _ -> "key"

instance ToField LocalStorageCol where
  toField lsCol =
    case lsCol of
      LSContract c -> toField c
      LSAccount  c -> toField c
      LSKey      c -> toField c

--------------------------------------------------------------------------------

-- | Block Columns
data BlockCol
  = BlockIdx        Int
  | BlockOrigin     Address
  | BlockTimestamp  Int64
  deriving (Eq, Ord, Show)

instance HasColName BlockCol where
  colName blockCol =
    case blockCol of
      BlockIdx        _ -> "idx"
      BlockOrigin     _ -> "origin"
      BlockTimestamp  _ -> "timestamp"

instance ToField BlockCol where
  toField blockCol =
    case blockCol of
      BlockIdx        c -> toField c
      BlockOrigin     c -> toField c
      BlockTimestamp  c -> toField c

-- | Transaction Columns
data TransactionCol
  = TxType      Text
  | TxOrigin    Address
  | TxTimestamp Int64
  | TxHash      Text
  deriving (Eq, Ord, Show)

instance HasColName TransactionCol where
  colName txCol =
    case txCol of
      TxType      _ -> "tx_type"
      TxOrigin    _ -> "origin"
      TxTimestamp _ -> "timestamp"
      TxHash      _ -> "hash"

instance ToField TransactionCol where
  toField txCol =
    case txCol of
      TxType      c -> toField c
      TxOrigin    c -> toField c
      TxTimestamp c -> toField c
      TxHash      c -> toField c

--------------------------------------------------------------------------------
-- DSL
--------------------------------------------------------------------------------

-- | Conditional Expressions
data Cond a where
  ColEquals :: (HasColName a, ToField a) => a -> Cond a
  ColGT     :: (HasColName a, ToField a) => a -> Cond a
  ColGTE    :: (HasColName a, ToField a) => a -> Cond a
  ColLT     :: (HasColName a, ToField a) => a -> Cond a
  ColLTE    :: (HasColName a, ToField a) => a -> Cond a

deriving instance (Show a) => Show (Cond a)
deriving instance (Eq a) => Eq (Cond a)

instance ToField c => ToField (Cond c) where
  toField (ColEquals e) = toField e
  toField (ColGT e)     = toField e
  toField (ColGTE e)    = toField e
  toField (ColLT e)     = toField e
  toField (ColLTE e)    = toField e

--------------------------------------------------------------------------------

-- | Conjunction of Conditionals
data Conj = And | Or
  deriving (Show, Eq)

-- | SQL Where clauses made up of 1 or more conditonal statements
-- GADT to enforce (ToField a)
data WhereClause a where
  Where    -- ^ Single Where condition
    :: ToField a
    => Cond a
    -> WhereClause a
  WhereConj
    :: ToField a
    => Cond a
    -> Conj
    -> WhereClause a
    -> WhereClause a

deriving instance (Show a) => Show (WhereClause a)
deriving instance (Eq a) => Eq (WhereClause a)

--------------------------------------------------------------------------------

-- | The Column values in the where clause depend on the
-- Column type of the Row type of `a`. I.e. The AssetsTable type has a RowType
-- of AssetRow, and the AssetRow type has columns of type AssetCol. Therefore,
-- in a where clause of a query on the AssetsTable table, only AssetCol values
-- can be used in the predicates.

type SelectConstraints a =
  ( HasTableName a
  , Show (ColType a)
  , Eq (ColType a)
  , HasColName (ColType a)
  , Pretty (ColType a)
  )

-- | A `Select` statement that queries a table from the uplink database, with 0
-- or more "where clauses" constraining the values the query should return
data Select' a where
  Select'
    :: SelectConstraints a
    => a                      -- ^ Type corresponding to which table to query
    -> Maybe (WhereClause (ColType a)) -- ^ Where clause to restrict the rows returned
    -> Select' a

deriving instance Show a => Show (Select' a)
deriving instance Eq a => Eq (Select' a)

runSelect'
  :: (FromRow (RowType a))
  => Connection
  -> Select' a
  -> IO (Either PostgreSQLError [RowType a])
runSelect' conn select' = do
  let (q, actions) = selectToRawSQL select'
  -- Log SQL query for debugging
  -- print =<< formatQuery conn q actions
  querySafe conn q actions

runSelectDB'
  :: (MonadBase IO m, FromRow (RowType a))
  => Select' a
  -> PostgresT m (Either PostgreSQLError [RowType a])
runSelectDB' select' =
  withConn $ \conn ->
    runSelect' conn select'

--------------------------------------------------------------------------------
-- SQL Generation
--------------------------------------------------------------------------------

condSQL :: (ToField a) => Cond a -> (ByteString,Action)
condSQL cond =
  (,toField cond) $
    case cond of
      ColEquals c -> colName c <> "=?"
      ColGT     c -> colName c <> ">?"
      ColGTE    c -> colName c <> ">=?"
      ColLT     c -> colName c <> "<?"
      ColLTE    c -> colName c <> "<=?"


whereSQL :: WhereClause a -> (ByteString, [Action])
whereSQL wc =
    first ("WHERE " <>) $
      whereCondsSQL wc
  where
    whereCondsSQL
      :: WhereClause a
      -> (ByteString, [Action])
    whereCondsSQL wc' =
      case wc' of
        Where cond ->
          let (bs,action) = condSQL cond
           in (bs, [action])
        WhereConj cond conj whereClause ->
          let (bs,action) = condSQL cond
              (bs',actions) = whereCondsSQL whereClause
           in (mconcat [bs, conjSQL conj, bs'], action : actions)

    conjSQL conj =
      case conj of
        And -> " AND "
        Or  -> " OR "

selectToRawSQL :: Select' a -> (Query,[Action])
selectToRawSQL (Select' table mWhere) =
    (fromString (toS selectSQL), actions)
  where
    selectKeyWord = "SELECT"
    starKeyWord   = "*"
    fromKeyWord   = "FROM"

    (whereSQL', actions) =
      case mWhere of
        Nothing     -> ("",[])
        Just _where -> whereSQL _where

    selectSQL =
      BS.intercalate " " $
        [ selectKeyWord
        , starKeyWord
        , fromKeyWord
        , tableName table
        , whereSQL'
        ]

--------------------------------------------------------------------------------
-- Polymorphic Types -> Monomorphic Types
--------------------------------------------------------------------------------
--
--  Unfortunately, the lovely type safety of the code above creates a bit of an
--  annoyance when writing a parser; The function `parse :: Text -> Select' a`
--  is impossible to write...
--
--  So, this part of the code is used for wrapping the polymorphic, type safe query
--  language such that it can be parsed. This is necessary because the parser must
--  have a monomorphic result, i.e. it must not return a polymorphic value, or
--  can't, rather, because the return type must be known at compile time, and if
--  an arbitrary string is parsed at run time, the compiler can't know the result
--  type of the parse statically.
--
--------------------------------------------------------------------------------

data Table
  = TableAccounts       AccountsTable
  | TableAssets         AssetsTable
  | TableHoldings       HoldingsTable
  | TableContracts      ContractsTable
  | TableGlobalStorage  GlobalStorageTable
  | TableLocalStorage   LocalStorageTable
  | TableBlocks         BlocksTable
  | TableTransactions   TransactionsTable
  deriving (Show, Eq)

data Select
  = SelectAccounts      (Select' AccountsTable)
  | SelectAssets        (Select' AssetsTable)
  | SelectContracts     (Select' ContractsTable)
  | SelectBlocks        (Select' BlocksTable)
  | SelectTransactions  (Select' TransactionsTable)
  deriving (Show, Eq)

data SelectResult
  = ResultAccounts      [Account]
  | ResultAssets        [Asset]
  | ResultContracts     [Contract]
  | ResultBlocks        [Block]
  | ResultTransactions  [Transaction]
  deriving (Show, Generic, ToJSON)

lenSelectResults :: SelectResult -> Int
lenSelectResults = \case
  ResultAccounts r     -> length r
  ResultAssets r       -> length r
  ResultContracts r    -> length r
  ResultBlocks r       -> length r
  ResultTransactions r -> length r

-- | First, we preprocess `Select' a` values, as some ledger types are
-- dissected and  stored in several tables. We need to build the _actual_
-- queries to the DB, escaping the abstract way in which users will submit
-- query strings. After "splitting" the Select' values, we generate the SQL
-- and send it off to the DB; In the case of no split, we simply return the
-- results from the DB. If the value _is_ split, we run each query separately,
-- and then either perform a union or intersection on the results, in relation
-- to the way the original query string was written.
runSelect
  :: Connection
  -> Select
  -> IO (Either PostgreSQLError SelectResult)
runSelect conn select =
  case splitSelect select of
    AccountSplit accSelect       ->
      fmap ResultAccounts <$>
        runSelect_ accSelect
    AssetSplit assetSplit        ->
      fmap ResultAssets <$>
        runSplit assetSplit
    ContractSplit contractSelect ->
      fmap ResultContracts <$>
        runSelect_ contractSelect
    BlockSplit blockSplit        ->
      fmap ResultBlocks <$>
        runSelect_ blockSplit
    TransactionSplit splitTxs    ->
      fmap ResultTransactions <$>
        runSelect_ splitTxs
  where
    runSelect_
      :: (FromRow (RowType a), HasLedgerType (RowType a))
      => Select' a
      -> IO (Either PostgreSQLError [LedgerType (RowType a)])
    runSelect_ sel =
      runSelect' conn sel >>=
        either (pure . Left) (queryManyLedgerType conn)

    runSplit
      :: (SplitConstraints (RowType a) (RowType b))
      => Split a b
      -> IO (Either PostgreSQLError [LedgerType (RowType a)])
    runSplit split = do
      case split of
        SplitLeft  lsplit    -> runSelect_ lsplit
        SplitRight rsplit    -> runSelect_ rsplit
        Split conj lsel rsel -> do
          elRes <- runSelect_ lsel
          case elRes of
            Left err -> pure $ Left err
            Right lRes -> do
              eRRes <- runSelect_ rsel
              case eRRes of
                Left err -> pure $ Left err
                Right rRes -> do
                  pure $ Right $
                    case conj of
                      And -> Data.List.union lRes rRes
                      Or  -> Data.List.intersect lRes rRes

    -- | Currently only Assets need to be "split"

-- | Performs the query operation on a database in a PostgresT stack
runSelectDB
  :: MonadBase IO m
  => Select
  -> PostgresT m (Either PostgreSQLError SelectResult)
runSelectDB select =
  withConn $ flip runSelect select

--------------------------------------------------------------------------------
-- Preprocessor
--------------------------------------------------------------------------------

type SplitConstraints a b =
  (Eq (LedgerType a), FromRow a, FromRow b, HasLedgerType a, HasLedgerType b, LedgerType a ~ LedgerType b)

-- Should the sub query be ANDed or ORed together?
data Split a b
  = SplitLeft  (Select' a)
  | SplitRight (Select' b)
  | Split Conj (Select' a) (Select' b)
  deriving (Show)

-- XXX Split contracts into ContractRows/GlobalStorageRows/LocalStorageRows
-- XXX Split blocks into BlockRows/TransactionRows
data SplitSelect
  = AssetSplit (Split AssetsTable HoldingsTable)
  | ContractSplit (Select' ContractsTable)
  | AccountSplit (Select' AccountsTable)
  | TransactionSplit (Select' TransactionsTable)
  | BlockSplit (Select' BlocksTable)

-- | Splits a Query Lang Expr into queries that are representative of the
-- database schema. Select Exprs generally provide a nice API for querying
-- things about the database, but do not lend themselves to easy translation
-- into queries that are representative of the actual DB schema.
-- Note: I tried hard but couldn't find a better solution
splitSelect :: Select -> SplitSelect
splitSelect select =
  case select of
    -- XXX Split on Local/GlobalStorage in contracts queries
    SelectContracts selectContracts -> ContractSplit selectContracts
    SelectAccounts  selectAccounts  -> AccountSplit selectAccounts
    -- XXX Split on Transaction fields in blocks queries
    SelectBlocks    selectBlocks    -> BlockSplit selectBlocks
    SelectTransactions selectTxs    -> TransactionSplit selectTxs
    SelectAssets selectAssets       -> splitAssets selectAssets
  where
    splitAssets
      :: Select' AssetsTable
      -> SplitSelect
    splitAssets selectAssets =
      AssetSplit $
        case selectAssets of
          Select' _ Nothing            -> SplitLeft selectAssets
          Select' _ (Just whereClause) -> splitAssets' whereClause
      where
        splitAssets'
          :: WhereClause AssetCol
          -> Split AssetsTable HoldingsTable
        splitAssets' wc =
          case wc of
            -- In the case of a single where condition
            Where cond ->
              let (constr, col) = explodeCond cond
               in case col of
                    -- In the case that only the hodlings
                    -- column is in the where clause
                    HoldingsCol hcol ->
                      SplitRight $
                        Select' HoldingsTable $
                          Just $ Where (constr hcol)
                    -- In the case that only one condition is in
                    -- the where clause, and it's an asset col
                    otherwise ->
                      SplitLeft $
                        Select' AssetsTable $
                          Just $ Where cond
            -- In the case of multiple conditions in the where clause
            -- recursively split the query, and add the current where
            -- condition to the split query afterwards
            WhereConj cond conj wc' ->
              let split = splitAssets' wc'
               in addWhereCondToSplit cond conj split

        addWhereCondToSplit
          :: Cond AssetCol
          -> Conj
          -> Split AssetsTable HoldingsTable
          -> Split AssetsTable HoldingsTable
        addWhereCondToSplit cond conj split =
          let (constr, col) = explodeCond cond
           in case col of
                HoldingsCol hCol ->
                  let hCond = constr hCol
                   in case split of
                        SplitLeft aselect     ->
                          Split conj aselect $
                            Select' HoldingsTable $
                              Just $ Where hCond
                        SplitRight hselect    ->
                          SplitRight $
                            addWhereCond hCond conj hselect
                        Split conj' aselect hselect ->
                          Split conj' aselect $
                            addWhereCond hCond conj hselect
                otherwise ->
                  case split of
                    SplitLeft aselect ->
                      SplitLeft $
                        addWhereCond cond conj aselect
                    SplitRight hselect ->
                      flip (Split conj) hselect $
                        Select' AssetsTable $
                          Just $ Where cond
                    Split conj' aselect hselect ->
                      flip (Split conj') hselect $
                        addWhereCond cond conj aselect

        addWhereCond
          :: ToField (ColType a)
          => Cond (ColType a)
          -> Conj
          -> Select' a
          -> Select' a
        addWhereCond cond conj (Select' t mWhere) =
          let wc = case mWhere of
                Nothing -> Where cond
                Just wc -> WhereConj cond conj wc
           in Select' t (Just wc)

    explodeCond
      :: (HasColName b, ToField b)
      => Cond a
      -> (b -> Cond b, a)
    explodeCond cond =
      case cond  of
        ColEquals c -> (ColEquals, c)
        ColGT     c -> (ColGT, c)
        ColGTE    c -> (ColGTE, c)
        ColLT     c -> (ColLT, c)
        ColLTE    c -> (ColLTE, c)

--------------------------------------------------------------------------------
-- SelectResult to Account, Asset, or Contract
--
-- Note: This is necessary because the frontend wants to talk about these
-- values, not the *Row type values that the relational schema annoyingly
-- devolves the beautiful Haskell SoP nested record types.
--------------------------------------------------------------------------------

class HasLedgerType a where
  type LedgerType a
  queryManyLedgerType
    :: Connection
    -> [a]
    -> IO (Either PostgreSQLError [LedgerType a])

instance HasLedgerType Account where
  type LedgerType Account = Account
  queryManyLedgerType _ accounts = pure $ Right accounts

instance HasLedgerType AssetRow where
  type LedgerType AssetRow = Asset
  queryManyLedgerType = assetRowsToAssets

instance HasLedgerType HoldingsRow where
  type LedgerType HoldingsRow = Asset
  queryManyLedgerType conn holdingsRows =
    queryAssetsByAddrs conn $
      map holdingsAsset holdingsRows

instance HasLedgerType ContractRow where
  type LedgerType ContractRow = Contract
  queryManyLedgerType = contractRowsToContracts

instance HasLedgerType GlobalStorageRow where
  type LedgerType GlobalStorageRow = Contract
  queryManyLedgerType conn gsRows =
    queryContractsByAddrs conn $
      map gsContract gsRows

instance HasLedgerType LocalStorageRow where
  type LedgerType LocalStorageRow = Contract
  queryManyLedgerType conn lsRows =
    queryContractsByAddrs conn $
      map lsContract lsRows

instance HasLedgerType BlockRow where
  type LedgerType BlockRow = Block
  queryManyLedgerType = blockRowsToBlocks

instance HasLedgerType TransactionRow where
  type LedgerType TransactionRow = Transaction
  queryManyLedgerType _ = pure . Right . map rowTypeToTransaction

--------------------------------------------------------------------------------
-- Pretty Print
--------------------------------------------------------------------------------

instance Pretty AccountsTable where
  ppr = ppr . tableName
instance Pretty AssetsTable where
  ppr = ppr . tableName
instance Pretty HoldingsTable where
  ppr = ppr . tableName
instance Pretty ContractsTable where
  ppr = ppr . tableName
instance Pretty GlobalStorageTable where
  ppr = ppr . tableName
instance Pretty LocalStorageTable where
  ppr = ppr . tableName
instance Pretty BlocksTable where
  ppr = ppr . tableName
instance Pretty TransactionsTable where
  ppr = ppr . tableName

instance Pretty AccountCol where
  ppr = \case
    AccountAddress addr -> ppr addr
    AccountTimezone tz  -> dquotes $ ppr tz
    AccountPubKey pkbs  -> dquotes $ ppr (show pkbs :: Text)
instance Pretty AssetCol where
  ppr = \case
    AssetName assetNm   -> dquotes $ ppr assetNm
    AssetIssuer addr    -> ppr addr
    AssetIssuedOn time  -> ppr time
    AssetSupply supply  -> ppr supply
    AssetReference ref  -> dquotes $ ppr $ (show ref :: Text)
    AssetType assetType -> dquotes $ ppr $ (show assetType :: Text)
    AssetAddress addr   -> ppr addr
    HoldingsCol hcol    -> ppr hcol
instance Pretty HoldingsCol where
  ppr = \case
    HoldingsAsset addr  -> ppr addr
    HoldingsHolder addr -> ppr addr
    HoldingsBalance bal -> ppr bal
instance Pretty ContractCol where
  ppr = \case
    ContractTimestamp ts -> ppr ts
    ContractState state  -> dquotes $ ppr state
    ContractOwner addr   -> ppr addr
    ContractAddress addr -> ppr addr
instance Pretty GlobalStorageCol where
  ppr = \case
    GSContract addr      -> ppr addr
    GSKey (Key keyBS)    -> dquotes $ ppr keyBS
instance Pretty LocalStorageCol where
  ppr = \case
    LSContract addr      -> ppr addr
    LSAccount addr       -> ppr addr
    LSKey (Key keyBS)    -> dquotes $ ppr keyBS
instance Pretty BlockCol where
  ppr = \case
    BlockIdx n           -> ppr n
    BlockOrigin addr     -> ppr addr
    BlockTimestamp ts    -> ppr ts
instance Pretty TransactionCol where
  ppr = \case
    TxOrigin addr        -> ppr addr
    TxType txtyp         -> dquotes $ ppr txtyp
    TxTimestamp ts       -> ppr ts
    TxHash      hash     -> ppr hash

instance Pretty a => Pretty (Cond a) where
  ppr (ColEquals col) = ppr (colName col) <+> "="  <+> ppr col
  ppr (ColGT col)     = ppr (colName col) <+> ">"  <+> ppr col
  ppr (ColGTE col)    = ppr (colName col) <+> ">=" <+> ppr col
  ppr (ColLT col)     = ppr (colName col) <+> "<"  <+> ppr col
  ppr (ColLTE col)    = ppr (colName col) <+> "<=" <+> ppr col

instance Pretty Conj where
  ppr And = "AND"
  ppr Or  = "OR"

instance Pretty a => Pretty (WhereClause a) where
  ppr (Where cond)             = ppr cond
  ppr (WhereConj cond conj wc) =
    ppr cond <+> ppr conj <+> ppr wc

instance Pretty (Select' a) where
  ppr (Select' tbl Nothing)   =
    "QUERY" <+> Pretty.text (toS $ tableName tbl) <> ";"
  ppr (Select' tbl (Just wc)) =
    "QUERY" <+> Pretty.text (toS $ tableName tbl) <+> "WHERE" <+> ppr wc <> ";"

instance Pretty Select where
  ppr (SelectAccounts s)     = ppr s
  ppr (SelectAssets s)       = ppr s
  ppr (SelectContracts s)    = ppr s
  ppr (SelectBlocks s)       = ppr s
  ppr (SelectTransactions s) = ppr s
