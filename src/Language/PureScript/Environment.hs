-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.Environment
-- Copyright   :  (c) 2013-14 Phil Freeman, (c) 2014 Gary Burgess, and other contributors
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Language.PureScript.Environment where

import Data.Data
import Data.Maybe (fromMaybe)
import Data.Aeson.TH
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Aeson as A

import Language.PureScript.Crash
import Language.PureScript.Kinds
import Language.PureScript.Names
import Language.PureScript.TypeClassDictionaries
import Language.PureScript.Types
import qualified Language.PureScript.Constants as C

-- |
-- The @Environment@ defines all values and types which are currently in scope:
--
data Environment = Environment {
  -- |
  -- Value names currently in scope
  --
    names :: M.Map (ModuleName, Ident) (Type, NameKind, NameVisibility)
  -- |
  -- Type names currently in scope
  --
  , types :: M.Map (Qualified ProperName) (Kind, TypeKind)
  -- |
  -- Data constructors currently in scope, along with their associated type
  -- constructor name, argument types and return type.
  , dataConstructors :: M.Map (Qualified ProperName) (DataDeclType, ProperName, Type, [Ident])
  -- |
  -- Type synonyms currently in scope
  --
  , typeSynonyms :: M.Map (Qualified ProperName) ([(String, Maybe Kind)], Type)
  -- |
  -- Available type class dictionaries
  --
  , typeClassDictionaries :: M.Map (Maybe ModuleName) (M.Map (Qualified ProperName) (M.Map (Qualified Ident) TypeClassDictionaryInScope))
  -- |
  -- Type classes
  --
  , typeClasses :: M.Map (Qualified ProperName) ([(String, Maybe Kind)], [(Ident, Type)], [Constraint])
  } deriving (Show, Read)

-- |
-- The initial environment with no values and only the default javascript types defined
--
initEnvironment :: Environment
initEnvironment = Environment M.empty primTypes M.empty M.empty M.empty M.empty

-- |
-- The visibility of a name in scope
--
data NameVisibility
  -- |
  -- The name is defined in the current binding group, but is not visible
  --
  = Undefined
  -- |
  -- The name is defined in the another binding group, or has been made visible by a function binder
  --
  | Defined deriving (Show, Read, Eq)

-- |
-- A flag for whether a name is for an private or public value - only public values will be
-- included in a generated externs file.
--
data NameKind
  -- |
  -- A private value introduced as an artifact of code generation (class instances, class member
  -- accessors, etc.)
  --
  = Private
  -- |
  -- A public value for a module member or foreing import declaration
  --
  | Public
  -- |
  -- A name for member introduced by foreign import
  --
  | External deriving (Show, Read, Eq, Data, Typeable)

-- |
-- The kinds of a type
--
data TypeKind
  -- |
  -- Data type
  --
  = DataType [(String, Maybe Kind)] [(ProperName, [Type])]
  -- |
  -- Type synonym
  --
  | TypeSynonym
  -- |
  -- Foreign data
  --
  | ExternData
  -- |
  -- A local type variable
  --
  | LocalTypeVariable
  -- |
  -- A scoped type variable
  --
  | ScopedTypeVar
   deriving (Show, Read, Eq, Data, Typeable)

-- |
-- The type ('data' or 'newtype') of a data type declaration
--
data DataDeclType
  -- |
  -- A standard data constructor
  --
  = Data
  -- |
  -- A newtype constructor
  --
  | Newtype deriving (Show, Read, Eq, Ord, Data, Typeable)

showDataDeclType :: DataDeclType -> String
showDataDeclType Data = "data"
showDataDeclType Newtype = "newtype"

instance A.ToJSON DataDeclType where
  toJSON = A.toJSON . showDataDeclType

instance A.FromJSON DataDeclType where
  parseJSON = A.withText "DataDeclType" $ \str ->
    case str of
      "data" -> return Data
      "newtype" -> return Newtype
      other -> fail $ "invalid type: '" ++ T.unpack other ++ "'"

-- |
-- Construct a ProperName in the Prim module
--
primName :: String -> Qualified ProperName
primName = Qualified (Just $ ModuleName [ProperName C.prim]) . ProperName

-- |
-- Construct a type in the Prim module
--
primTy :: String -> Type
primTy = TypeConstructor . primName

-- |
-- Type constructor for functions
--
tyFunction :: Type
tyFunction = primTy "Function"

-- |
-- Type constructor for strings
--
tyString :: Type
tyString = primTy "String"

-- |
-- Type constructor for strings
--
tyChar :: Type
tyChar = primTy "Char"

-- |
-- Type constructor for numbers
--
tyNumber :: Type
tyNumber = primTy "Number"

-- |
-- Type constructor for integers
--
tyInt :: Type
tyInt = primTy "Int"

-- |
-- Type constructor for booleans
--
tyBoolean :: Type
tyBoolean = primTy "Boolean"

-- |
-- Type constructor for arrays
--
tyArray :: Type
tyArray = primTy "Array"

-- |
-- Type constructor for objects
--
tyObject :: Type
tyObject = primTy "Object"

-- |
-- Check whether a type is an object
--
isObject :: Type -> Bool
isObject = isTypeOrApplied tyObject

-- |
-- Check whether a type is a function
--
isFunction :: Type -> Bool
isFunction = isTypeOrApplied tyFunction

isTypeOrApplied :: Type -> Type -> Bool
isTypeOrApplied t1 (TypeApp t2 _) = t1 == t2
isTypeOrApplied t1 t2 = t1 == t2

-- |
-- Smart constructor for function types
--
function :: Type -> Type -> Type
function t1 = TypeApp (TypeApp tyFunction t1)

-- |
-- The primitive types in the external javascript environment with their associated kinds.
--
primTypes :: M.Map (Qualified ProperName) (Kind, TypeKind)
primTypes = M.fromList [ (primName "Function" , (FunKind Star (FunKind Star Star), ExternData))
                       , (primName "Array"    , (FunKind Star Star, ExternData))
                       , (primName "Object"   , (FunKind (Row Star) Star, ExternData))
                       , (primName "String"   , (Star, ExternData))
                       , (primName "Char"     , (Star, ExternData))
                       , (primName "Number"   , (Star, ExternData))
                       , (primName "Int"      , (Star, ExternData))
                       , (primName "Boolean"  , (Star, ExternData)) ]

-- |
-- Finds information about data constructors from the current environment.
--
lookupConstructor :: Environment -> Qualified ProperName -> (DataDeclType, ProperName, Type, [Ident])
lookupConstructor env ctor =
  fromMaybe (internalError "Data constructor not found") $ ctor `M.lookup` dataConstructors env

-- |
-- Checks whether a data constructor is for a newtype.
--
isNewtypeConstructor :: Environment -> Qualified ProperName -> Bool
isNewtypeConstructor e ctor = case lookupConstructor e ctor of
  (Newtype, _, _, _) -> True
  (Data, _, _, _) -> False

-- |
-- Finds information about values from the current environment.
--
lookupValue :: Environment -> Qualified Ident -> Maybe (Type, NameKind, NameVisibility)
lookupValue env (Qualified (Just mn) ident) = (mn, ident) `M.lookup` names env
lookupValue _ _ = Nothing

$(deriveJSON (defaultOptions { sumEncoding = ObjectWithSingleField }) ''TypeKind)
