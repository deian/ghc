
% (c) The University of Glasgow 2006
% (c) The GRASP Project, Glasgow University, 1992-2002
%

Various types used during typechecking, please see TcRnMonad as well for
operations on these types. You probably want to import it, instead of this
module.

All the monads exported here are built on top of the same IOEnv monad. The
monad functions like a Reader monad in the way it passes the environment
around. This is done to allow the environment to be manipulated in a stack
like fashion when entering expressions... ect.

For state that is global and should be returned at the end (e.g not part
of the stack mechanism), you should use an TcRef (= IORef) to store them.

\begin{code}
module TcRnTypes(
        TcRnIf, TcRn, TcM, RnM, IfM, IfL, IfG, -- The monad is opaque outside this module
        TcRef,

        -- The environment types
        Env(..),
        TcGblEnv(..), TcLclEnv(..),
        IfGblEnv(..), IfLclEnv(..),

        -- Ranamer types
        ErrCtxt, RecFieldEnv(..),
        ImportAvails(..), emptyImportAvails, plusImportAvails,
        WhereFrom(..), mkModDeps,

        -- Typechecker types
        TcTypeEnv, TcIdBinder(..), TcTyThing(..), PromotionErr(..),
        pprTcTyThingCategory, pprPECategory,

        -- Template Haskell
        ThStage(..), topStage, topAnnStage, topSpliceStage,
        ThLevel, impLevel, outerLevel, thLevel,

        -- Arrows
        ArrowCtxt(NoArrowCtxt), newArrowScope, escapeArrowScope,

        -- Canonical constraints
        Xi, Ct(..), Cts, emptyCts, andCts, andManyCts, dropDerivedWC,
        singleCt, extendCts, isEmptyCts, isCTyEqCan, isCFunEqCan,
        isCDictCan_Maybe, isCFunEqCan_Maybe,
        isCIrredEvCan, isCNonCanonical, isWantedCt, isDerivedCt,
        isGivenCt, isHoleCt,
        ctEvidence,
        SubGoalDepth, mkNonCanonical, mkNonCanonicalCt,
        ctPred, ctEvPred, ctEvTerm, ctEvId,

        WantedConstraints(..), insolubleWC, emptyWC, isEmptyWC,
        andWC, unionsWC, addFlats, addImplics, mkFlatWC, addInsols,

        Implication(..),
        CtLoc(..), ctLocSpan, ctLocEnv, ctLocOrigin,
        ctLocDepth, bumpCtLocDepth,
        setCtLocOrigin, setCtLocEnv,
        CtOrigin(..),
        pushErrCtxt, pushErrCtxtSameOrigin,

        SkolemInfo(..),

        CtEvidence(..),
        mkGivenLoc,
        isWanted, isGiven,
        isDerived, canSolve, canRewrite,
        CtFlavour(..), ctEvFlavour, ctFlavour,

        -- Pretty printing
        pprEvVarTheta, pprWantedsWithLocs,
        pprEvVars, pprEvVarWithType,
        pprArising, pprArisingAt,

        -- Misc other types
        TcId, TcIdSet, TcTyVarBind(..), TcTyVarBinds

  ) where

#include "HsVersions.h"

import HsSyn
import HscTypes
import TcEvidence
import Type
import Class    ( Class )
import TyCon    ( TyCon )
import DataCon  ( DataCon, dataConUserType )
import TcType
import Annotations
import InstEnv
import FamInstEnv
import IOEnv
import RdrName
import Name
import NameEnv
import NameSet
import Avail
import Var
import VarEnv
import Module
import SrcLoc
import VarSet
import ErrUtils
import UniqFM
import UniqSupply
import BasicTypes
import Bag
import DynFlags
import Outputable
import ListSetOps
import FastString

import Data.Set (Set)
\end{code}


%************************************************************************
%*                                                                      *
               Standard monad definition for TcRn
    All the combinators for the monad can be found in TcRnMonad
%*                                                                      *
%************************************************************************

The monad itself has to be defined here, because it is mentioned by ErrCtxt

\begin{code}
type TcRef a     = IORef a
type TcId        = Id
type TcIdSet     = IdSet


type TcRnIf a b c = IOEnv (Env a b) c
type IfM lcl a  = TcRnIf IfGblEnv lcl a         -- Iface stuff

type IfG a  = IfM () a                          -- Top level
type IfL a  = IfM IfLclEnv a                    -- Nested
type TcRn a = TcRnIf TcGblEnv TcLclEnv a
type RnM  a = TcRn a            -- Historical
type TcM  a = TcRn a            -- Historical
\end{code}

Representation of type bindings to uninstantiated meta variables used during
constraint solving.

\begin{code}
data TcTyVarBind = TcTyVarBind TcTyVar TcType

type TcTyVarBinds = Bag TcTyVarBind

instance Outputable TcTyVarBind where
  ppr (TcTyVarBind tv ty) = ppr tv <+> text ":=" <+> ppr ty
\end{code}


%************************************************************************
%*                                                                      *
                The main environment types
%*                                                                      *
%************************************************************************

\begin{code}
-- We 'stack' these envs through the Reader like monad infastructure
-- as we move into an expression (although the change is focused in
-- the lcl type).
data Env gbl lcl
  = Env {
        env_top  :: HscEnv,  -- Top-level stuff that never changes
                             -- Includes all info about imported things

        env_us   :: {-# UNPACK #-} !(IORef UniqSupply),
                             -- Unique supply for local varibles

        env_gbl  :: gbl,     -- Info about things defined at the top level
                             -- of the module being compiled

        env_lcl  :: lcl      -- Nested stuff; changes as we go into
    }

instance ContainsDynFlags (Env gbl lcl) where
    extractDynFlags env = hsc_dflags (env_top env)

instance ContainsModule gbl => ContainsModule (Env gbl lcl) where
    extractModule env = extractModule (env_gbl env)

-- TcGblEnv describes the top-level of the module at the
-- point at which the typechecker is finished work.
-- It is this structure that is handed on to the desugarer
-- For state that needs to be updated during the typechecking
-- phase and returned at end, use a TcRef (= IORef).

data TcGblEnv
  = TcGblEnv {
        tcg_mod     :: Module,         -- ^ Module being compiled
        tcg_src     :: HscSource,
          -- ^ What kind of module (regular Haskell, hs-boot, ext-core)

        tcg_rdr_env :: GlobalRdrEnv,   -- ^ Top level envt; used during renaming
        tcg_default :: Maybe [Type],
          -- ^ Types used for defaulting. @Nothing@ => no @default@ decl

        tcg_fix_env   :: FixityEnv,     -- ^ Just for things in this module
        tcg_field_env :: RecFieldEnv,   -- ^ Just for things in this module

        tcg_type_env :: TypeEnv,
          -- ^ Global type env for the module we are compiling now.  All
          -- TyCons and Classes (for this module) end up in here right away,
          -- along with their derived constructors, selectors.
          --
          -- (Ids defined in this module start in the local envt, though they
          --  move to the global envt during zonking)

        tcg_type_env_var :: TcRef TypeEnv,
                -- Used only to initialise the interface-file
                -- typechecker in initIfaceTcRn, so that it can see stuff
                -- bound in this module when dealing with hi-boot recursions
                -- Updated at intervals (e.g. after dealing with types and classes)

        tcg_inst_env     :: InstEnv,
          -- ^ Instance envt for all /home-package/ modules;
          -- Includes the dfuns in tcg_insts
        tcg_fam_inst_env :: FamInstEnv, -- ^ Ditto for family instances

                -- Now a bunch of things about this module that are simply
                -- accumulated, but never consulted until the end.
                -- Nevertheless, it's convenient to accumulate them along
                -- with the rest of the info from this module.
        tcg_exports :: [AvailInfo],     -- ^ What is exported
        tcg_imports :: ImportAvails,
          -- ^ Information about what was imported from where, including
          -- things bound in this module. Also store Safe Haskell info
          -- here about transative trusted packaage requirements.

        tcg_dus :: DefUses,
          -- ^ What is defined in this module and what is used.
          -- The latter is used to generate
          --
          --  (a) version tracking; no need to recompile if these things have
          --      not changed version stamp
          --
          --  (b) unused-import info

        tcg_keep :: TcRef NameSet,
          -- ^ Locally-defined top-level names to keep alive.
          --
          -- "Keep alive" means give them an Exported flag, so that the
          -- simplifier does not discard them as dead code, and so that they
          -- are exposed in the interface file (but not to export to the
          -- user).
          --
          -- Some things, like dict-fun Ids and default-method Ids are "born"
          -- with the Exported flag on, for exactly the above reason, but some
          -- we only discover as we go.  Specifically:
          --
          --   * The to/from functions for generic data types
          --
          --   * Top-level variables appearing free in the RHS of an orphan
          --     rule
          --
          --   * Top-level variables appearing free in a TH bracket

        tcg_th_used :: TcRef Bool,
          -- ^ @True@ <=> Template Haskell syntax used.
          --
          -- We need this so that we can generate a dependency on the
          -- Template Haskell package, becuase the desugarer is going
          -- to emit loads of references to TH symbols.  The reference
          -- is implicit rather than explicit, so we have to zap a
          -- mutable variable.

        tcg_th_splice_used :: TcRef Bool,
          -- ^ @True@ <=> A Template Haskell splice was used.
          --
          -- Splices disable recompilation avoidance (see #481)

        tcg_dfun_n  :: TcRef OccSet,
          -- ^ Allows us to choose unique DFun names.

        -- The next fields accumulate the payload of the module
        -- The binds, rules and foreign-decl fiels are collected
        -- initially in un-zonked form and are finally zonked in tcRnSrcDecls

        tcg_rn_exports :: Maybe [Located (IE Name)],
        tcg_rn_imports :: [LImportDecl Name],
                -- Keep the renamed imports regardless.  They are not
                -- voluminous and are needed if you want to report unused imports

        tcg_used_rdrnames :: TcRef (Set RdrName),
                -- The set of used *imported* (not locally-defined) RdrNames
                -- Used only to report unused import declarations

        tcg_rn_decls :: Maybe (HsGroup Name),
          -- ^ Renamed decls, maybe.  @Nothing@ <=> Don't retain renamed
          -- decls.

        tcg_dependent_files :: TcRef [FilePath], -- ^ dependencies from addDependentFile

        tcg_ev_binds  :: Bag EvBind,        -- Top-level evidence bindings
        tcg_binds     :: LHsBinds Id,       -- Value bindings in this module
        tcg_sigs      :: NameSet,           -- ...Top-level names that *lack* a signature
        tcg_imp_specs :: [LTcSpecPrag],     -- ...SPECIALISE prags for imported Ids
        tcg_warns     :: Warnings,          -- ...Warnings and deprecations
        tcg_anns      :: [Annotation],      -- ...Annotations
        tcg_tcs       :: [TyCon],           -- ...TyCons and Classes
        tcg_insts     :: [ClsInst],         -- ...Instances
        tcg_fam_insts :: [FamInst],         -- ...Family instances
        tcg_rules     :: [LRuleDecl Id],    -- ...Rules
        tcg_fords     :: [LForeignDecl Id], -- ...Foreign import & exports
        tcg_vects     :: [LVectDecl Id],    -- ...Vectorisation declarations

        tcg_doc_hdr   :: Maybe LHsDocString, -- ^ Maybe Haddock header docs
        tcg_hpc       :: AnyHpcUsage,        -- ^ @True@ if any part of the
                                             --  prog uses hpc instrumentation.

        tcg_main      :: Maybe Name,         -- ^ The Name of the main
                                             -- function, if this module is
                                             -- the main module.
        tcg_safeInfer :: TcRef Bool          -- Has the typechecker
                                             -- inferred this module
                                             -- as -XSafe (Safe Haskell)
    }

instance ContainsModule TcGblEnv where
    extractModule env = tcg_mod env

data RecFieldEnv
  = RecFields (NameEnv [Name])  -- Maps a constructor name *in this module*
                                -- to the fields for that constructor
              NameSet           -- Set of all fields declared *in this module*;
                                -- used to suppress name-shadowing complaints
                                -- when using record wild cards
                                -- E.g.  let fld = e in C {..}
        -- This is used when dealing with ".." notation in record
        -- construction and pattern matching.
        -- The FieldEnv deals *only* with constructors defined in *this*
        -- module.  For imported modules, we get the same info from the
        -- TypeEnv
\end{code}

%************************************************************************
%*                                                                      *
                The interface environments
              Used when dealing with IfaceDecls
%*                                                                      *
%************************************************************************

\begin{code}
data IfGblEnv
  = IfGblEnv {
        -- The type environment for the module being compiled,
        -- in case the interface refers back to it via a reference that
        -- was originally a hi-boot file.
        -- We need the module name so we can test when it's appropriate
        -- to look in this env.
        if_rec_types :: Maybe (Module, IfG TypeEnv)
                -- Allows a read effect, so it can be in a mutable
                -- variable; c.f. handling the external package type env
                -- Nothing => interactive stuff, no loops possible
    }

data IfLclEnv
  = IfLclEnv {
        -- The module for the current IfaceDecl
        -- So if we see   f = \x -> x
        -- it means M.f = \x -> x, where M is the if_mod
        if_mod :: Module,

        -- The field is used only for error reporting
        -- if (say) there's a Lint error in it
        if_loc :: SDoc,
                -- Where the interface came from:
                --      .hi file, or GHCi state, or ext core
                -- plus which bit is currently being examined

        if_tv_env  :: UniqFM TyVar,     -- Nested tyvar bindings
                                        -- (and coercions)
        if_id_env  :: UniqFM Id         -- Nested id binding
    }
\end{code}


%************************************************************************
%*                                                                      *
                The local typechecker environment
%*                                                                      *
%************************************************************************

The Global-Env/Local-Env story
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
During type checking, we keep in the tcg_type_env
        * All types and classes
        * All Ids derived from types and classes (constructors, selectors)

At the end of type checking, we zonk the local bindings,
and as we do so we add to the tcg_type_env
        * Locally defined top-level Ids

Why?  Because they are now Ids not TcIds.  This final GlobalEnv is
        a) fed back (via the knot) to typechecking the
           unfoldings of interface signatures
        b) used in the ModDetails of this module

\begin{code}
data TcLclEnv           -- Changes as we move inside an expression
                        -- Discarded after typecheck/rename; not passed on to desugarer
  = TcLclEnv {
        tcl_loc        :: SrcSpan,         -- Source span
        tcl_ctxt       :: [ErrCtxt],       -- Error context, innermost on top
        tcl_untch      :: Untouchables,    -- Birthplace for new unification variables
        tcl_th_ctxt    :: ThStage,         -- Template Haskell context
        tcl_arrow_ctxt :: ArrowCtxt,       -- Arrow-notation context

        tcl_rdr :: LocalRdrEnv,         -- Local name envt
                -- Maintained during renaming, of course, but also during
                -- type checking, solely so that when renaming a Template-Haskell
                -- splice we have the right environment for the renamer.
                --
                --   Does *not* include global name envt; may shadow it
                --   Includes both ordinary variables and type variables;
                --   they are kept distinct because tyvar have a different
                --   occurrence contructor (Name.TvOcc)
                -- We still need the unsullied global name env so that
                --   we can look up record field names

        tcl_env  :: TcTypeEnv,    -- The local type environment:
                                  -- Ids and TyVars defined in this module

        tcl_bndrs :: [TcIdBinder],   -- Stack of locally-bound Ids, innermost on top
                                     -- Used only for error reporting

        tcl_tidy :: TidyEnv,      -- Used for tidying types; contains all
                                  -- in-scope type variables (but not term variables)

        tcl_tyvars :: TcRef TcTyVarSet, -- The "global tyvars"
                        -- Namely, the in-scope TyVars bound in tcl_env,
                        -- plus the tyvars mentioned in the types of Ids bound
                        -- in tcl_lenv.
                        -- Why mutable? see notes with tcGetGlobalTyVars

        tcl_lie  :: TcRef WantedConstraints,    -- Place to accumulate type constraints
        tcl_errs :: TcRef Messages              -- Place to accumulate errors
    }

type TcTypeEnv = NameEnv TcTyThing
data TcIdBinder = TcIdBndr TcId TopLevelFlag

{- Note [Given Insts]
   ~~~~~~~~~~~~~~~~~~
Because of GADTs, we have to pass inwards the Insts provided by type signatures
and existential contexts. Consider
        data T a where { T1 :: b -> b -> T [b] }
        f :: Eq a => T a -> Bool
        f (T1 x y) = [x]==[y]

The constructor T1 binds an existential variable 'b', and we need Eq [b].
Well, we have it, because Eq a refines to Eq [b], but we can only spot that if we
pass it inwards.

-}

---------------------------
-- Template Haskell stages and levels
---------------------------

data ThStage    -- See Note [Template Haskell state diagram] in TcSplice
  = Splice      -- Top-level splicing
                -- This code will be run *at compile time*;
                --   the result replaces the splice
                -- Binding level = 0

  | Comp        -- Ordinary Haskell code
                -- Binding level = 1

  | Brack                       -- Inside brackets
      ThStage                   --   Binding level = level(stage) + 1
      (TcRef [PendingSplice])   --   Accumulate pending splices here
      (TcRef WantedConstraints) --     and type constraints here

topStage, topAnnStage, topSpliceStage :: ThStage
topStage       = Comp
topAnnStage    = Splice
topSpliceStage = Splice

instance Outputable ThStage where
   ppr Splice        = text "Splice"
   ppr Comp          = text "Comp"
   ppr (Brack s _ _) = text "Brack" <> parens (ppr s)

type ThLevel = Int
        -- See Note [Template Haskell levels] in TcSplice
        -- Incremented when going inside a bracket,
        -- decremented when going inside a splice
        -- NB: ThLevel is one greater than the 'n' in Fig 2 of the
        --     original "Template meta-programming for Haskell" paper

impLevel, outerLevel :: ThLevel
impLevel = 0    -- Imported things; they can be used inside a top level splice
outerLevel = 1  -- Things defined outside brackets
-- NB: Things at level 0 are not *necessarily* imported.
--      eg  $( \b -> ... )   here b is bound at level 0
--
-- For example:
--      f = ...
--      g1 = $(map ...)         is OK
--      g2 = $(f ...)           is not OK; because we havn't compiled f yet

thLevel :: ThStage -> ThLevel
thLevel Splice        = 0
thLevel Comp          = 1
thLevel (Brack s _ _) = thLevel s + 1

---------------------------
-- Arrow-notation context
---------------------------

{- Note [Escaping the arrow scope]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In arrow notation, a variable bound by a proc (or enclosed let/kappa)
is not in scope to the left of an arrow tail (-<) or the head of (|..|).
For example

        proc x -> (e1 -< e2)

Here, x is not in scope in e1, but it is in scope in e2.  This can get
a bit complicated:

        let x = 3 in
        proc y -> (proc z -> e1) -< e2

Here, x and z are in scope in e1, but y is not.

We implement this by
recording the environment when passing a proc (using newArrowScope),
and returning to that (using escapeArrowScope) on the left of -< and the
head of (|..|).

All this can be dealt with by the *renamer*; by the time we get to
the *type checker* we have sorted out the scopes
-}

data ArrowCtxt
  = NoArrowCtxt
  | ArrowCtxt (Env TcGblEnv TcLclEnv)

-- Record the current environment (outside a proc)
newArrowScope :: TcM a -> TcM a
newArrowScope
  = updEnv $ \env ->
        env { env_lcl = (env_lcl env) { tcl_arrow_ctxt = ArrowCtxt env } }

-- Return to the stored environment (from the enclosing proc)
escapeArrowScope :: TcM a -> TcM a
escapeArrowScope
  = updEnv $ \ env -> case tcl_arrow_ctxt (env_lcl env) of
        NoArrowCtxt -> env
        ArrowCtxt env' -> env'

---------------------------
-- TcTyThing
---------------------------

data TcTyThing
  = AGlobal TyThing             -- Used only in the return type of a lookup

  | ATcId   {           -- Ids defined in this module; may not be fully zonked
        tct_id     :: TcId,
        tct_closed :: TopLevelFlag,   -- See Note [Bindings with closed types]
        tct_level  :: ThLevel }

  | ATyVar  Name TcTyVar        -- The type variable to which the lexically scoped type
                                -- variable is bound. We only need the Name
                                -- for error-message purposes; it is the corresponding
                                -- Name in the domain of the envt

  | AThing  TcKind   -- Used temporarily, during kind checking, for the
                     -- tycons and clases in this recursive group
                     -- Can be a mono-kind or a poly-kind; in TcTyClsDcls see
                     -- Note [Type checking recursive type and class declarations]

  | APromotionErr PromotionErr

data PromotionErr
  = TyConPE          -- TyCon used in a kind before we are ready
                     --     data T :: T -> * where ...
  | ClassPE          -- Ditto Class

  | FamDataConPE     -- Data constructor for a data family
                     -- See Note [AFamDataCon: not promoting data family constructors] in TcRnDriver

  | RecDataConPE     -- Data constructor in a reuursive loop
                     -- See Note [ARecDataCon: recusion and promoting data constructors] in TcTyClsDecls

instance Outputable TcTyThing where     -- Debugging only
   ppr (AGlobal g)      = pprTyThing g
   ppr elt@(ATcId {})   = text "Identifier" <>
                          brackets (ppr (tct_id elt) <> dcolon
                                 <> ppr (varType (tct_id elt)) <> comma
                                 <+> ppr (tct_closed elt) <> comma
                                 <+> ppr (tct_level elt))
   ppr (ATyVar n tv)    = text "Type variable" <+> quotes (ppr n) <+> equals <+> ppr tv
   ppr (AThing k)       = text "AThing" <+> ppr k
   ppr (APromotionErr err) = text "APromotionErr" <+> ppr err

instance Outputable PromotionErr where
  ppr ClassPE      = text "ClassPE"
  ppr TyConPE      = text "TyConPE"
  ppr FamDataConPE = text "FamDataConPE"
  ppr RecDataConPE = text "RecDataConPE"

pprTcTyThingCategory :: TcTyThing -> SDoc
pprTcTyThingCategory (AGlobal thing)    = pprTyThingCategory thing
pprTcTyThingCategory (ATyVar {})        = ptext (sLit "Type variable")
pprTcTyThingCategory (ATcId {})         = ptext (sLit "Local identifier")
pprTcTyThingCategory (AThing {})        = ptext (sLit "Kinded thing")
pprTcTyThingCategory (APromotionErr pe) = pprPECategory pe

pprPECategory :: PromotionErr -> SDoc
pprPECategory ClassPE      = ptext (sLit "Class")
pprPECategory TyConPE      = ptext (sLit "Type constructor")
pprPECategory FamDataConPE = ptext (sLit "Data constructor")
pprPECategory RecDataConPE = ptext (sLit "Data constructor")
\end{code}


Note [Bindings with closed types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider

  f x = let g ys = map not ys
        in ...

Can we generalise 'g' under the OutsideIn algorithm?  Yes,
because all g's free variables are top-level; that is they themselves
have no free type variables, and it is the type variables in the
environment that makes things tricky for OutsideIn generalisation.

Definition:

   A variable is "closed", and has tct_closed set to TopLevel,
      iff
   a) all its free variables are imported, or are themselves closed
   b) generalisation is not restricted by the monomorphism restriction

Under OutsideIn we are free to generalise a closed let-binding.
This is an extension compared to the JFP paper on OutsideIn, which
used "top-level" as a proxy for "closed".  (It's not a good proxy
anyway -- the MR can make a top-level binding with a free type
variable.)

Note that:
  * A top-level binding may not be closed, if it suffer from the MR

  * A nested binding may be closed (eg 'g' in the example we started with)
    Indeed, that's the point; whether a function is defined at top level
    or nested is orthogonal to the question of whether or not it is closed

  * A binding may be non-closed because it mentions a lexically scoped
    *type variable*  Eg
        f :: forall a. blah
        f x = let g y = ...(y::a)...


\begin{code}
type ErrCtxt = (Bool, TidyEnv -> TcM (TidyEnv, MsgDoc))
        -- Monadic so that we have a chance
        -- to deal with bound type variables just before error
        -- message construction

        -- Bool:  True <=> this is a landmark context; do not
        --                 discard it when trimming for display
\end{code}


%************************************************************************
%*                                                                      *
        Operations over ImportAvails
%*                                                                      *
%************************************************************************

\begin{code}
-- | 'ImportAvails' summarises what was imported from where, irrespective of
-- whether the imported things are actually used or not.  It is used:
--
--  * when processing the export list,
--
--  * when constructing usage info for the interface file,
--
--  * to identify the list of directly imported modules for initialisation
--    purposes and for optimised overlap checking of family instances,
--
--  * when figuring out what things are really unused
--
data ImportAvails
   = ImportAvails {
        imp_mods :: ImportedMods,
          --      = ModuleEnv [(ModuleName, Bool, SrcSpan, Bool)],
          -- ^ Domain is all directly-imported modules
          -- The 'ModuleName' is what the module was imported as, e.g. in
          -- @
          --     import Foo as Bar
          -- @
          -- it is @Bar@.
          --
          -- The 'Bool' means:
          --
          --  - @True@ => import was @import Foo ()@
          --
          --  - @False@ => import was some other form
          --
          -- Used
          --
          --   (a) to help construct the usage information in the interface
          --       file; if we import somethign we need to recompile if the
          --       export version changes
          --
          --   (b) to specify what child modules to initialise
          --
          -- We need a full ModuleEnv rather than a ModuleNameEnv here,
          -- because we might be importing modules of the same name from
          -- different packages. (currently not the case, but might be in the
          -- future).

        imp_dep_mods :: ModuleNameEnv (ModuleName, IsBootInterface),
          -- ^ Home-package modules needed by the module being compiled
          --
          -- It doesn't matter whether any of these dependencies
          -- are actually /used/ when compiling the module; they
          -- are listed if they are below it at all.  For
          -- example, suppose M imports A which imports X.  Then
          -- compiling M might not need to consult X.hi, but X
          -- is still listed in M's dependencies.

        imp_dep_pkgs :: [PackageId],
          -- ^ Packages needed by the module being compiled, whether directly,
          -- or via other modules in this package, or via modules imported
          -- from other packages.

        imp_trust_pkgs :: [PackageId],
          -- ^ This is strictly a subset of imp_dep_pkgs and records the
          -- packages the current module needs to trust for Safe Haskell
          -- compilation to succeed. A package is required to be trusted if
          -- we are dependent on a trustworthy module in that package.
          -- While perhaps making imp_dep_pkgs a tuple of (PackageId, Bool)
          -- where True for the bool indicates the package is required to be
          -- trusted is the more logical  design, doing so complicates a lot
          -- of code not concerned with Safe Haskell.
          -- See Note [RnNames . Tracking Trust Transitively]

        imp_trust_own_pkg :: Bool,
          -- ^ Do we require that our own package is trusted?
          -- This is to handle efficiently the case where a Safe module imports
          -- a Trustworthy module that resides in the same package as it.
          -- See Note [RnNames . Trust Own Package]

        imp_orphs :: [Module],
          -- ^ Orphan modules below us in the import tree (and maybe including
          -- us for imported modules)

        imp_finsts :: [Module]
          -- ^ Family instance modules below us in the import tree (and maybe
          -- including us for imported modules)
      }

mkModDeps :: [(ModuleName, IsBootInterface)]
          -> ModuleNameEnv (ModuleName, IsBootInterface)
mkModDeps deps = foldl add emptyUFM deps
               where
                 add env elt@(m,_) = addToUFM env m elt

emptyImportAvails :: ImportAvails
emptyImportAvails = ImportAvails { imp_mods          = emptyModuleEnv,
                                   imp_dep_mods      = emptyUFM,
                                   imp_dep_pkgs      = [],
                                   imp_trust_pkgs    = [],
                                   imp_trust_own_pkg = False,
                                   imp_orphs         = [],
                                   imp_finsts        = [] }

-- | Union two ImportAvails
--
-- This function is a key part of Import handling, basically
-- for each import we create a seperate ImportAvails structure
-- and then union them all together with this function.
plusImportAvails ::  ImportAvails ->  ImportAvails ->  ImportAvails
plusImportAvails
  (ImportAvails { imp_mods = mods1,
                  imp_dep_mods = dmods1, imp_dep_pkgs = dpkgs1,
                  imp_trust_pkgs = tpkgs1, imp_trust_own_pkg = tself1,
                  imp_orphs = orphs1, imp_finsts = finsts1 })
  (ImportAvails { imp_mods = mods2,
                  imp_dep_mods = dmods2, imp_dep_pkgs = dpkgs2,
                  imp_trust_pkgs = tpkgs2, imp_trust_own_pkg = tself2,
                  imp_orphs = orphs2, imp_finsts = finsts2 })
  = ImportAvails { imp_mods          = plusModuleEnv_C (++) mods1 mods2,
                   imp_dep_mods      = plusUFM_C plus_mod_dep dmods1 dmods2,
                   imp_dep_pkgs      = dpkgs1 `unionLists` dpkgs2,
                   imp_trust_pkgs    = tpkgs1 `unionLists` tpkgs2,
                   imp_trust_own_pkg = tself1 || tself2,
                   imp_orphs         = orphs1 `unionLists` orphs2,
                   imp_finsts        = finsts1 `unionLists` finsts2 }
  where
    plus_mod_dep (m1, boot1) (m2, boot2)
        = WARN( not (m1 == m2), (ppr m1 <+> ppr m2) $$ (ppr boot1 <+> ppr boot2) )
                -- Check mod-names match
          (m1, boot1 && boot2) -- If either side can "see" a non-hi-boot interface, use that
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Where from}
%*                                                                      *
%************************************************************************

The @WhereFrom@ type controls where the renamer looks for an interface file

\begin{code}
data WhereFrom
  = ImportByUser IsBootInterface        -- Ordinary user import (perhaps {-# SOURCE #-})
  | ImportBySystem                      -- Non user import.

instance Outputable WhereFrom where
  ppr (ImportByUser is_boot) | is_boot     = ptext (sLit "{- SOURCE -}")
                             | otherwise   = empty
  ppr ImportBySystem                       = ptext (sLit "{- SYSTEM -}")
\end{code}

%************************************************************************
%*                                                                      *
%*                       Canonical constraints                          *
%*                                                                      *
%*   These are the constraints the low-level simplifier works with      *
%*                                                                      *
%************************************************************************


\begin{code}
-- The syntax of xi types:
-- xi ::= a | T xis | xis -> xis | ... | forall a. tau
-- Two important notes:
--      (i) No type families, unless we are under a ForAll
--      (ii) Note that xi types can contain unexpanded type synonyms;
--           however, the (transitive) expansions of those type synonyms
--           will not contain any type functions, unless we are under a ForAll.
-- We enforce the structure of Xi types when we flatten (TcCanonical)

type Xi = Type       -- In many comments, "xi" ranges over Xi

type Cts = Bag Ct

data Ct
  -- Atomic canonical constraints
  = CDictCan {  -- e.g.  Num xi
      cc_ev :: CtEvidence,   -- See Note [Ct/evidence invariant]
      cc_class  :: Class,
      cc_tyargs :: [Xi],

      cc_loc  :: CtLoc
    }

  | CIrredEvCan {  -- These stand for yet-unknown predicates
      cc_ev :: CtEvidence,   -- See Note [Ct/evidence invariant]
                   -- In CIrredEvCan, the ctev_pred of the evidence is flat
                   -- and hence it may only be of the form (tv xi1 xi2 ... xin)
                   -- Since, if it were a type constructor application, that'd make the
                   -- whole constraint a CDictCan, or CTyEqCan. And it can't be
                   -- a type family application either because it's a Xi type.
      cc_loc :: CtLoc
    }

  | CTyEqCan {  -- tv ~ xi      (recall xi means function free)
       -- Invariant:
       --   * tv not in tvs(xi)   (occurs check)
       --   * typeKind xi `compatKind` typeKind tv
       --       See Note [Spontaneous solving and kind compatibility]
       --   * We prefer unification variables on the left *JUST* for efficiency
      cc_ev :: CtEvidence,    -- See Note [Ct/evidence invariant]
      cc_tyvar  :: TcTyVar,
      cc_rhs    :: Xi,
      cc_loc    :: CtLoc
    }

  | CFunEqCan {  -- F xis ~ xi
                 -- Invariant: * isSynFamilyTyCon cc_fun
                 --            * typeKind (F xis) `compatKind` typeKind xi
      cc_ev     :: CtEvidence,  -- See Note [Ct/evidence invariant]
      cc_fun    :: TyCon,       -- A type function
      cc_tyargs :: [Xi],        -- Either under-saturated or exactly saturated
      cc_rhs    :: Xi,          --    *never* over-saturated (because if so
                                --    we should have decomposed)

      cc_loc  :: CtLoc

    }

  | CNonCanonical { -- See Note [NonCanonical Semantics]
      cc_ev  :: CtEvidence,
      cc_loc :: CtLoc
    }

  | CHoleCan {
      cc_ev  :: CtEvidence,
      cc_loc :: CtLoc
    }
\end{code}

Note [Ct/evidence invariant]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If  ct :: Ct, then extra fields of 'ct' cache precisely the ctev_pred field
of (cc_ev ct), and is fully rewritten wrt the substitution.   Eg for CDictCan,
   ctev_pred (cc_ev ct) = (cc_class ct) (cc_tyargs ct)
This holds by construction; look at the unique place where CDictCan is
built (in TcCanonical).

In contrast, the type of the evidence *term* (ccev_evtm or ctev_evar) in
the evidence may *not* be fully zonked; we are careful not to look at it
during constraint solving.  Seee Note [Evidence field of CtEvidence]

\begin{code}
mkNonCanonical :: CtLoc -> CtEvidence -> Ct
mkNonCanonical loc ev = CNonCanonical { cc_ev = ev, cc_loc = loc }

mkNonCanonicalCt :: Ct -> Ct
mkNonCanonicalCt ct = CNonCanonical { cc_ev = cc_ev ct, cc_loc = cc_loc ct }

ctEvidence :: Ct -> CtEvidence
ctEvidence = cc_ev

ctPred :: Ct -> PredType
-- See Note [Ct/evidence invariant]
ctPred ct = ctEvPred (cc_ev ct)

dropDerivedWC :: WantedConstraints -> WantedConstraints
dropDerivedWC wc@(WC { wc_flat = flats })
  = wc { wc_flat = filterBag isWantedCt flats }
    -- Don't filter the insolubles, because derived
    -- insolubles should stay so that we report them.
    -- The implications are (recursively) already filtered
\end{code}


%************************************************************************
%*                                                                      *
                    CtEvidence
         The "flavor" of a canonical constraint
%*                                                                      *
%************************************************************************

\begin{code}
isWantedCt :: Ct -> Bool
isWantedCt = isWanted . cc_ev

isGivenCt :: Ct -> Bool
isGivenCt = isGiven . cc_ev

isDerivedCt :: Ct -> Bool
isDerivedCt = isDerived . cc_ev

isCTyEqCan :: Ct -> Bool
isCTyEqCan (CTyEqCan {})  = True
isCTyEqCan (CFunEqCan {}) = False
isCTyEqCan _              = False

isCDictCan_Maybe :: Ct -> Maybe Class
isCDictCan_Maybe (CDictCan {cc_class = cls })  = Just cls
isCDictCan_Maybe _              = Nothing

isCIrredEvCan :: Ct -> Bool
isCIrredEvCan (CIrredEvCan {}) = True
isCIrredEvCan _                = False

isCFunEqCan_Maybe :: Ct -> Maybe TyCon
isCFunEqCan_Maybe (CFunEqCan { cc_fun = tc }) = Just tc
isCFunEqCan_Maybe _ = Nothing

isCFunEqCan :: Ct -> Bool
isCFunEqCan (CFunEqCan {}) = True
isCFunEqCan _ = False

isCNonCanonical :: Ct -> Bool
isCNonCanonical (CNonCanonical {}) = True
isCNonCanonical _ = False

isHoleCt:: Ct -> Bool
isHoleCt (CHoleCan {}) = True
isHoleCt _ = False

\end{code}

\begin{code}
instance Outputable Ct where
  ppr ct = ppr (cc_ev ct) <+> parens (text ct_sort)
         where ct_sort = case ct of
                           CTyEqCan {}      -> "CTyEqCan"
                           CFunEqCan {}     -> "CFunEqCan"
                           CNonCanonical {} -> "CNonCanonical"
                           CDictCan {}      -> "CDictCan"
                           CIrredEvCan {}   -> "CIrredEvCan"
                           CHoleCan {}      -> "CHoleCan"
\end{code}

\begin{code}
singleCt :: Ct -> Cts
singleCt = unitBag

andCts :: Cts -> Cts -> Cts
andCts = unionBags

extendCts :: Cts -> Ct -> Cts
extendCts = snocBag

andManyCts :: [Cts] -> Cts
andManyCts = unionManyBags

emptyCts :: Cts
emptyCts = emptyBag

isEmptyCts :: Cts -> Bool
isEmptyCts = isEmptyBag
\end{code}

%************************************************************************
%*                                                                      *
                Wanted constraints
     These are forced to be in TcRnTypes because
           TcLclEnv mentions WantedConstraints
           WantedConstraint mentions CtLoc
           CtLoc mentions ErrCtxt
           ErrCtxt mentions TcM
%*                                                                      *
v%************************************************************************

\begin{code}

data WantedConstraints
  = WC { wc_flat  :: Cts               -- Unsolved constraints, all wanted
       , wc_impl  :: Bag Implication
       , wc_insol :: Cts               -- Insoluble constraints, can be
                                       -- wanted, given, or derived
                                       -- See Note [Insoluble constraints]
    }

emptyWC :: WantedConstraints
emptyWC = WC { wc_flat = emptyBag, wc_impl = emptyBag, wc_insol = emptyBag }

mkFlatWC :: [Ct] -> WantedConstraints
mkFlatWC cts
  = WC { wc_flat = listToBag cts, wc_impl = emptyBag, wc_insol = emptyBag }

isEmptyWC :: WantedConstraints -> Bool
isEmptyWC (WC { wc_flat = f, wc_impl = i, wc_insol = n })
  = isEmptyBag f && isEmptyBag i && isEmptyBag n

insolubleWC :: WantedConstraints -> Bool
-- True if there are any insoluble constraints in the wanted bag
insolubleWC wc = not (isEmptyBag (wc_insol wc))
               || anyBag ic_insol (wc_impl wc)

andWC :: WantedConstraints -> WantedConstraints -> WantedConstraints
andWC (WC { wc_flat = f1, wc_impl = i1, wc_insol = n1 })
      (WC { wc_flat = f2, wc_impl = i2, wc_insol = n2 })
  = WC { wc_flat  = f1 `unionBags` f2
       , wc_impl  = i1 `unionBags` i2
       , wc_insol = n1 `unionBags` n2 }

unionsWC :: [WantedConstraints] -> WantedConstraints
unionsWC = foldr andWC emptyWC

addFlats :: WantedConstraints -> Bag Ct -> WantedConstraints
addFlats wc cts
  = wc { wc_flat = wc_flat wc `unionBags` cts }

addImplics :: WantedConstraints -> Bag Implication -> WantedConstraints
addImplics wc implic = wc { wc_impl = wc_impl wc `unionBags` implic }

addInsols :: WantedConstraints -> Bag Ct -> WantedConstraints
addInsols wc cts
  = wc { wc_insol = wc_insol wc `unionBags` cts }

instance Outputable WantedConstraints where
  ppr (WC {wc_flat = f, wc_impl = i, wc_insol = n})
   = ptext (sLit "WC") <+> braces (vcat
        [ if isEmptyBag f then empty else
          ptext (sLit "wc_flat =")  <+> pprBag ppr f
        , if isEmptyBag i then empty else
          ptext (sLit "wc_impl =")  <+> pprBag ppr i
        , if isEmptyBag n then empty else
          ptext (sLit "wc_insol =") <+> pprBag ppr n ])

pprBag :: (a -> SDoc) -> Bag a -> SDoc
pprBag pp b = foldrBag (($$) . pp) empty b
\end{code}


%************************************************************************
%*                                                                      *
                Implication constraints
%*                                                                      *
%************************************************************************

\begin{code}
data Implication
  = Implic {
      ic_untch :: Untouchables, -- Untouchables: unification variables
                                -- free in the environment

      ic_skols  :: [TcTyVar],    -- Introduced skolems
      ic_info  :: SkolemInfo,    -- See Note [Skolems in an implication]
                                 -- See Note [Shadowing in a constraint]

      ic_fsks  :: [TcTyVar],   -- Extra flatten-skolems introduced by the flattening
                               -- done by canonicalisation.

      ic_given  :: [EvVar],      -- Given evidence variables
                                 --   (order does not matter)

      ic_env   :: TcLclEnv,      -- Gives the source location and error context
                                 -- for the implicatdion, and hence for all the
                                 -- given evidence variables

      ic_wanted :: WantedConstraints,  -- The wanted
      ic_insol  :: Bool,               -- True iff insolubleWC ic_wanted is true

      ic_binds  :: EvBindsVar   -- Points to the place to fill in the
                                -- abstraction and bindings
    }

instance Outputable Implication where
  ppr (Implic { ic_untch = untch, ic_skols = skols, ic_fsks = fsks
              , ic_given = given
              , ic_wanted = wanted
              , ic_binds = binds, ic_info = info })
   = ptext (sLit "Implic") <+> braces
     (sep [ ptext (sLit "Untouchables =") <+> ppr untch
          , ptext (sLit "Skolems =") <+> ppr skols
          , ptext (sLit "Flatten-skolems =") <+> ppr fsks
          , ptext (sLit "Given =") <+> pprEvVars given
          , ptext (sLit "Wanted =") <+> ppr wanted
          , ptext (sLit "Binds =") <+> ppr binds
          , pprSkolInfo info ])
\end{code}

Note [Shadowing in a constraint]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We assume NO SHADOWING in a constraint.  Specifically
 * The unification variables are all implicitly quantified at top
   level, and are all unique
 * The skolem varibles bound in ic_skols are all freah when the
   implication is created.
So we can safely substitute. For example, if we have
   forall a.  a~Int => ...(forall b. ...a...)...
we can push the (a~Int) constraint inwards in the "givens" without
worrying that 'b' might clash.

Note [Skolems in an implication]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The skolems in an implication are not there to perform a skolem escape
check.  That happens because all the environment variables are in the
untouchables, and therefore cannot be unified with anything at all,
let alone the skolems.

Instead, ic_skols is used only when considering floating a constraint
outside the implication in TcSimplify.floatEqualities or
TcSimplify.approximateImplications

Note [Insoluble constraints]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Some of the errors that we get during canonicalization are best
reported when all constraints have been simplified as much as
possible. For instance, assume that during simplification the
following constraints arise:

 [Wanted]   F alpha ~  uf1
 [Wanted]   beta ~ uf1 beta

When canonicalizing the wanted (beta ~ uf1 beta), if we eagerly fail
we will simply see a message:
    'Can't construct the infinite type  beta ~ uf1 beta'
and the user has no idea what the uf1 variable is.

Instead our plan is that we will NOT fail immediately, but:
    (1) Record the "frozen" error in the ic_insols field
    (2) Isolate the offending constraint from the rest of the inerts
    (3) Keep on simplifying/canonicalizing

At the end, we will hopefully have substituted uf1 := F alpha, and we
will be able to report a more informative error:
    'Can't construct the infinite type beta ~ F alpha beta'

Insoluble constraints *do* include Derived constraints. For example,
a functional dependency might give rise to [D] Int ~ Bool, and we must
report that.  If insolubles did not contain Deriveds, reportErrors would
never see it.


%************************************************************************
%*                                                                      *
            Pretty printing
%*                                                                      *
%************************************************************************

\begin{code}
pprEvVars :: [EvVar] -> SDoc    -- Print with their types
pprEvVars ev_vars = vcat (map pprEvVarWithType ev_vars)

pprEvVarTheta :: [EvVar] -> SDoc
pprEvVarTheta ev_vars = pprTheta (map evVarPred ev_vars)

pprEvVarWithType :: EvVar -> SDoc
pprEvVarWithType v = ppr v <+> dcolon <+> pprType (evVarPred v)

pprWantedsWithLocs :: WantedConstraints -> SDoc
pprWantedsWithLocs wcs
  =  vcat [ pprBag ppr (wc_flat wcs)
          , pprBag ppr (wc_impl wcs)
          , pprBag ppr (wc_insol wcs) ]
\end{code}

%************************************************************************
%*                                                                      *
            CtEvidence
%*                                                                      *
%************************************************************************

Note [Evidence field of CtEvidence]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
During constraint solving we never look at the type of ctev_evtm, or
ctev_evar; instead we look at the cte_pred field.  The evtm/evar field
may be un-zonked.

\begin{code}
data CtEvidence
  = CtGiven { ctev_pred :: TcPredType      -- See Note [Ct/evidence invariant]
            , ctev_evtm :: EvTerm }        -- See Note [Evidence field of CtEvidence]
    -- Truly given, not depending on subgoals
    -- NB: Spontaneous unifications belong here

  | CtWanted { ctev_pred :: TcPredType     -- See Note [Ct/evidence invariant]
             , ctev_evar :: EvVar }        -- See Note [Evidence field of CtEvidence]
    -- Wanted goal

  | CtDerived { ctev_pred :: TcPredType }
    -- A goal that we don't really have to solve and can't immediately
    -- rewrite anything other than a derived (there's no evidence!)
    -- but if we do manage to solve it may help in solving other goals.

data CtFlavour = Given | Wanted | Derived

ctFlavour :: Ct -> CtFlavour
ctFlavour ct = ctEvFlavour (cc_ev ct)

ctEvFlavour :: CtEvidence -> CtFlavour
ctEvFlavour (CtGiven {})   = Given
ctEvFlavour (CtWanted {})  = Wanted
ctEvFlavour (CtDerived {}) = Derived

ctEvPred :: CtEvidence -> TcPredType
-- The predicate of a flavor
ctEvPred = ctev_pred

ctEvTerm :: CtEvidence -> EvTerm
ctEvTerm (CtGiven   { ctev_evtm = tm }) = tm
ctEvTerm (CtWanted  { ctev_evar = ev }) = EvId ev
ctEvTerm ctev@(CtDerived {}) = pprPanic "ctEvTerm: derived constraint cannot have id"
                                      (ppr ctev)

ctEvId :: CtEvidence -> TcId
ctEvId (CtWanted  { ctev_evar = ev }) = ev
ctEvId ctev = pprPanic "ctEvId:" (ppr ctev)

instance Outputable CtFlavour where
  ppr Given   = ptext (sLit "[G]")
  ppr Wanted  = ptext (sLit "[W]")
  ppr Derived = ptext (sLit "[D]")

instance Outputable CtEvidence where
  ppr fl = case fl of
             CtGiven {}   -> ptext (sLit "[G]") <+> ppr (ctev_evtm fl) <+> ppr_pty
             CtWanted {}  -> ptext (sLit "[W]") <+> ppr (ctev_evar fl) <+> ppr_pty
             CtDerived {} -> ptext (sLit "[D]") <+> text "_" <+> ppr_pty
         where ppr_pty = dcolon <+> ppr (ctEvPred fl)

isWanted :: CtEvidence -> Bool
isWanted (CtWanted {}) = True
isWanted _ = False

isGiven :: CtEvidence -> Bool
isGiven (CtGiven {})  = True
isGiven _ = False

isDerived :: CtEvidence -> Bool
isDerived (CtDerived {}) = True
isDerived _              = False

canSolve :: CtFlavour -> CtFlavour -> Bool
-- canSolve ctid1 ctid2
-- The constraint ctid1 can be used to solve ctid2
-- "to solve" means a reaction where the active parts of the two constraints match.
--  active(F xis ~ xi) = F xis
--  active(tv ~ xi)    = tv
--  active(D xis)      = D xis
--  active(IP nm ty)   = nm
--
-- NB:  either (a `canSolve` b) or (b `canSolve` a) must hold
-----------------------------------------
canSolve Given   _       = True
canSolve Wanted  Derived = True
canSolve Wanted  Wanted  = True
canSolve Derived Derived = True  -- Derived can't solve wanted/given
canSolve _ _ = False                       -- No evidence for a derived, anyway

canRewrite :: CtFlavour -> CtFlavour -> Bool
-- canRewrite ct1 ct2
-- The equality constraint ct1 can be used to rewrite inside ct2
canRewrite = canSolve
\end{code}

%************************************************************************
%*                                                                      *
            CtLoc
%*                                                                      *
%************************************************************************

The 'CtLoc' gives information about where a constraint came from.
This is important for decent error message reporting because
dictionaries don't appear in the original source code.
type will evolve...

\begin{code}
data CtLoc = CtLoc { ctl_origin :: CtOrigin
                   , ctl_env ::  TcLclEnv
                   , ctl_depth :: SubGoalDepth }
  -- The TcLclEnv includes particularly
  --    source location:  tcl_loc   :: SrcSpan
  --    context:          tcl_ctxt  :: [ErrCtxt]
  --    binder stack:     tcl_bndrs :: [TcIdBinders]

type SubGoalDepth = Int -- An ever increasing number used to restrict
                        -- simplifier iterations. Bounded by -fcontext-stack.
                        -- See Note [WorkList]

mkGivenLoc :: SkolemInfo -> TcLclEnv -> CtLoc
mkGivenLoc skol_info env = CtLoc { ctl_origin = GivenOrigin skol_info
                                 , ctl_env = env
                                 , ctl_depth = 0 }

ctLocEnv :: CtLoc -> TcLclEnv
ctLocEnv = ctl_env

ctLocDepth :: CtLoc -> SubGoalDepth
ctLocDepth = ctl_depth

ctLocOrigin :: CtLoc -> CtOrigin
ctLocOrigin = ctl_origin

ctLocSpan :: CtLoc -> SrcSpan
ctLocSpan (CtLoc { ctl_env = lcl}) = tcl_loc lcl

bumpCtLocDepth :: CtLoc -> CtLoc
bumpCtLocDepth loc@(CtLoc { ctl_depth = d }) = loc { ctl_depth = d+1 }

setCtLocOrigin :: CtLoc -> CtOrigin -> CtLoc
setCtLocOrigin ctl orig = ctl { ctl_origin = orig }

setCtLocEnv :: CtLoc -> TcLclEnv -> CtLoc
setCtLocEnv ctl env = ctl { ctl_env = env }

pushErrCtxt :: CtOrigin -> ErrCtxt -> CtLoc -> CtLoc
pushErrCtxt o err loc@(CtLoc { ctl_env = lcl })
  = loc { ctl_origin = o, ctl_env = lcl { tcl_ctxt = err : tcl_ctxt lcl } }

pushErrCtxtSameOrigin :: ErrCtxt -> CtLoc -> CtLoc
-- Just add information w/o updating the origin!
pushErrCtxtSameOrigin err loc@(CtLoc { ctl_env = lcl })
  = loc { ctl_env = lcl { tcl_ctxt = err : tcl_ctxt lcl } }

pprArising :: CtOrigin -> SDoc
-- Used for the main, top-level error message
-- We've done special processing for TypeEq and FunDep origins
pprArising (TypeEqOrigin {}) = empty
pprArising FunDepOrigin      = empty
pprArising orig              = text "arising from" <+> ppr orig

pprArisingAt :: CtLoc -> SDoc
pprArisingAt (CtLoc { ctl_origin = o, ctl_env = lcl})
  = sep [ text "arising from" <+> ppr o
        , text "at" <+> ppr (tcl_loc lcl)]
\end{code}

%************************************************************************
%*                                                                      *
                SkolemInfo
%*                                                                      *
%************************************************************************

\begin{code}
-- SkolemInfo gives the origin of *given* constraints
--   a) type variables are skolemised
--   b) an implication constraint is generated
data SkolemInfo
  = SigSkol UserTypeCtxt        -- A skolem that is created by instantiating
            Type                -- a programmer-supplied type signature
                                -- Location of the binding site is on the TyVar

        -- The rest are for non-scoped skolems
  | ClsSkol Class       -- Bound at a class decl
  | InstSkol            -- Bound at an instance decl
  | DataSkol            -- Bound at a data type declaration
  | FamInstSkol         -- Bound at a family instance decl
  | PatSkol             -- An existential type variable bound by a pattern for
      DataCon           -- a data constructor with an existential type.
      (HsMatchContext Name)
             -- e.g.   data T = forall a. Eq a => MkT a
             --        f (MkT x) = ...
             -- The pattern MkT x will allocate an existential type
             -- variable for 'a'.

  | ArrowSkol           -- An arrow form (see TcArrows)

  | IPSkol [HsIPName]   -- Binding site of an implicit parameter

  | RuleSkol RuleName   -- The LHS of a RULE

  | InferSkol [(Name,TcType)]
                        -- We have inferred a type for these (mutually-recursivive)
                        -- polymorphic Ids, and are now checking that their RHS
                        -- constraints are satisfied.

  | BracketSkol         -- Template Haskell bracket

  | UnifyForAllSkol     -- We are unifying two for-all types
       [TcTyVar]        -- The instantiated skolem variables
       TcType           -- The instantiated type *inside* the forall

  | UnkSkol             -- Unhelpful info (until I improve it)

instance Outputable SkolemInfo where
  ppr = pprSkolInfo

pprSkolInfo :: SkolemInfo -> SDoc
-- Complete the sentence "is a rigid type variable bound by..."
pprSkolInfo (SigSkol (FunSigCtxt f) ty)
                            = hang (ptext (sLit "the type signature for"))
                                 2 (ppr f <+> dcolon <+> ppr ty)
pprSkolInfo (SigSkol cx ty) = hang (pprUserTypeCtxt cx <> colon)
                                 2 (ppr ty)
pprSkolInfo (IPSkol ips)    = ptext (sLit "the implicit-parameter bindings for")
                              <+> pprWithCommas ppr ips
pprSkolInfo (ClsSkol cls)   = ptext (sLit "the class declaration for") <+> quotes (ppr cls)
pprSkolInfo InstSkol        = ptext (sLit "the instance declaration")
pprSkolInfo DataSkol        = ptext (sLit "the data type declaration")
pprSkolInfo FamInstSkol     = ptext (sLit "the family instance declaration")
pprSkolInfo BracketSkol     = ptext (sLit "a Template Haskell bracket")
pprSkolInfo (RuleSkol name) = ptext (sLit "the RULE") <+> doubleQuotes (ftext name)
pprSkolInfo ArrowSkol       = ptext (sLit "the arrow form")
pprSkolInfo (PatSkol dc mc)  = sep [ ptext (sLit "a pattern with constructor")
                                   , nest 2 $ ppr dc <+> dcolon
                                              <+> ppr (dataConUserType dc) <> comma
                                  , ptext (sLit "in") <+> pprMatchContext mc ]
pprSkolInfo (InferSkol ids) = sep [ ptext (sLit "the inferred type of")
                                  , vcat [ ppr name <+> dcolon <+> ppr ty
                                         | (name,ty) <- ids ]]
pprSkolInfo (UnifyForAllSkol tvs ty) = ptext (sLit "the type") <+> ppr (mkForAllTys tvs ty)

-- UnkSkol
-- For type variables the others are dealt with by pprSkolTvBinding.
-- For Insts, these cases should not happen
pprSkolInfo UnkSkol = WARN( True, text "pprSkolInfo: UnkSkol" ) ptext (sLit "UnkSkol")
\end{code}


%************************************************************************
%*                                                                      *
            CtOrigin
%*                                                                      *
%************************************************************************

\begin{code}
data CtOrigin
  = GivenOrigin SkolemInfo

  -- All the others are for *wanted* constraints
  | OccurrenceOf Name           -- Occurrence of an overloaded identifier
  | AppOrigin                   -- An application of some kind

  | SpecPragOrigin Name         -- Specialisation pragma for identifier

  | TypeEqOrigin { uo_actual   :: TcType
                 , uo_expected :: TcType }
  | KindEqOrigin
      TcType TcType             -- A kind equality arising from unifying these two types
      CtOrigin                  -- originally arising from this

  | IPOccOrigin  HsIPName       -- Occurrence of an implicit parameter

  | LiteralOrigin (HsOverLit Name)      -- Occurrence of a literal
  | NegateOrigin                        -- Occurrence of syntactic negation

  | ArithSeqOrigin (ArithSeqInfo Name) -- [x..], [x..y] etc
  | PArrSeqOrigin  (ArithSeqInfo Name) -- [:x..y:] and [:x,y..z:]
  | SectionOrigin
  | TupleOrigin                        -- (..,..)
  | AmbigOrigin Name    -- f :: ty
  | ExprSigOrigin       -- e :: ty
  | PatSigOrigin        -- p :: ty
  | PatOrigin           -- Instantiating a polytyped pattern at a constructor
  | RecordUpdOrigin
  | ViewPatOrigin

  | ScOrigin            -- Typechecking superclasses of an instance declaration
  | DerivOrigin         -- Typechecking deriving
  | StandAloneDerivOrigin -- Typechecking stand-alone deriving
  | DefaultOrigin       -- Typechecking a default decl
  | DoOrigin            -- Arising from a do expression
  | MCompOrigin         -- Arising from a monad comprehension
  | IfOrigin            -- Arising from an if statement
  | ProcOrigin          -- Arising from a proc expression
  | AnnOrigin           -- An annotation
  | FunDepOrigin
  | HoleOrigin

pprO :: CtOrigin -> SDoc
pprO (GivenOrigin sk)      = ppr sk
pprO (OccurrenceOf name)   = hsep [ptext (sLit "a use of"), quotes (ppr name)]
pprO AppOrigin             = ptext (sLit "an application")
pprO (SpecPragOrigin name) = hsep [ptext (sLit "a specialisation pragma for"), quotes (ppr name)]
pprO (IPOccOrigin name)    = hsep [ptext (sLit "a use of implicit parameter"), quotes (ppr name)]
pprO RecordUpdOrigin       = ptext (sLit "a record update")
pprO (AmbigOrigin name)    = ptext (sLit "the ambiguity check for") <+> quotes (ppr name)
pprO ExprSigOrigin         = ptext (sLit "an expression type signature")
pprO PatSigOrigin          = ptext (sLit "a pattern type signature")
pprO PatOrigin             = ptext (sLit "a pattern")
pprO ViewPatOrigin         = ptext (sLit "a view pattern")
pprO IfOrigin              = ptext (sLit "an if statement")
pprO (LiteralOrigin lit)   = hsep [ptext (sLit "the literal"), quotes (ppr lit)]
pprO (ArithSeqOrigin seq)  = hsep [ptext (sLit "the arithmetic sequence"), quotes (ppr seq)]
pprO (PArrSeqOrigin seq)   = hsep [ptext (sLit "the parallel array sequence"), quotes (ppr seq)]
pprO SectionOrigin         = ptext (sLit "an operator section")
pprO TupleOrigin           = ptext (sLit "a tuple")
pprO NegateOrigin          = ptext (sLit "a use of syntactic negation")
pprO ScOrigin              = ptext (sLit "the superclasses of an instance declaration")
pprO DerivOrigin           = ptext (sLit "the 'deriving' clause of a data type declaration")
pprO StandAloneDerivOrigin = ptext (sLit "a 'deriving' declaration")
pprO DefaultOrigin         = ptext (sLit "a 'default' declaration")
pprO DoOrigin              = ptext (sLit "a do statement")
pprO MCompOrigin           = ptext (sLit "a statement in a monad comprehension")
pprO ProcOrigin            = ptext (sLit "a proc expression")
pprO (TypeEqOrigin t1 t2)  = ptext (sLit "a type equality") <+> sep [ppr t1, char '~', ppr t2]
pprO (KindEqOrigin t1 t2 _) = ptext (sLit "a kind equality arising from") <+> sep [ppr t1, char '~', ppr t2]
pprO AnnOrigin             = ptext (sLit "an annotation")
pprO FunDepOrigin          = ptext (sLit "a functional dependency")
pprO HoleOrigin            = ptext (sLit "a use of the hole") <+> quotes (ptext $ sLit "_")

instance Outputable CtOrigin where
  ppr = pprO
\end{code}

