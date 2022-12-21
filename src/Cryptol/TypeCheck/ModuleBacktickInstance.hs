{-# Language ImplicitParams #-}
{-# Language FlexibleInstances #-}
{-# Language RecursiveDo #-}
{-# Language BlockArguments #-}
{-# Language RankNTypes #-}
{-# Language OverloadedStrings #-}
module Cryptol.TypeCheck.ModuleBacktickInstance where

import Data.Map(Map)
import qualified Data.Map as Map
import MonadLib

import Cryptol.Utils.Ident(ModPath(..), modPathIsOrContains,Namespace(..),
                                                                    mkIdent)
import Cryptol.Utils.PP(pp)
import Cryptol.Utils.Panic(panic)
import Cryptol.Utils.RecordMap(RecordMap,recordFromFields,recordFromFieldsErr)
import Cryptol.Parser.Position
import Cryptol.ModuleSystem.Name(nameModPath, nameModPathMaybe, nameIdent)
import Cryptol.TypeCheck.AST
import Cryptol.TypeCheck.Error
import qualified Cryptol.TypeCheck.Monad as TC

{- | Rewrite declarations to add the given module parameters.
Assumes the renaming due to the instantiation has already happened.
The module being rewritten should not contain any nested functors
(or module with only top-level constraints) because it is not clear
how to parameterize the parameters.
-}
doBacktickInstance ::
  [TParam] ->
  [Prop] ->
  Map Name Type ->
  ModuleG (Located (ImpName Name)) ->
  TC.InferM (ModuleG (Located (ImpName Name)))
doBacktickInstance as ps mp m
  | null as && null ps && Map.null mp = pure m
  | otherwise =
    runReaderT
      RO { isOurs = \x -> case nameModPathMaybe x of
                            Nothing -> False
                            Just y  -> ourPath `modPathIsOrContains` y
         , tparams = as
         , constraints = ps
         , vparams = mp
         , newNewtypes = Map.empty
         }

    do unless (null bad)
              (recordError (FunctorInstanceBadBacktick (BINested bad)))

       rec
         ts <- doAddParams nt mTySyns
         nt <- doAddParams nt mNewtypes
         ds <- doAddParams nt mDecls

       pure m
         { mTySyns   = ts
         , mNewtypes = nt
         , mDecls    = ds
         }

    where
    bad = mkBad mFunctors BIFunctor
       ++ mkBad mPrimTypes BIAbstractType
       ++ mkBad mSignatures BIInterface

    mkBad sel a = [ (a,k) | k <- Map.keys (sel m) ]

    ourPath = case thing (mName m) of
                ImpTop mo    -> TopModule mo
                ImpNested mo -> Nested (nameModPath mo) (nameIdent mo)

    doAddParams nt sel =
      mapReader (\ro -> ro { newNewtypes = nt }) (addParams (sel m))


type RewM = ReaderT RO TC.InferM

recordError :: Error -> RewM ()
recordError e = lift (TC.recordError e)

data RO = RO
  { isOurs       :: Name -> Bool
  , tparams      :: [TParam]
  , constraints  :: [Prop]
  , vparams      :: Map Name Type
  , newNewtypes  :: Map Name Newtype
  }


class AddParams t where
  addParams :: t -> RewM t

instance AddParams a => AddParams (Map Name a) where
  addParams = mapM addParams

instance AddParams a => AddParams [a] where
  addParams = mapM addParams

instance AddParams Newtype where
  addParams nt =
    do (tps,cs) <- newTypeParams TPNewtypeParam
       rProps   <- rewTypeM tps (ntConstraints nt)
       rFields  <- rewTypeM tps (ntFields nt)
       pure nt
         { ntParams       = pDecl tps ++ ntParams nt
         , ntConstraints  = cs ++ rProps
         , ntFields       = rFields
         }

instance AddParams TySyn where
  addParams ts =
    do (tps,cs) <- newTypeParams TPTySynParam
       rProps   <- rewTypeM tps (tsConstraints ts)
       rDef     <- rewTypeM tps (tsDef ts)
       pure ts
         { tsParams      = pDecl tps ++ tsParams ts
         , tsConstraints = cs ++ rProps
         , tsDef         = rDef
         }

instance AddParams DeclGroup where
  addParams dg =
    case dg of
      Recursive ds   -> Recursive <$> addParams ds
      NonRecursive d -> NonRecursive <$> addParams d

instance AddParams Decl where
  addParams d =
    case dDefinition d of
      DPrim       -> bad BIPrimitive
      DForeign {} -> bad BIForeign
      DExpr e ->
        do (tps,cs) <- newTypeParams TPSchemaParam
           (vps,bs) <- newValParams tps
           let s = dSignature d

           ty1 <- rewTypeM tps (sType s)
           let ty2 = foldr tFun ty1 (map snd bs)

           e1 <- rewValM tps (length cs) vps e
           let (das,e2) = splitWhile splitTAbs     e1
               (dcs,e3) = splitWhile splitProofAbs e2
               e4 = foldr (uncurry EAbs) e3 bs
               e5 = foldr EProofAbs e4 (cs ++ dcs)
               e6 = foldr ETAbs     e5 (pDecl tps ++ das)

               s1 = Forall
                      { sVars  = pDecl tps ++ sVars s
                      , sProps = cs ++ sProps s
                      , sType  = ty2
                      }

           pure d { dDefinition = DExpr e6
                  , dSignature  = s1
                  }
    where
    bad w =
      do recordError (FunctorInstanceBadBacktick (BINested [(w,dName d)]))
         pure d

data Params decl use = Params
  { pDecl   :: [decl]
  , pUse    :: [use]
  , pSubst  :: Map decl use
  }

noParams :: Params decl use
noParams = Params
  { pDecl   = []
  , pUse    = []
  , pSubst  = Map.empty
  }

type TypeParams = Params TParam Type
type ValParams  = Params Name   Expr

newTypeParams :: (Name -> TPFlavor) -> RewM (TypeParams,[Prop])
newTypeParams flav =
  do ro <- ask
     as <- lift (mapM (TC.freshTParam flav) (tparams ro))
     let ts = map (TVar . TVBound) as
         su = Map.fromList (zip (tparams ro) ts)
         ps = Params { pDecl = as, pUse = ts, pSubst = su }
     cs <- rewTypeM ps (constraints ro)
     pure (ps,cs)

-- Note: we pass all value parameters as a record
newValParams :: TypeParams -> RewM (ValParams, [(Name,Type)])
newValParams tps =
  do ro <- ask
     let vps = vparams ro
     if Map.null vps
       then pure (noParams, [])
       else do xts <- forM (Map.toList vps) \(x,t) ->
                        do t1 <- rewTypeM tps t
                           pure (x,t1)
               let (xs,ts) = unzip xts
                   ls      = map nameIdent xs
                   fs      = zip ls ts
                   sel x   = RecordSel (nameIdent x) (Just ls)

               t <- case recordFromFieldsErr fs of
                      Right ok -> pure (TRec ok)
                      Left (x,_) ->
                        do recordError (FunctorInstanceBadBacktick
                                          (BIMultipleParams x))
                           pure (TRec (recordFromFields fs))

               r <- lift (TC.newLocalName NSValue (mkIdent "params"))
               let e = EVar r
               pure
                 ( Params
                     { pDecl  = [r]
                     , pUse   = [e]
                     , pSubst = Map.fromList [ (x,ESel e (sel x)) | x <- xs ]
                     }
                 , [ (r,t) ]
                 )

liftRew ::
  ((?isOurs :: Name -> Bool, ?newNewtypes :: Map Name Newtype) => a) ->
  RewM a
liftRew x =
  do ro <- ask
     let ?isOurs      = isOurs ro
         ?newNewtypes = newNewtypes ro
     pure x

rewTypeM :: RewType t => TypeParams -> t -> RewM t
rewTypeM ps x =
  do let ?tparams = ps
     liftRew rewType <*> pure x

rewValM :: RewVal t => TypeParams -> Int -> ValParams -> t -> RewM t
rewValM ts cs vs x =
  do let ?tparams = ts
         ?cparams = cs
         ?vparams = vs
     liftRew rew <*> pure x

class RewType t where
  rewType ::
    ( ?isOurs      :: Name -> Bool
    , ?newNewtypes :: Map Name Newtype    -- Lazy
    , ?tparams     :: TypeParams
    ) => t -> t

instance RewType Type where
  rewType ty =
    case ty of

      TCon tc ts
        | TC (TCAbstract (UserTC x _)) <- tc
        , ?isOurs x  -> TCon tc (pUse ?tparams ++ rewType ts)
        | otherwise  -> TCon tc (rewType ts)

      TVar x ->
        case x of
          TVBound x' ->
            case Map.lookup x' (pSubst ?tparams) of
              Just t  -> t
              Nothing -> ty
          TVFree {} -> panic "rawType" ["Free unification variable"]

      TUser f ts t
        | ?isOurs f -> TUser f (pUse ?tparams ++ rewType ts) (rewType t)
        | otherwise -> TUser f (rewType ts) (rewType t)

      TRec fs -> TRec (rewType fs)

      TNewtype tdef ts
        | ?isOurs nm -> TNewtype tdef' (pUse ?tparams ++ rewType ts)
        | otherwise  -> TNewtype tdef (rewType ts)
        where
        nm    = ntName tdef
        tdef' = case Map.lookup nm ?newNewtypes of
                  Just yes -> yes
                  Nothing  -> panic "rewType" [ "Missing recursive newtype"
                                              , show (pp nm) ]

instance RewType a => RewType [a] where
  rewType = fmap rewType

instance RewType b => RewType (RecordMap a b) where
  rewType = fmap rewType

instance RewType Schema where
  rewType sch =
    Forall { sVars  = sVars sch
           , sProps = rewType (sProps sch)
           , sType  = rewType (sType sch)
           }


class RewVal t where
  rew ::
    ( ?isOurs      :: Name -> Bool
    , ?newNewtypes :: Map Name Newtype    -- Lazy
    , ?tparams     :: TypeParams
    , ?cparams     :: Int                 -- Number of constraitns
    , ?vparams     :: ValParams
    ) => t -> t

instance RewVal a => RewVal [a] where
  rew = fmap rew

instance RewVal b => RewVal (RecordMap a b) where
  rew = fmap rew

{- x as cs vs  -->
   e (newAs ++ as) (newCS ++ cs) (newVS ++ vs)
-}
instance RewVal Expr where
  rew expr =
    case expr of
      EList es t        -> EList (rew es) (rewType t)
      ETuple es         -> ETuple (rew es)
      ERec fs           -> ERec (rew fs)
      ESel e l          -> ESel (rew e) l
      ESet t e1 s e2    -> ESet (rewType t) (rew e1) s (rew e2)
      EIf e1 e2 e3      -> EIf (rew e1) (rew e2) (rew e3)
      EComp t1 t2 e mss -> EComp (rewType t1) (rewType t2) (rew e) (rew mss)
      EVar x            -> tryVarApp
                           case Map.lookup x (pSubst ?vparams) of
                             Just p  -> p
                             Nothing -> expr

      ETApp e t         -> tryVarApp (ETApp (rew e) (rewType t))
      EProofApp e       -> tryVarApp (EProofApp (rew e))

      EApp e1 e2        -> EApp (rew e1) (rew e2)
      ETAbs a e         -> ETAbs a (rew e)
      EAbs x t e        -> EAbs x (rewType t) (rew e)
      ELocated r e      -> ELocated r (rew e)
      EProofAbs p e     -> EProofAbs (rewType p) (rew e)
      EWhere e ds       -> EWhere (rew e) (rew ds)
      EPropGuards gs t  -> EPropGuards gs' (rewType t)
        where gs' = [ (rewType <$> p, rew e) | (p,e) <- gs ]

    where
    tryVarApp orElse =
      case splitExprInst expr of
        (EVar x, ts, cs) | ?isOurs x ->
           let ets = foldl ETApp (EVar x) (pUse ?tparams ++ rewType ts)
               eps = iterate EProofApp ets !! (?cparams + cs)
               evs = foldl EApp eps (pUse ?vparams)
           in evs
        _ -> orElse


instance RewVal DeclGroup where
  rew dg =
    case dg of
      Recursive ds    -> Recursive (rew ds)
      NonRecursive d  -> NonRecursive (rew d)

instance RewVal Decl where
  rew d = d { dDefinition = rew (dDefinition d)
            , dSignature  = rewType (dSignature d)
            }

instance RewVal DeclDef where
  rew def =
    case def of
      DPrim       -> def
      DForeign {} -> def
      DExpr e     -> DExpr (rew e)

instance RewVal Match where
  rew ma =
    case ma of
      From x t1 t2 e -> From x (rewType t1) (rewType t2) (rew e)
      Let d          -> Let (rew d)


