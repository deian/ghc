module Vectorise.Monad.InstEnv 
  ( lookupInst
  , lookupFamInst
  ) 
where

import Vectorise.Monad.Global
import Vectorise.Monad.Base
import Vectorise.Env

import DynFlags
import FamInstEnv
import InstEnv
import Class
import Type
import TyCon
import Outputable
import Util


#include "HsVersions.h"


-- Look up the dfun of a class instance.
--
-- The match must be unique —i.e., match exactly one instance— but the 
-- type arguments used for matching may be more specific than those of 
-- the class instance declaration.  The found class instances must not have
-- any type variables in the instance context that do not appear in the
-- instances head (i.e., no flexi vars); for details for what this means,
-- see the docs at InstEnv.lookupInstEnv.
--
lookupInst :: Class -> [Type] -> VM (DFunId, [Type])
lookupInst cls tys
  = do { instEnv <- readGEnv global_inst_env
       ; case lookupUniqueInstEnv instEnv cls tys of
           Right (inst, inst_tys) -> return (instanceDFunId inst, inst_tys)
           Left  err              ->
               do dflags <- getDynFlags
                  cantVectorise dflags "Vectorise.Monad.InstEnv.lookupInst:" err
       }

-- Look up a family instance.
--
-- The match must be unique - ie, match exactly one instance - but the 
-- type arguments used for matching may be more specific than those of 
-- the family instance declaration.
--
-- Return the family instance and its type instance.  For example, if we have
--
--  lookupFamInst 'T' '[Int]' yields (':R42T', 'Int')
--
-- then we have a coercion (ie, type instance of family instance coercion)
--
--  :Co:R42T Int :: T [Int] ~ :R42T Int
--
-- which implies that :R42T was declared as 'data instance T [a]'.
--
lookupFamInst :: TyCon -> [Type] -> VM (FamInst, [Type])
lookupFamInst tycon tys
  = ASSERT( isFamilyTyCon tycon )
    do { instEnv <- readGEnv global_fam_inst_env
       ; case lookupFamInstEnv instEnv tycon tys of
           [(fam_inst, rep_tys)] -> return ( fam_inst, rep_tys)
           _other                -> 
             do dflags <- getDynFlags
                cantVectorise dflags "VectMonad.lookupFamInst: not found: "
                           (ppr $ mkTyConApp tycon tys)
       }
