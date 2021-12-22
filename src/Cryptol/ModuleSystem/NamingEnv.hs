-- |
-- Module      :  Cryptol.ModuleSystem.NamingEnv
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Cryptol.ModuleSystem.NamingEnv where

import Data.Maybe (mapMaybe,maybeToList)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Set (Set)
import qualified Data.Set as Set

import GHC.Generics (Generic)
import Control.DeepSeq(NFData)

import Cryptol.Utils.PP
import Cryptol.Utils.Panic (panic)
import Cryptol.Utils.Ident(allNamespaces)
import Cryptol.Parser.AST
import qualified Cryptol.TypeCheck.AST as T
import Cryptol.ModuleSystem.Name
import Cryptol.ModuleSystem.Names
import Cryptol.ModuleSystem.Interface


-- | The 'NamingEnv' is used by the renamer to determine what
-- identifiers refer to.
newtype NamingEnv = NamingEnv (Map Namespace (Map PName Names))
  deriving (Show,Generic,NFData)

instance Monoid NamingEnv where
  mempty = NamingEnv Map.empty
  {-# INLINE mempty #-}

instance Semigroup NamingEnv where
  NamingEnv l <> NamingEnv r =
    NamingEnv (Map.unionWith (Map.unionWith (<>)) l r)

instance PP NamingEnv where
  ppPrec _ (NamingEnv mps)   = vcat $ map ppNS $ Map.toList mps
    where ppNS (ns,xs) = nest 2 (vcat (pp ns : map ppNm (Map.toList xs)))
          ppNm (x,as)  = pp x <+> "->" <+> commaSep (map pp (namesToList as))



-- | All names mentioned in the environment
namingEnvNames :: NamingEnv -> Set Name
namingEnvNames (NamingEnv xs) =
  case unionManyNames (mapMaybe (unionManyNames . Map.elems) (Map.elems xs)) of
    Nothing -> Set.empty
    Just (One x) -> Set.singleton x
    Just (Ambig as) -> as

-- | Get the names in a given namespace
namespaceMap :: Namespace -> NamingEnv -> Map PName Names
namespaceMap ns (NamingEnv env) = Map.findWithDefault Map.empty ns env

-- | Resolve a name in the given namespace.
lookupNS :: Namespace -> PName -> NamingEnv -> Maybe Names
lookupNS ns x env = Map.lookup x (namespaceMap ns env)

-- | Resolve a name in the given namespace.
lookupListNS :: Namespace -> PName -> NamingEnv -> [Name]
lookupListNS ns x env =
  case lookupNS ns x env of
    Nothing -> []
    Just as -> namesToList as

-- | Singleton renaming environment for the given namespace.
singletonNS :: Namespace -> PName -> Name -> NamingEnv
singletonNS ns pn n = NamingEnv (Map.singleton ns (Map.singleton pn (One n)))

-- | Generate a mapping from 'PrimIdent' to 'Name' for a
-- given naming environment.
toPrimMap :: NamingEnv -> PrimMap
toPrimMap env =
  PrimMap
    { primDecls = fromNS NSValue
    , primTypes = fromNS NSType
    }
  where
  fromNS ns = Map.fromList
                [ entry x | xs <- Map.elems (namespaceMap ns env)
                          , x <- namesToList xs ]

  entry n = case asPrim n of
              Just p  -> (p,n)
              Nothing -> panic "toPrimMap" [ "Not a declared name?"
                                           , show n
                                           ]


-- | Generate a display format based on a naming environment.
toNameDisp :: NamingEnv -> NameDisp
toNameDisp env = NameDisp (`Map.lookup` names)
  where
  names = Map.fromList
            [ (og, qn)
              | ns            <- allNamespaces
              , (pn,xs)       <- Map.toList (namespaceMap ns env)
              , x             <- namesToList xs
              , og            <- maybeToList (asOrigName x)
              , let qn = case getModName pn of
                          Just q  -> Qualified q
                          Nothing -> UnQualified
            ]


-- | Produce sets of visible names for types and declarations.
--
-- NOTE: if entries in the NamingEnv would have produced a name clash,
-- they will be omitted from the resulting sets.
visibleNames :: NamingEnv -> Map Namespace (Set Name)
visibleNames (NamingEnv env) = check <$> env
  where check mp = Set.fromList [ a | One a <- Map.elems mp ]

-- | Qualify all symbols in a 'NamingEnv' with the given prefix.
qualify :: ModName -> NamingEnv -> NamingEnv
qualify pfx (NamingEnv env) = NamingEnv (Map.mapKeys toQual <$> env)
  where
  -- We don't qualify fresh names, because they should not be directly
  -- visible to the end users (i.e., they shouldn't really be exported)
  toQual (Qual _ n)  = Qual pfx n
  toQual (UnQual n)  = Qual pfx n
  toQual n@NewName{} = n

filterNames :: (PName -> Bool) -> NamingEnv -> NamingEnv
filterNames p (NamingEnv env) = NamingEnv (Map.filterWithKey check <$> env)
  where check n _ = p n


-- | Restrict an environment to contain only the ambiguous names
onlyAmbig :: NamingEnv -> NamingEnv
onlyAmbig (NamingEnv xs) =
  NamingEnv (Map.filter (not . Map.null) (Map.filter isAmbig <$> xs))
  where
  isAmbig x = case x of
                One {}   -> False
                Ambig {} -> True

-- | Get the subset of the first environment that shadows something
-- in the second one.
onlyShadowing :: NamingEnv -> NamingEnv -> NamingEnv
onlyShadowing (NamingEnv lhs) rhs = NamingEnv
                                      (Map.filter (not . Map.null)
                                                  (Map.mapWithKey doNS lhs))
  where
  doNS ns = Map.filterWithKey \nm' _ ->
              case lookupNS ns nm' rhs of
                Just {} -> True
                _       -> False

-- | Do an arbitrary choice for ambiguous names.
-- We do this to continue checking afetr we've reported an ambiguity error.
forceUnambig :: NamingEnv -> NamingEnv
forceUnambig (NamingEnv mp) = NamingEnv (fmap (One . anyOne) <$> mp)

-- | Like mappend, but when merging, prefer values on the lhs.
shadowing :: NamingEnv -> NamingEnv -> NamingEnv
shadowing (NamingEnv l) (NamingEnv r) = NamingEnv (Map.unionWith Map.union l r)

mapNamingEnv :: (Name -> Name) -> NamingEnv -> NamingEnv
mapNamingEnv f (NamingEnv mp) = NamingEnv (fmap (mapNames f) <$> mp)

travNamingEnv :: Applicative f => (Name -> f Name) -> NamingEnv -> f NamingEnv
travNamingEnv f (NamingEnv mp) =
  NamingEnv <$> traverse (traverse (travNames f)) mp

isEmptyNamingEnv :: NamingEnv -> Bool
isEmptyNamingEnv (NamingEnv mp) = Map.null mp
-- This assumes that we've been normalizing away empty maps, hopefully
-- we've been doing it everywhere.



-- | Compute an unqualified naming environment, containing the various module
-- parameters.
modParamsNamingEnv :: IfaceParams -> NamingEnv
modParamsNamingEnv IfaceParams { .. } =
  NamingEnv $ Map.fromList
    [ (NSValue, Map.fromList $ map fromFu $ Map.keys ifParamFuns)
    , (NSType,  Map.fromList $ map fromTy $ Map.elems ifParamTypes)
    ]
  where
  toPName n = mkUnqual (nameIdent n)

  fromTy tp = let nm = T.mtpName tp
              in (toPName nm, One nm)

  fromFu f  = (toPName f, One f)


-- | Generate a naming environment from a declaration interface, where none of
-- the names are qualified.
unqualifiedEnv :: IfaceDecls -> NamingEnv
unqualifiedEnv IfaceDecls { .. } =
  mconcat [ exprs, tySyns, ntTypes, absTys, ntExprs, mods, sigs ]
  where
  toPName n = mkUnqual (nameIdent n)

  exprs   = mconcat [ singletonNS NSValue (toPName n) n
                    | n <- Map.keys ifDecls ]

  tySyns  = mconcat [ singletonNS NSType (toPName n) n
                    | n <- Map.keys ifTySyns ]

  ntTypes = mconcat [ singletonNS NSType (toPName n) n
                    | n <- Map.keys ifNewtypes ]

  absTys  = mconcat [ singletonNS NSType (toPName n) n
                    | n <- Map.keys ifAbstractTypes ]

  ntExprs = mconcat [ singletonNS NSValue (toPName n) n
                    | n <- Map.keys ifNewtypes ]

  mods    = mconcat [ singletonNS NSModule (toPName n) n
                    | n <- Map.keys ifModules ]

  sigs    = mconcat [ singletonNS NSSignature (toPName n) n
                    | n <- Map.keys ifSignatures ]



