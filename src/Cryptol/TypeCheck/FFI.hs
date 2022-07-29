{-# LANGUAGE BlockArguments  #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns    #-}

module Cryptol.TypeCheck.FFI
  ( toFFIFunType
  ) where

import           Data.Either

import           Cryptol.TypeCheck.FFI.Error
import           Cryptol.TypeCheck.FFI.FFIType
import           Cryptol.TypeCheck.SimpType
import           Cryptol.TypeCheck.Type
import           Cryptol.Utils.RecordMap

toFFIFunType :: Schema -> Either FFITypeError ([Prop], FFIFunType)
toFFIFunType (Forall params props t) = case go $ tRebuild' False t of
  Just (Right r)   -> Right r
  Just (Left errs) -> Left $ FFITypeError t $ FFIBadComponentTypes errs
  Nothing          -> Left $ FFITypeError t FFINotFunction
  where go (TCon (TC TCFun) [argType, retType]) = Just case toFFIType argType of
          Right (ps, ffiArgType) -> case go retType of
            Just (Right (ps', ffiFunType)) -> Right
              ( ps ++ ps'
              , ffiFunType
                  { ffiArgTypes = ffiArgType : ffiArgTypes ffiFunType } )
            Just (Left errs) -> Left errs
            Nothing -> case toFFIType retType of
              Right (ps', ffiRetType) -> Right
                ( ps ++ ps' ++ map (fin . TVar . TVBound) params ++ props
                , FFIFunType
                    { ffiTParams = params, ffiArgTypes = [ffiArgType], .. } )
              Left err -> Left [err]
          Left err -> Left case go retType of
            Just (Right _) -> [err]
            Just (Left errs) -> err : errs
            Nothing -> case toFFIType retType of
              Right _   -> [err]
              Left err' -> [err, err']
        go _ = Nothing

toFFIType :: Type -> Either FFITypeError ([Prop], FFIType)
toFFIType t = case t of
  TCon (TC TCBit) [] -> Right ([], FFIBool)
  (toFFIBasicType -> Just r) -> (\fbt -> ([], FFIBasic fbt)) <$> r
  TCon (TC TCSeq) [sz, bt] -> case toFFIBasicType bt of
    Just (Right fbt) -> Right ([fin sz], FFIArray sz fbt)
    Just (Left err) -> Left $ FFITypeError t $ FFIBadComponentTypes [err]
    Nothing -> Left $ FFITypeError t FFIBadArrayType
  TCon (TC (TCTuple _)) ts -> case partitionEithers $ map toFFIType ts of
    ([], unzip -> (pss, fts)) -> Right (concat pss, FFITuple fts)
    (errs, _) -> Left $ FFITypeError t $ FFIBadComponentTypes errs
  TRec tMap -> case sequence resMap of
    Right resMap' -> Right $ FFIRecord <$>
      recordMapAccum (\ps (ps', ft) -> (ps' ++ ps, ft)) [] resMap'
    Left _ -> Left $ FFITypeError t $
      FFIBadComponentTypes $ lefts $ displayElements resMap
    where resMap = fmap toFFIType tMap
  _ -> Left $ FFITypeError t FFIBadType

toFFIBasicType :: Type -> Maybe (Either FFITypeError FFIBasicType)
toFFIBasicType t = case t of
  TCon (TC TCSeq) [TCon (TC (TCNum n)) [], TCon (TC TCBit) []]
    | n <= 8 -> word FFIWord8
    | n <= 16 -> word FFIWord16
    | n <= 32 -> word FFIWord32
    | n <= 64 -> word FFIWord64
    | otherwise -> Just $ Left $ FFITypeError t FFIBadWordSize
    where word = Just . Right . FFIWord n
  TCon (TC TCFloat) [TCon (TC (TCNum e)) [], TCon (TC (TCNum p)) []]
    | e == 8, p == 24 -> float FFIFloat32
    | e == 11, p == 53 -> float FFIFloat64
    | otherwise -> Just $ Left $ FFITypeError t FFIBadFloatSize
    where float = Just . Right . FFIFloat e p
  _ -> Nothing

fin :: Type -> Prop
fin t = TCon (PC PFin) [t]
