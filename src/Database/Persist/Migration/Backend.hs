{-|
Module      :  Database.Persist.Migration.Backend
Maintainer  :  Brandon Chinn <brandonchinn178@gmail.com>
Stability   :  experimental
Portability :  portable

Defines `MigrateBackend`, the data constructor that each SQL backend will need to implement.
-}

module Database.Persist.Migration.Backend (MigrateBackend(..)) where

import Data.Text (Text)
import Database.Persist.Migration.Operation (Operation)
import Database.Persist.Sql (SqlPersistT)

-- | The backend to migrate with.
newtype MigrateBackend = MigrateBackend
  { getMigrationText :: Operation -> SqlPersistT IO [Text]
  }
