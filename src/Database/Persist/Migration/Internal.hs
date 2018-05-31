{-|
Module      :  Database.Persist.Migration.Internal
Maintainer  :  Brandon Chinn <brandonchinn178@gmail.com>
Stability   :  experimental
Portability :  portable

Defines a migration framework for the persistent library.
-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

module Database.Persist.Migration.Internal where

import Control.Monad.Reader (ReaderT)
import Data.Text (Text)
import Database.Persist.Class (BackendCompatible)
import Database.Persist.Sql (SqlBackend)
import Database.Persist.Types (SqlType(..))

{- Operation types -}

-- | The ID of an operation. Should be unique and not change, ever.
type OperationId = Int

-- | An operation that can be migrated.
data Operation =
  forall m. Migrateable m =>
  Operation
    { opId :: OperationId
    , opOp :: m
    }

-- | Set an operation to be a noop for any operations in the given migration with the given OperationIds.
setNoop :: [OperationId] -> MigrationInfo -> MigrationInfo
setNoop ids = map $ \(shouldRun, op) ->
  if opId op `elem` ids
    then (False, op)
    else (shouldRun, op)

{- Migration types -}

-- | A list of operations.
type Migration = [Operation]

-- | A list of operations containing a Bool that should be False to make the operation a noop.
type MigrationInfo = [(Bool, Operation)]

-- | The type for the underlying operation.
--
-- RawOperations should primarily use 'rawSql' and 'rawExecute' from the persistent library. If the
-- operation depends on the backend being run, query 'connRDBMS' from the 'SqlBackend':
--
-- @
-- asks connRDBMS >>= \case
--   "sqlite" -> ...
--   _ -> return ()
-- @
type MigrateT m a = forall backend. BackendCompatible SqlBackend backend => ReaderT backend m a

-- | The backend to migrate with.
data MigrateBackend = MigrateBackend
  { createTable :: CreateTable -> MigrateT IO ()
  , dropTable :: DropTable -> MigrateT IO ()
  , addColumn :: AddColumn -> MigrateT IO ()
  , dropColumn :: DropColumn -> MigrateT IO ()
  }

class Migrateable m where
  -- | How to run the given operation.
  runOperation :: MigrateBackend -> m -> MigrateT IO ()

  -- | Modify the list of pending operations prior to migrating.
  modifyMigration :: OperationId -> m -> MigrationInfo -> MigrationInfo
  modifyMigration _ _ = id

{- Core Operations -}

-- | An operation to create a table according to the specified schema.
data CreateTable = CreateTable
  { ctName :: Text
  , ctSchema :: [Column]
  , ctConstraints :: [TableConstraint]
  }

instance Migrateable CreateTable where
  runOperation = createTable

-- | An operation to drop the given table.
data DropTable = DropTable Text

instance Migrateable DropTable where
  runOperation = dropTable

-- | An operation to add the given column to an existing table.
data AddColumn = AddColumn
  { acTable :: Text
  , acColumn :: Column
  , acDefault :: Maybe Text
    -- ^ if the column is non-nullable and doesn't have a default, need to define a default for
    -- existing rows.
  }

instance Migrateable AddColumn where
  runOperation = addColumn

-- | An operation to drop the given column to an existing table.
data DropColumn = DropColumn
  { dcTable :: Text
  , dcColumn :: Text
  }

instance Migrateable DropColumn where
  runOperation = dropColumn

-- | A custom operation that can be defined manually.
newtype RawOperation = RawOperation (MigrateT IO ())

instance Migrateable RawOperation where
  runOperation _ (RawOperation op) = op

-- | If the given OperationId has not been run, don't run it. Otherwise, run the given Operation.
--
-- e.g. given:
-- @
-- migrations =
--   [ Operation 0 $ CreateTable "person" ...
--   , Operation 1 $ DropColumn "person" "name"
--   , Operation 2 $ Revert 1 $ AddColumn "person" (Column "name" ...) ...
--   ]
-- @
--
-- * Someone migrating an empty database will only run operation 0
-- * Someone who only ran 0 will not run anything
-- * Someone who ran 0 and 1 will run the AddColumn operation in 2
data Revert = Revert OperationId Operation

instance Migrateable Revert where
  runOperation backend (Revert _ (Operation _ op)) = runOperation backend op

  modifyMigration newId (Revert oldId _) migrations =
    if any ((== oldId) . opId . snd) migrations
      then setNoop [oldId, newId] migrations
      else migrations

-- | If none of the given OperationIds have been run, run the given operation instead.
--
-- e.g. given:
-- @
-- migrations =
--   [ Operation 0 $ CreateTable "person" ...
--   , Operation 1 $ AddColumn "person" (Column "height" ...) ...
--   , Operation 2 $ DropColumn "person" "height"
--   , Operation 3 $ Squash [1,2] []
--   ]
-- @
--
-- * Someone migrating an empty database will run operations 0 and 3
-- * Someone who only ran 0 will only run 3
-- * Someone who ran up to 1 will run 2, but not 3
-- * Someone who ran up to 2 will not run anything
data Squash = Squash [OperationId] [Operation]

instance Migrateable Squash where
  runOperation backend (Squash _ ops) = fmap concat . mapM helper $ ops
    where
      helper (Operation _ op) = runOperation backend op

  modifyMigration newId (Squash ids _) migrations =
    if all (`elem` map (opId . snd) migrations) ids
      then setNoop [newId] migrations
      else setNoop ids migrations

{- Auxiliary types -}

-- | The definition for a Column in a SQL database.
data Column = Column
  { colName :: Text
  , colType :: SqlType
  , colProps :: [ColumnProp]
  }

-- | A property for a 'Column'.
data ColumnProp
  = Nullable -- ^ Makes a 'Column' nullable (defaults to non-nullable)
  | Defaults Text -- ^ Set the default for inserted rows without a value specified for the column
  | ForeignKey (Text, Text) -- ^ Mark this column as a foreign key to the given table.column

-- | Table constraints in a CREATE query.
data TableConstraint
  = PrimaryKey [Text] -- ^ PRIMARY KEY (col1, col2, ...)
  | Unique [Text] -- ^ UNIQUE (col1, col2, ...)
