{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE PatternGuards #-}

-- This module makes it so no binds with different sorts have the same name.

module Language.Fixpoint.Solver.UniqifyBinds (renameAll) where

import           Language.Fixpoint.Types
import           Language.Fixpoint.Solver.Sanitize (dropDeadSubsts)
import           Language.Fixpoint.Misc          (fst3, mlookup)

import qualified Data.HashMap.Strict as M
import qualified Data.HashSet        as S
import qualified Data.List           as L
import           Data.Foldable       (foldl')
import           Data.Maybe          (catMaybes, mapMaybe, fromJust, isJust)
import           Data.Hashable       (Hashable)
import           GHC.Generics        (Generic)
import           Control.Arrow       (second)
import           Control.DeepSeq     (NFData, ($!!))
-- import Debug.Trace (trace)

--------------------------------------------------------------------------------
renameAll    :: SInfo a -> SInfo a
--------------------------------------------------------------------------------
renameAll fi2 = fi6
  where
    fi6       = {- SCC "dropDead"    #-} dropDeadSubsts  fi5
    fi5       = {- SCC "dropUnused"  #-} dropUnusedBinds fi4
    fi4       = {- SCC "renameBinds" #-} renameBinds fi3 $!! rnm
    fi3       = {- SCC "renameVars"  #-} renameVars fi2 rnm $!! idm
    rnm       = {- SCC "mkRenameMap" #-} mkRenameMap $!! bs fi2
    idm       = {- SCC "mkIdMap"     #-} mkIdMap fi2


--------------------------------------------------------------------------------
-- | `dropUnusedBinds` replaces the refinements of "unused" binders with "true".
--   see tests/pos/unused.fq for an example of why this phase is needed.
--------------------------------------------------------------------------------
dropUnusedBinds :: SInfo a -> SInfo a
dropUnusedBinds fi = fi {bs = filterBindEnv isUsed (bs fi)}-- { bs = mapBindEnv tx (bs fi) }
  where
    -- _tx i (x, r)
    -- | isUsed i    = (x, r)
    -- | otherwise   = (x, top r)
    isUsed i _x r  = {- tracepp (unwords ["isUsed", show i, showpp _x]) $ -} memberIBindEnv i usedBinds || isTauto r
    usedBinds      = L.foldl' unionIBindEnv emptyIBindEnv (cEnvs ++ wEnvs)
    wEnvs          = wenv <$> M.elems (ws fi)
    cEnvs          = senv <$> M.elems (cm fi)

data Ref
  = RB !BindId    -- ^ Bind identifier
  | RI !Integer   -- ^ Constraint identifier?
    deriving (Eq, Generic)

instance NFData   Ref
instance Hashable Ref

-- | An `IdMap` stores for each constraint and BindId the
--   set of other BindIds that it references, i.e. those
--   where it needs to know when their names gets changed
type IdMap = M.HashMap Ref (S.HashSet BindId)

-- | A `RenameMap` maps an old name and sort to new name,
--   represented by a hashmap containing association lists.
--   `Nothing` as new name means the name is the same as the old.
type RenameMap = M.HashMap Symbol [(Sort, Maybe Symbol)]

--------------------------------------------------------------------------------
mkIdMap :: SInfo a -> IdMap
--------------------------------------------------------------------------------
mkIdMap fi = M.foldlWithKey' (updateIdMap $ bs fi) M.empty $ cm fi

updateIdMap :: BindEnv -> IdMap -> Integer -> SimpC a -> IdMap
updateIdMap be m scId s = M.insertWith S.union (RI scId) refSet m'
  where
    ids                 = elemsIBindEnv (senv s)
    nameMap             = M.fromList [(fst $ lookupBindEnv i be, i) | i <- ids]
    m'                  = foldl' (insertIdIdLinks be nameMap) m ids
    symSet              = S.fromList $ syms $ crhs s
    refSet              = namesToIds symSet nameMap

insertIdIdLinks :: BindEnv -> M.HashMap Symbol BindId -> IdMap -> BindId -> IdMap
insertIdIdLinks be nameMap m i = M.insertWith S.union (RB i) refSet m
  where
    sr     = snd $ lookupBindEnv i be
    symSet = reftFreeVars $ sr_reft sr
    refSet = namesToIds symSet nameMap

namesToIds :: S.HashSet Symbol -> M.HashMap Symbol BindId -> S.HashSet BindId
namesToIds xs m = S.fromList $ catMaybes [M.lookup x m | x <- S.toList xs] --TODO why any Nothings?

--------------------------------------------------------------------------------
mkRenameMap :: BindEnv -> RenameMap
--------------------------------------------------------------------------------
mkRenameMap be = foldl' (addId be) M.empty ids
  where
    ids = fst3 <$> bindEnvToList be

addId :: BindEnv -> RenameMap -> BindId -> RenameMap
addId be m i
  | M.member sym m = addDupId m sym t i
  | otherwise      = M.insert sym [(t, Nothing)] m
  where
    (sym, t)       = second sr_sort $ lookupBindEnv i be

addDupId :: RenameMap -> Symbol -> Sort -> BindId -> RenameMap
addDupId m sym t i
  | isJust $ L.lookup t mapping = m
  | otherwise                   = M.insert sym ((t, Just $ renameSymbol sym i) : mapping) m
  where
    mapping = fromJust $ M.lookup sym m

--------------------------------------------------------------------------------
-- | `renameVars` seems to do the actual work of renaming all the binders
--   to use their sort-specific names.
--------------------------------------------------------------------------------
renameVars :: SInfo a -> RenameMap -> IdMap -> SInfo a
--------------------------------------------------------------------------------
renameVars fi rnMap idMap = M.foldlWithKey' (updateRef rnMap) fi idMap

updateRef :: RenameMap -> SInfo a -> Ref -> S.HashSet BindId -> SInfo a
updateRef rnMap fi rf bset = applySub (mkSubst subs) fi rf
  where
    symTList = [second sr_sort $ lookupBindEnv i $ bs fi | i <- S.toList bset]
    subs     = mapMaybe (mkSubUsing rnMap) symTList

mkSubUsing :: RenameMap -> (Symbol, Sort) -> Maybe (Symbol, Expr)
mkSubUsing m (sym, t) = do
  newName <- fromJust $ L.lookup t $ mlookup m sym
  return (sym, eVar newName)

applySub :: Subst -> SInfo a -> Ref -> SInfo a
applySub sub fi (RB i) = fi { bs = adjustBindEnv go i (bs fi) }
  where
    go (sym, sr)       = (sym, subst sub sr)

applySub sub fi (RI i) = fi { cm = M.adjust go i (cm fi) }
  where
    go c               = c { _crhs = subst sub (_crhs c) }

--------------------------------------------------------------------------------
renameBinds :: SInfo a -> RenameMap -> SInfo a
--------------------------------------------------------------------------------
renameBinds fi m = fi { bs = bindEnvFromList $ renameBind m <$> beList }
  where
    beList       = bindEnvToList $ bs fi

renameBind :: RenameMap -> (BindId, Symbol, SortedReft) -> (BindId, Symbol, SortedReft)
renameBind m (i, sym, sr)
  | Just newSym <- mnewSym = (i, newSym, sr)
  | otherwise              = (i, sym,    sr)
  where
    t                      = sr_sort sr
    mnewSym                = fromJust $ L.lookup t $ mlookup m sym
