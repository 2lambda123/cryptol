{-# Language ImplicitParams #-}
module Cryptol.IR.TraverseNames where

import Data.Set(Set)
import qualified Data.Set as Set
import Data.Functor.Identity

import Cryptol.Utils.RecordMap(traverseRecordMap)
import Cryptol.Parser.Position(Located(..))
import Cryptol.TypeCheck.AST

traverseNames ::
  (TraverseNames t, Applicative f) => (Name -> f Name) -> (t -> f t)
traverseNames f = let ?name = f in traverseNamesIP

mapNames :: (TraverseNames t) => (Name -> Name) -> t -> t
mapNames f x = result
  where
  Identity result = let ?name = pure . f
                    in traverseNamesIP x

class TraverseNames t where
  traverseNamesIP :: (Applicative f, ?name :: Name -> f Name) => t -> f t

instance TraverseNames a => TraverseNames [a] where
  traverseNamesIP = traverse traverseNamesIP

instance TraverseNames a => TraverseNames (Maybe a) where
  traverseNamesIP = traverse traverseNamesIP

instance (Ord a, TraverseNames a) => TraverseNames (Set a) where
  traverseNamesIP = fmap Set.fromList . traverseNamesIP . Set.toList

instance TraverseNames a => TraverseNames (Located a) where
  traverseNamesIP (Located r a) = Located r <$> traverseNamesIP a

instance TraverseNames Name where
  traverseNamesIP = ?name

instance TraverseNames Expr where
  traverseNamesIP expr =
    case expr of
      EList es t        -> EList  <$> traverseNamesIP es <*> traverseNamesIP t

      ETuple es         -> ETuple <$> traverseNamesIP es

      ERec mp           -> ERec <$> traverseRecordMap (\_ -> traverseNamesIP) mp

      ESel e l          -> (`ESel` l) <$> traverseNamesIP e

      ESet t e1 l e2    -> ESet <$> traverseNamesIP t
                                <*> traverseNamesIP e1
                                <*> pure l
                                <*> traverseNamesIP e2

      EIf e1 e2 e3      -> EIf <$> traverseNamesIP e1
                               <*> traverseNamesIP e2
                               <*> traverseNamesIP e3

      EComp t1 t2 e mss -> EComp <$> traverseNamesIP t1
                                 <*> traverseNamesIP t2
                                 <*> traverseNamesIP e
                                 <*> traverseNamesIP mss

      EVar x            -> EVar <$> traverseNamesIP x
      ETAbs tp e        -> ETAbs tp <$> traverseNamesIP e
      ETApp e t         -> ETApp <$> traverseNamesIP e <*> traverseNamesIP t
      EApp e1 e2        -> EApp <$> traverseNamesIP e1 <*> traverseNamesIP e2
      EAbs x t e        -> EAbs <$> traverseNamesIP x
                                <*> traverseNamesIP t
                                <*> traverseNamesIP e
      ELocated r e      -> ELocated r <$> traverseNamesIP e
      EProofAbs p e     -> EProofAbs <$> traverseNamesIP p <*> traverseNamesIP e
      EProofApp e       -> EProofApp <$> traverseNamesIP e
      EWhere e ds       -> EWhere <$> traverseNamesIP e <*> traverseNamesIP ds

instance TraverseNames Match where
  traverseNamesIP mat =
    case mat of
      From x t1 t2 e -> From <$> traverseNamesIP x
                             <*> traverseNamesIP t1
                             <*> traverseNamesIP t2
                             <*> traverseNamesIP e
      Let d          -> Let <$> traverseNamesIP d

instance TraverseNames DeclGroup where
  traverseNamesIP dg =
    case dg of
      NonRecursive d -> NonRecursive <$> traverseNamesIP d
      Recursive ds   -> Recursive    <$> traverseNamesIP ds

instance TraverseNames Decl where
  traverseNamesIP decl = mk <$> traverseNamesIP (dName decl)
                            <*> traverseNamesIP (dSignature decl)
                            <*> traverseNamesIP (dDefinition decl)
    where mk nm sig def = decl { dName = nm
                               , dSignature = sig
                               , dDefinition = def
                               }

instance TraverseNames DeclDef where
  traverseNamesIP d =
    case d of
      DPrim   -> pure d
      DExpr e -> DExpr <$> traverseNamesIP e

instance TraverseNames Schema where
  traverseNamesIP (Forall as ps t) =
    Forall as <$> traverseNamesIP ps <*> traverseNamesIP t


instance TraverseNames TPFlavor where
  traverseNamesIP tpf =
    case tpf of
      TPUnifyVar        -> pure tpf
      TPSchemaParam x   -> TPSchemaParam  <$> traverseNamesIP x
      TPTySynParam x    -> TPTySynParam   <$> traverseNamesIP x
      TPPropSynParam x  -> TPPropSynParam <$> traverseNamesIP x
      TPNewtypeParam x  -> TPNewtypeParam <$> traverseNamesIP x
      TPPrimParam x     -> TPPrimParam    <$> traverseNamesIP x

instance TraverseNames TVarInfo where
  traverseNamesIP (TVarInfo r s) = TVarInfo r <$> traverseNamesIP s

instance TraverseNames TypeSource where
  traverseNamesIP src =
    case src of
      TVFromModParam x            -> TVFromModParam <$> traverseNamesIP x
      TVFromSignature x           -> TVFromSignature <$> traverseNamesIP x
      TypeWildCard                -> pure src
      TypeOfRecordField {}        -> pure src
      TypeOfTupleField {}         -> pure src
      TypeOfSeqElement            -> pure src
      LenOfSeq                    -> pure src
      TypeParamInstNamed x i      -> TypeParamInstNamed <$> traverseNamesIP x
                                                        <*> pure i
      TypeParamInstPos   x i      -> TypeParamInstPos   <$> traverseNamesIP x
                                                        <*> pure i
      DefinitionOf x              -> DefinitionOf <$> traverseNamesIP x
      LenOfCompGen                -> pure src
      TypeOfArg arg               -> TypeOfArg <$> traverseNamesIP arg
      TypeOfRes                   -> pure src
      FunApp                      -> pure src
      TypeOfIfCondExpr            -> pure src
      TypeFromUserAnnotation      -> pure src
      GeneratorOfListComp         -> pure src
      TypeErrorPlaceHolder        -> pure src

instance TraverseNames ArgDescr where
  traverseNamesIP arg = mk <$> traverseNamesIP (argDescrFun arg)
    where mk n = arg { argDescrFun = n }

instance TraverseNames Type where
  traverseNamesIP ty =
    case ty of
      TCon tc ts    -> TCon <$> traverseNamesIP tc <*> traverseNamesIP ts
      TVar x        -> TVar <$> traverseNamesIP x
      TUser x ts t  -> TUser <$> traverseNamesIP x
                             <*> traverseNamesIP ts
                             <*> traverseNamesIP t
      TRec rm       -> TRec <$> traverseRecordMap (\_ -> traverseNamesIP) rm
      TNewtype nt ts -> TNewtype <$> traverseNamesIP nt <*> traverseNamesIP ts

-- XXX: It might be better to arrange to not have names here?
instance TraverseNames TCon where
  traverseNamesIP tcon =
    case tcon of
      TC tc -> TC <$> traverseNamesIP tc
      _ -> pure tcon

instance TraverseNames TC where
  traverseNamesIP tc =
    case tc of
      TCAbstract ut -> TCAbstract <$> traverseNamesIP ut
      _ -> pure tc

instance TraverseNames UserTC where
  traverseNamesIP (UserTC x k) = UserTC <$> traverseNamesIP x <*> pure k

instance TraverseNames TVar where
  traverseNamesIP tvar =
    case tvar of
      TVFree x k ys i -> TVFree x k ys <$> traverseNamesIP i
      TVBound x       -> pure (TVBound x)

instance TraverseNames Newtype where
  traverseNamesIP nt = mk <$> traverseNamesIP (ntName nt)
                          <*> pure (ntParams nt)
                          <*> traverseNamesIP (ntConstraints nt)
                          <*> traverseRecordMap (\_ -> traverseNamesIP)
                                                (ntFields nt)
    where
    mk a b c d = nt { ntName = a
                    , ntParams = b
                    , ntConstraints = c
                    , ntFields = d
                    }

instance TraverseNames ModTParam where
  traverseNamesIP nt = mk <$> traverseNamesIP (mtpName nt)
    where
    mk x = nt { mtpName = x }

instance TraverseNames ModVParam where
  traverseNamesIP nt = mk <$> traverseNamesIP (mvpName nt)
                          <*> traverseNamesIP (mvpType nt)
    where
    mk x t = nt { mvpName = x, mvpType = t }


