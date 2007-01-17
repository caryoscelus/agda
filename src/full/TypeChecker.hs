{-# OPTIONS -cpp -fglasgow-exts #-}

module TypeChecker where

import Prelude hiding (putStrLn, putStr, print)

--import Control.Monad
import Control.Applicative
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Error
import qualified Data.Map as Map
import qualified Data.List as List
import Data.Traversable (traverse)
import System.Directory
import System.Time

import qualified Syntax.Abstract as A
import Syntax.Abstract.Pretty
import Syntax.Abstract.Views
import Syntax.Common
import Syntax.Info as Info
import Syntax.Position
import Syntax.Internal
import Syntax.Translation.AbstractToConcrete
import Syntax.Translation.ConcreteToAbstract
import Syntax.Concrete.Pretty ()
import Syntax.Strict
import Syntax.Literal
import Syntax.Scope

import TypeChecking.Monad hiding (defAbstract)
import qualified TypeChecking.Monad as TCM
import TypeChecking.Monad.Name
import TypeChecking.Monad.Builtin
import TypeChecking.Conversion
import TypeChecking.MetaVars
import TypeChecking.Reduce
import TypeChecking.Substitute
import TypeChecking.Primitive
import TypeChecking.Rebind
import TypeChecking.Serialise
import TypeChecking.Interface
import TypeChecking.Constraints
import TypeChecking.Errors
import TypeChecking.Positivity
import TypeChecking.Empty
import TypeChecking.Patterns.Monad

import Utils.Monad
import Utils.List
import Utils.Serialise
import Utils.IO
import Utils.Tuple

#include "undefined.h"

---------------------------------------------------------------------------
-- * Declarations
---------------------------------------------------------------------------

-- | Type check a sequence of declarations.
checkDecls :: [A.Declaration] -> TCM ()
checkDecls ds = mapM_ checkDecl ds


-- | Type check a single declaration.
checkDecl :: A.Declaration -> TCM ()
checkDecl d =
    case d of
	A.Axiom i x e		   -> checkAxiom i x e
	A.Primitive i x e	   -> checkPrimitive i x e
	A.Definition i ts ds	   -> checkMutual i ts ds
	A.Module i x tel ds	   -> checkModule i x tel ds
	A.ModuleDef i x tel m args -> checkModuleDef i x tel m args
	A.Import i x		   -> checkImport i x
	A.Pragma i p		   -> checkPragma i p
	A.Open _		   -> return ()
	    -- open is just an artifact from the concrete syntax


-- | Type check an axiom.
checkAxiom :: DefInfo -> Name -> A.Expr -> TCM ()
checkAxiom _ x e =
    do	t <- isType_ e
	m <- currentModule
	addConstant (qualify m x) (Defn t 0 Axiom)


-- | Type check a primitive function declaration.
checkPrimitive :: DefInfo -> Name -> A.Expr -> TCM ()
checkPrimitive i x e =
    traceCall (CheckPrimitive (getRange i) x e) $ do
    PrimImpl t' pf <- lookupPrimitiveFunction (nameString x)
    t <- isType_ e
    noConstraints $ equalType t t'
    m <- currentModule
    let s  = show x
	qx = qualify m x
    bindPrimitive s $ pf { primFunName = qx }
    addConstant qx (Defn t 0 $ Primitive (defAbstract i) s [])
    where
	nameString (Name _ x) = show x


-- | Check a pragma.
checkPragma :: Range -> A.Pragma -> TCM ()
checkPragma r p =
    traceCall (CheckPragma r p) $ case p of
	A.BuiltinPragma x e -> bindBuiltin x e
	A.OptionsPragma _   -> __IMPOSSIBLE__	-- not allowed here

-- | Type check a bunch of mutual inductive recursive definitions.
checkMutual :: DeclInfo -> [A.TypeSignature] -> [A.Definition] -> TCM ()
checkMutual i ts ds =
    do	mapM_ checkTypeSignature ts
	mapM_ checkDefinition ds
	m <- currentModule
	whenM positivityCheckEnabled $
	    checkStrictlyPositive [ qualify m name | A.DataDef _ name _ _ <- ds ]


-- | Type check the type signature of an inductive or recursive definition.
checkTypeSignature :: A.TypeSignature -> TCM ()
checkTypeSignature (A.Axiom i x e) =
    case defAccess i of
	PublicAccess	-> inAbstractMode $ checkAxiom i x e
	_		-> checkAxiom i x e
checkTypeSignature _ = __IMPOSSIBLE__	-- type signatures are always axioms


-- | Check an inductive or recursive definition. Assumes the type has has been
--   checked and added to the signature.
checkDefinition d =
    case d of
	A.FunDef i x cs	    -> abstract (defAbstract i) $ checkFunDef i x cs
	A.DataDef i x ps cs -> abstract (defAbstract i) $ checkDataDef i x ps cs
    where
	-- Concrete definitions cannot use information about abstract things.
	abstract ConcreteDef = inAbstractMode
	abstract _	     = id


-- | Type check a module.
checkModule :: ModuleInfo -> ModuleName -> A.Telescope -> [A.Declaration] -> TCM ()
checkModule i x tel ds =
    do	tel0 <- getContextTelescope
	checkTelescope tel $ \tel' ->
	    do	m'   <- flip qualifyModule x <$> currentModule
		reportLn 5 $ "adding module " ++ show (mnameId m')
		addModule m' $ ModuleDef
				{ mdefName	= m'
				, mdefTelescope = tel0 ++ tel'
				, mdefNofParams = length tel'
				, mdefDefs	= Map.empty
				}
		withCurrentModule m' $ checkDecls ds


{-| Type check a module definition.
    If M' is qualified we know that its parent is fully instantiated. In other
    words M' is a valid module in a prefix of the current context.

    Current context: ΓΔ

    Without bothering about submodules of M':
	Γ   ⊢ module M' Ω
	ΓΔ  ⊢ module M Θ = M' us
	ΓΔΘ ⊢ us : Ω

	Expl ΓΩ _ = lookupModule M'
	addModule M ΓΔΘ = M' Γ us

    Submodules of M':

	Forall submodules A
	    ΓΩΦ ⊢ module M'.A Ψ ...

	addModule M.A ΓΔΘΦΨ = M'.A Γ us ΦΨ
-}
checkModuleDef :: ModuleInfo -> ModuleName -> A.Telescope -> ModuleName -> [NamedArg A.Expr] -> TCM ()
checkModuleDef i x tel m' args =
    do	m <- flip qualifyModule x <$> currentModule
	gammaDelta <- getContextTelescope
	md' <- lookupModule m'
	let gammaOmega	  = mdefTelescope md'
	    (gamma,omega) = splitAt (length gammaOmega - mdefNofParams md') gammaOmega
	    delta	  = drop (length gamma) gammaDelta
	checkTelescope tel $ \theta ->
	    do	(vs, cs) <- checkArguments_ (getRange m') args omega
		noConstraints (return cs)   -- we don't allow left-over constraints in module instantiations
		let vs0 = reverse [ Arg Hidden
				  $ Var (i + length delta + length theta) []
				  | i <- [0..length gamma - 1]
				  ]
		addModule m $ ModuleDef
				    { mdefName	     = m
				    , mdefTelescope  = gammaDelta ++ theta
				    , mdefNofParams  = length theta
				    , mdefDefs	     = implicitModuleDefs
							(minfoAbstract i)
							(gammaDelta ++ theta)
							m' (vs0 ++ vs)
							(mdefDefs md')
				    }
		forEachModule_ (`isSubModuleOf` m') $ \m'a ->
		    do	md <- lookupModule m'a	-- lookup twice (could be optimised)
			let gammaOmegaPhiPsi = mdefTelescope md
			    ma = requalifyModule m' m m'a
			    phiPsi  = drop (length gammaOmega) gammaOmegaPhiPsi
			    vs1	    = reverse [ Arg Hidden $ Var i []
					      | i <- [0..length phiPsi - 1]
					      ]
			    tel	    = gammaDelta ++ theta ++ phiPsi
			addModule ma $ ModuleDef
					    { mdefName	     = ma
					    , mdefTelescope  = tel
					    , mdefNofParams  = mdefNofParams md
					    , mdefDefs	     = implicitModuleDefs
								(minfoAbstract i)
								tel m'a (vs0 ++ vs ++ vs1)
								(mdefDefs md)
					    }


-- | Type check an import declaration. Actually doesn't do anything, since all
--   the work is done when scope checking.
checkImport :: ModuleInfo -> ModuleName -> TCM ()
checkImport i x = return ()

---------------------------------------------------------------------------
-- * Datatypes
---------------------------------------------------------------------------

-- | Type check a datatype definition. Assumes that the type has already been
--   checked.
checkDataDef :: DefInfo -> Name -> [A.LamBinding] -> [A.Constructor] -> TCM ()
checkDataDef i x ps cs =
    traceCall (CheckDataDef (getRange i) x ps cs) $ do
	m <- currentModule
	let name  = qualify m x
	    npars = length ps

	-- Look up the type of the datatype.
	t <- typeOfConst name

	-- The parameters are in scope when checking the constructors. 
	(nofIxs, s) <- bindParameters ps t $ \tel t -> do

	    -- Parameters are always hidden in constructors
	    let tel' = map hide tel

	    -- The type we get from bindParameters is Θ -> s where Θ is the type of
	    -- the indices. We count the number of indices and return s.
	    (nofIxs, s) <- splitType =<< normalise t

	    -- Check the types of the constructors
	    mapM_ (checkConstructor name tel' nofIxs s) cs

	    -- Return the target sort and the number of indices
	    return (nofIxs, s)

	-- If proof irrelevance is enabled we have to check that datatypes in
	-- Prop contain at most one element.
	do  proofIrr <- proofIrrelevance
	    case (proofIrr, s, cs) of
		(True, Prop, _:_:_) -> typeError PropMustBeSingleton
		_		    -> return ()

	-- Add the datatype to the signature as a datatype. It was previously
	-- added as an axiom.
	addConstant name (Defn t 0 $ Datatype npars nofIxs (map (cname m) cs)
					      s (defAbstract i)
			 )
    where
	cname m (A.Axiom _ x _) = qualify m x
	cname _ _		= __IMPOSSIBLE__ -- constructors are axioms

	hide (Arg _ x) = Arg Hidden x

	splitType (El _ (Pi _ b))  = ((+ 1) -*- id) <$> splitType (absBody b)
	splitType (El _ (Fun _ b)) = ((+ 1) -*- id) <$> splitType b
	splitType (El _ (Sort s))  = return (0, s)
	splitType (El _ t)	   = typeError $ DataMustEndInSort t

-- | Type check a constructor declaration. Checks that the constructor targets
--   the datatype and that it fits inside the declared sort.
checkConstructor :: QName -> Telescope -> Int -> Sort -> A.Constructor -> TCM ()
checkConstructor d tel nofIxs s con@(A.Axiom i c e) =
    traceCall (CheckConstructor d tel s con) $ do
	t <- isType_ e
	n <- length <$> getContextTelescope
	verbose 5 $ do
	    td <- prettyTCM t
	    liftIO $ putStrLn $ "checking that " ++ show td ++ " ends in " ++ show d
	    liftIO $ putStrLn $ "  nofPars = " ++ show n
	constructs n t d
	verbose 5 $ do
	    d <- prettyTCM s
	    liftIO $ putStrLn $ "checking that the type fits in " ++ show d
	t `fitsIn` s
	m <- currentModule
	escapeContext (length tel)
	    $ addConstant (qualify m c)
	    $ Defn (telePi tel t) 0 $ Constructor (length tel) d $ defAbstract i
checkConstructor _ _ _ _ _ = __IMPOSSIBLE__ -- constructors are axioms


-- | Bind the parameters of a datatype. The bindings should be domain free.
bindParameters :: [A.LamBinding] -> Type -> (Telescope -> Type -> TCM a) -> TCM a
bindParameters [] a ret = ret [] a
bindParameters (A.DomainFree h x : ps) (El _ (Pi (Arg h' a) b)) ret	-- always dependent function
    | h /= h'	=
	__IMPOSSIBLE__
    | otherwise = addCtx x a $ bindParameters ps (absBody b) $ \tel s ->
		    ret (Arg h (show x,a) : tel) s
bindParameters _ _ _ = __IMPOSSIBLE__


-- | Check that the arguments to a constructor fits inside the sort of the datatype.
--   The first argument is the type of the constructor.
fitsIn :: Type -> Sort -> TCM ()
fitsIn t s =
    do	t <- instantiate t
	case funView $ unEl t of
	    FunV (Arg h a) _ -> do
		let s' = getSort a
		s' `leqSort` s
		x <- freshName_ (argName t)
		let v  = Arg h $ Var 0 []
		    t' = piApply' (raise 1 t) [v]
		addCtx x a $ fitsIn t' s
	    _		     -> return ()

-- | Check that a type constructs something of the given datatype. The first
--   argument is the number of parameters to the datatype.
--   TODO: what if there's a meta here?
constructs :: Int -> Type -> QName -> TCM ()
constructs nofPars t q = constrT 0 t
    where
	constrT n (El s v) = constr n s v

	constr n s v = do
	    v <- reduce v
	    case v of
		Pi a b	-> underAbstraction (unArg a) b $ \t ->
			   constrT (n + 1) t
		Fun _ b -> constrT n b
		Def d vs
		    | d == q -> checkParams n =<< reduce (take nofPars vs)
						    -- we only check the parameters
		_ -> bad $ El s v

	bad t = typeError $ ShouldEndInApplicationOfTheDatatype t

	checkParams n vs
	    | vs `sameVars` ps = return ()
	    | otherwise	       =
		typeError $ ShouldBeAppliedToTheDatatypeParameters
			    (apply def ps) (apply def vs)
	    where
		def = Def q []
		ps = reverse [ Arg h $ Var i [] | (i,Arg h _) <- zip [n..] vs ]
		sameVar (Var i []) (Var j []) = i == j
		sameVar _ _		      = False

		sameVars xs ys = and $ zipWith sameVar (map unArg xs) (map unArg ys)


-- | Force a type to be a specific datatype.
forceData :: MonadTCM tcm => QName -> Type -> tcm Type
forceData d (El s0 t) = liftTCM $ do
    t' <- reduce t
    case t' of
	Def d' _
	    | d == d'   -> return $ El s0 t'
	MetaV m vs	    -> do
	    Defn t _ (Datatype _ _ _ s _) <- getConstInfo d
	    ps <- newArgsMeta t
	    noConstraints $ equalType (El s0 t') (El s (Def d ps)) -- TODO: too strict?
	    reduce $ El s0 t'
	_ -> typeError $ ShouldBeApplicationOf (El s0 t) d

---------------------------------------------------------------------------
-- * Definitions by pattern matching
---------------------------------------------------------------------------

-- | Type check a definition by pattern matching.
checkFunDef :: DefInfo -> Name -> [A.Clause] -> TCM ()
checkFunDef i x cs =

    traceCall (CheckFunDef (getRange i) x cs) $ do
	-- Get the type of the function
	name <- flip qualify x <$> currentModule
	t    <- typeOfConst name

	-- Check the clauses
	cs <- mapM (checkClause t) cs

	-- Check that all clauses have the same number of arguments
	unless (allEqual $ map npats cs) $ typeError DifferentArities

	-- Annotate the clauses with which arguments are actually used.
	cs <- mapM rebindClause cs

	-- Add the definition
	addConstant name $ Defn t 0 $ Function cs $ defAbstract i
    where
	npats (Clause ps _) = length ps


-- | Type check a function clause.
checkClause :: Type -> A.Clause -> TCM Clause
checkClause t c@(A.Clause (A.LHS i x aps) rhs ds) =
    traceCall (CheckClause t c) $
    checkLHS aps t $ \xs ps t' -> do
	checkDecls ds
	body <- case rhs of
	    A.RHS e -> do
		v <- checkExpr e t'
		return $ foldr (\x t -> Bind $ Abs x t) (Body v) xs
	    A.AbsurdRHS
		| any (containsAbsurdPattern . namedThing . unArg) aps
			    -> return NoBody
		| otherwise -> typeError $ NoRHSRequiresAbsurdPattern aps
	return $ Clause ps body

-- | Check if a pattern contains an absurd pattern. For instance, @suc ()@
containsAbsurdPattern :: A.Pattern -> Bool
containsAbsurdPattern p = case p of
    A.AbsurdP _   -> True
    A.VarP _	  -> False
    A.WildP _	  -> False
    A.ImplicitP _ -> False
    A.DotP _ _	  -> False
    A.LitP _	  -> False
    A.AsP _ _ p   -> containsAbsurdPattern p
    A.ConP _ _ ps -> any (containsAbsurdPattern . namedThing . unArg) ps
    A.DefP _ _ _  -> __IMPOSSIBLE__

-- | Type check a left-hand side.
checkLHS :: [NamedArg A.Pattern] -> Type -> ([String] -> [Arg Pattern] -> Type -> TCM a) -> TCM a
checkLHS ps t ret = do

    -- Save the state for later. (should this be done with the undo monad, or
    -- would that interfere with normal undo?)
    rollback <- do
	checkPoint <- get
	return $ put checkPoint

    runCheckPatM (checkPatterns ps t) $ \xs metas (ps0, ps, ts, a) -> do

    -- < Insert magic code for inductive families here. >

    -- Build the new pattern, turning implicit patterns into variables when
    -- they couldn't be solved.
    ps1 <- evalStateT (buildNewPatterns ps0) metas

    verbose 5 $ liftIO $ do
	putStrLn $ "first check"
	putStrLn $ "  xs    = " ++ show xs
	putStrLn $ "  metas = " ++ show metas
	putStrLn $ "  ps0   = " ++ showA ps0
	putStrLn $ "  ps1   = " ++ showA ps1

    verbose 5 $ do
	is <- mapM (instantiateFull . flip MetaV []) metas
	ds <- mapM prettyTCM is
	dts <- mapM prettyTCM =<< mapM instantiateFull ts
	liftIO $ putStrLn $ "  is    = " ++ concat (List.intersperse ", " $ map show ds)
	liftIO $ putStrLn $ "  ts    = " ++ concat (List.intersperse ", " $ map show dts)

    -- Now we forget that we ever type checked anything and type check the new
    -- pattern.
    rollback
    escapeContext (length xs) $ runCheckPatM (checkPatterns ps1 t)
			      $ \xs metas (_, ps, ts, a) -> do

    verbose 5 $ liftIO $ do
	putStrLn $ "second check"
	putStrLn $ "  xs    = " ++ show xs
	putStrLn $ "  metas = " ++ show metas

    verbose 5 $ do
	is <- mapM (instantiateFull . flip MetaV []) metas
	ds <- mapM prettyTCM is
	liftIO $ putStrLn $ "  is    = " ++ concat (List.intersperse ", " $ map show ds)

    -- Finally we type check the dot patterns and check that they match their
    -- instantiations.
    evalStateT (checkDotPatterns ps1) metas

    -- Sanity check. Make sure that all metas were instantiated.
    is <- mapM lookupMeta metas
    case [ getRange i | i <- is, FirstOrder <- [mvInstantiation i] ] of
	[] -> return ()
	rs -> fail $ "unsolved pattern metas at\n" ++ unlines (map show rs)

    ret xs ps a
    where
	popMeta = do
	    x : xs <- get
	    put xs
	    return x

	buildNewPatterns :: [NamedArg A.Pattern] -> StateT [MetaId] TCM [NamedArg A.Pattern]
	buildNewPatterns = mapM buildNewPattern'

	buildNewPattern' = (traverse . traverse) buildNewPattern

	buildNewPattern :: A.Pattern -> StateT [MetaId] TCM A.Pattern
	buildNewPattern (A.ImplicitP i) = do
	    x <- popMeta
	    v <- lift $ instantiate (MetaV x [])
	    lift $ verbose 6 $ do
		d <- prettyTCM v
		liftIO $ putStrLn $ "new pattern for " ++ show x ++ " = " ++ show d
	    case v of
		-- Unsolved metas become variables
		MetaV y _ | x == y  -> return $ A.WildP i
		-- Anything else becomes dotted
		_		    -> do
		    lift $ verbose 6 $ do
			d <- prettyTCM =<< instantiateFull v
			liftIO $ putStrLn $ show x ++ " := " ++ show d
		    return $ A.DotP i (A.Underscore info)
		    where info = MetaInfo
				    (getRange i)
				    emptyScopeInfo  -- TODO: fill in the right thing here
				    Nothing
	buildNewPattern p@(A.VarP _)	= return p
	buildNewPattern p@(A.WildP _)	= return p
	buildNewPattern p@(A.DotP _ _)	= popMeta >> return p
	buildNewPattern (A.AsP i x p)	= A.AsP i x <$> buildNewPattern p
	buildNewPattern (A.ConP i c ps) = A.ConP i c <$> buildNewPatterns ps
	buildNewPattern (A.DefP i c ps) = A.DefP i c <$> buildNewPatterns ps
	buildNewPattern p@(A.AbsurdP _)	= return p
	buildNewPattern p@(A.LitP _)	= return p

	checkDotPatterns :: [NamedArg A.Pattern] -> StateT [MetaId] TCM ()
	checkDotPatterns = mapM_ checkDotPattern'

	checkDotPattern' p = (traverse . traverse) checkDotPattern p >> return ()

	checkDotPattern :: A.Pattern -> StateT [MetaId] TCM ()
	checkDotPattern (A.ImplicitP i) = __IMPOSSIBLE__    -- there should be no implicits left at this point
	checkDotPattern p@(A.VarP _)	= return ()
	checkDotPattern p@(A.WildP _)	= return ()
	checkDotPattern p@(A.DotP i e)	= do
	    x <- popMeta
	    lift $ do
		firstOrder <- isFirstOrder x    -- first order and uninstantiated
		when firstOrder $ typeError
				$ InternalError	-- TODO: proper error
				$ "uninstantiated dot pattern at " ++ show (getRange i)
		HasType _ ot <- mvJudgement <$> lookupMeta x
		t <- getOpen ot
		v <- checkExpr e t
		noConstraints $ equalTerm t v (MetaV x [])
	checkDotPattern (A.AsP i x p)	= checkDotPattern p
	checkDotPattern (A.ConP i c ps) = checkDotPatterns ps
	checkDotPattern (A.DefP i c ps) = checkDotPatterns ps
	checkDotPattern p@(A.AbsurdP _)	= return ()
	checkDotPattern p@(A.LitP _)	= return ()


-- | Check the patterns of a left-hand-side. Binds the variables of the pattern.
checkPatterns :: [NamedArg A.Pattern] -> Type -> CheckPatM r ([NamedArg A.Pattern], [Arg Pattern], [Arg Term], Type)
checkPatterns [] t = do
    -- traceCallCPS (CheckPatterns [] t) ret $ \ret -> do
    t' <- instantiate t
    case funView $ unEl t' of
	FunV (Arg Hidden _) _   -> do
	    r <- getCurrentRange
	    checkPatterns [Arg Hidden $ unnamed $ A.ImplicitP $ PatRange r] t'
	_ -> return ([], [], [], t)

checkPatterns ps0@(Arg h np:ps) t = do
    -- traceCallCPS (CheckPatterns ps0 t) ret $ \ret -> do

    -- Make sure the type is a function type
    (t', cs) <- forcePi h (name np) t
    opent'   <- makeOpen t'

    -- Add any resulting constraints to the global constraint set
    addNewConstraints cs

    -- If np is named then np = {x = p'}
    let p' = namedThing np

    -- We might have to insert wildcards for implicit arguments
    case funView $ unEl t' of

	-- There is a hidden argument missing here (either because the next
	-- pattern is non-hidden, or it's a named hidden pattern with the wrong name).
	-- Insert a {_} and re-type check.
	FunV (Arg Hidden _) _
	    | h == NotHidden ||
	      not (sameName (nameOf np) (nameInPi $ unEl t')) ->
	    checkPatterns (Arg Hidden (unnamed $ A.ImplicitP $ PatRange $ getRange np) : Arg h np : ps) t'

	-- No missing arguments.
	FunV (Arg h' a) _ | h == h' -> do

	    -- Check the first pattern
	    (p0, p, v) <- checkPattern (argName t') p' a
	    openv      <- makeOpen v

	    -- We're now in an extended context so we have lift t' accordingly.
	    t0 <- getOpen opent'

	    -- Check the rest of the patterns. If the type of all the patterns were
	    -- (x : A)Δ, then we check the rest against Δ[v] where v is the
	    -- value of the first pattern (piApply' (Γ -> B) vs == B[vs/Γ]).
	    (ps0, ps, vs, t'') <- checkPatterns ps (piApply' t0 [Arg h' v])

	    -- Additional variables have been added to the context.
	    v' <- getOpen openv

	    -- Combine the results
	    return (Arg h (fmap (const p0) np) : ps0, Arg h p : ps, Arg h v':vs, t'')

	_ -> typeError $ WrongHidingInLHS t'
    where
	name (Named _ (A.VarP x)) = show x
	name (Named (Just x) _)   = x
	name _			  = "x"

	sameName Nothing _  = True
	sameName n1	 n2 = n1 == n2

	nameInPi (Pi _ b)  = Just $ absName b
	nameInPi (Fun _ _) = Nothing
	nameInPi _	   = __IMPOSSIBLE__

-- | TODO: move
argName = argN . unEl
    where
	argN (Pi _ b)  = "_" ++ absName b
	argN (Fun _ _) = "_"
	argN _	  = __IMPOSSIBLE__


actualConstructor :: MonadTCM tcm => QName -> tcm QName
actualConstructor c = do
    v <- constructorForm =<< reduce (Con c [])
    case ignoreBlocking v of
	Con c _	-> return c
	_	-> actualConstructor =<< stripLambdas v
    where
	stripLambdas v = case ignoreBlocking v of
	    Con c _ -> return c
	    Lam _ b -> do
		x <- freshName_ $ absName b
		addCtx x (sort Prop) $ stripLambdas (absBody b)
	    _	    -> typeError $ GenericError $ "Not a constructor: " ++ show c

-- | Type check a pattern and bind the variables. First argument is a name
--   suggestion for wildcard patterns.
checkPattern :: String -> A.Pattern -> Type -> CheckPatM r (A.Pattern, Pattern, Term)
checkPattern name p t =
--    traceCallCPS (CheckPattern name p t) ret $ \ret -> case p of
    case p of

	-- Variable. Simply bind the variable.
	A.VarP x    -> do
	    bindPatternVar x t
	    return (p, VarP (show x), Var 0 [])

	-- Wild card. Create and bind a fresh name.
	A.WildP i   -> do
	    x <- freshName (getRange i) name
	    bindPatternVar x t
	    return (p, VarP name, Var 0 [])

	-- Implicit pattern. Create a new meta variable.
	A.ImplicitP i -> do
	    x <- addPatternMeta normalMetaPriority t
	    return (p, WildP, MetaV x [])

	-- Dot pattern. Create a meta variable.
	A.DotP i _ -> do
	    -- we should always instantiate dotted patterns first
	    x <- addPatternMeta highMetaPriority t
	    return (p, WildP, MetaV x [])

	-- Constructor. This is where the action is.
	A.ConP i c ps -> do

	    -- We're gonna need t in a different context so record the current
	    -- one.
	    ot <- makeOpen t

	    -- The constructor might have been renamed
	    c  <- actualConstructor c

	    (t', vs) <- do
		-- Get the type of the constructor and the target datatype. The
		-- type is the full lambda lifted type.
		Defn t' _ (Constructor _ d _) <- getConstInfo c

		-- Make sure that t is an application of the datatype to its
		-- parameters (and some indices). This will include module
		-- parameters.
		El _ (Def _ vs)	<- forceData d t

		-- Get the number of parameters of the datatype, including
		-- parameters to enclosing modules.
		Datatype nofPars _ _ _ _ <- theDef <$> getConstInfo d

		-- Throw away the indices
		let vs' = take nofPars vs
		return (t', vs')

	    -- Apply the constructor to the datatype parameters and compute the
	    -- canonical form (it might go through a lot of module
	    -- instantiations).
	    Con c' us <- constructorForm =<< reduce (Con c $ map hide vs)

	    -- We're gonna need the parameters in a different context.
	    ous	<- makeOpen us

	    -- Check the arguments
	    (aps, ps', ts', rest) <- checkPatterns ps (piApply' t' vs)

	    -- Compute the corresponding value (possibly blocked by constraints)
	    v <- do
		tn  <- getOpen ot
		us' <- getOpen ous
		blockTerm tn (Con c' $ us' ++ ts') $ equalType rest tn

	    return (A.ConP i c' aps, ConP c' ps', v)
	    where
		hide (Arg _ x) = Arg Hidden x

	-- Absurd pattern. Make sure that the type is empty. Otherwise treat as
	-- an anonymous variable.
	A.AbsurdP i -> do
	    isEmptyType t
	    x <- freshName (getRange i) name
	    bindPatternVar x t
	    return (p, AbsurdP, Var 0 [])

	-- As pattern. Create a let binding for the term corresponding to the
	-- pattern.
	A.AsP i x p -> do
	    ot	       <- makeOpen t
	    (p0, p, v) <- checkPattern name p t
	    t	       <- getOpen ot
	    liftPatCPS_ (addLetBinding x v t)
	    return (p0, p, v)

	-- Literal.
	A.LitP l    -> do
	    v <- liftTCM $ checkLiteral l t
	    return (p, LitP l, v)

	-- Defined patterns are not implemented.
	A.DefP i f ps ->
	    typeError $ NotImplemented "defined patterns"


---------------------------------------------------------------------------
-- * Let bindings
---------------------------------------------------------------------------

checkLetBindings :: [A.LetBinding] -> TCM a -> TCM a
checkLetBindings = foldr (.) id . map checkLetBinding

checkLetBinding :: A.LetBinding -> TCM a -> TCM a
checkLetBinding b@(A.LetBind i x t e) ret =
    traceCallCPS_ (CheckLetBinding b) ret $ \ret -> do
	t <- isType_ t
	v <- checkExpr e t
	addLetBinding x v t ret

---------------------------------------------------------------------------
-- * Types
---------------------------------------------------------------------------

-- | Check that an expression is a type.
isType :: A.Expr -> Sort -> TCM Type
isType e s =
    traceCall (IsTypeCall e s) $ do
    v <- checkExpr e (sort s)
    return $ El s v

-- | Check that an expression is a type without knowing the sort.
isType_ :: A.Expr -> TCM Type
isType_ e =
    traceCall (IsType_ e) $ do
    s <- newSortMeta
    isType e s


-- | Force a type to be a Pi. Instantiates if necessary. The 'Hiding' is only
--   used when instantiating a meta variable.
forcePi :: MonadTCM tcm => Hiding -> String -> Type -> tcm (Type, Constraints)
forcePi h name (El s t) =
    do	t' <- reduce t
	case t' of
	    Pi _ _	-> return (El s t', [])
	    Fun _ _	-> return (El s t', [])
	    MetaV m vs	-> do
		i <- getMetaInfo <$> lookupMeta m

		sa <- newSortMeta
		sb <- newSortMeta
		let s' = sLub sa sb

		a <- newTypeMeta sa
		x <- refreshName (getRange i) name
		b <- addCtx x a $ newTypeMeta sb

		let ty = El s' $ Pi (Arg h a) (Abs (show x) b)
		cs <- equalType (El s t') ty
		ty' <- reduce ty
		return (ty', cs)
	    _ -> typeError $ ShouldBePi (El s t')


---------------------------------------------------------------------------
-- * Telescopes
---------------------------------------------------------------------------

-- | Type check a telescope. Binds the variables defined by the telescope.
checkTelescope :: A.Telescope -> (Telescope -> TCM a) -> TCM a
checkTelescope [] ret = ret []
checkTelescope (b : tel) ret =
    checkTypedBindings b $ \tel1 ->
    checkTelescope tel   $ \tel2 ->
	ret $ tel1 ++ tel2


-- | Check a typed binding and extends the context with the bound variables.
--   The telescope passed to the continuation is valid in the original context.
checkTypedBindings :: A.TypedBindings -> (Telescope -> TCM a) -> TCM a
checkTypedBindings (A.TypedBindings i h bs) ret =
    thread checkTypedBinding bs $ \bss ->
    ret $ map (Arg h) (concat bss)

checkTypedBinding :: A.TypedBinding -> ([(String,Type)] -> TCM a) -> TCM a
checkTypedBinding (A.TBind i xs e) ret = do
    t <- isType_ e
    addCtxs xs t $ ret $ mkTel xs t
    where
	mkTel [] t     = []
	mkTel (x:xs) t = (show x,t) : mkTel xs (raise 1 t)
checkTypedBinding (A.TNoBind e) ret = do
    t <- isType_ e
    ret [("_",t)]


---------------------------------------------------------------------------
-- * Terms
---------------------------------------------------------------------------

-- | Type check an expression.
checkExpr :: A.Expr -> Type -> TCM Term
checkExpr e t =
    traceCall (CheckExpr e t) $ do
    t <- instantiate t
    case e of

	-- Variable or constant application
	_   | Application hd args <- appView e -> do
		(v,  t0)     <- inferHead hd
		(vs, t1, cs) <- checkArguments (getRange hd) args t0 t
		blockTerm t (apply v vs) $ (cs ++) <$> equalType t1 t

	-- Insert hidden lambda if appropriate
	_   | not (hiddenLambda e)
	    , FunV (Arg Hidden _) _ <- funView (unEl t) -> do
		x <- freshName r (argName t)
		checkExpr (A.Lam (ExprRange $ getRange e) (A.DomainFree Hidden x) e) t
	    where
		r = emptyR (rStart $ getRange e)
		    where
			emptyR r = Range r r

		hiddenLambda (A.Lam _ (A.DomainFree Hidden _) _)		     = True
		hiddenLambda (A.Lam _ (A.DomainFull (A.TypedBindings _ Hidden _)) _) = True
		hiddenLambda _							     = False

	A.App i e arg -> do
	    (v0, t0)	 <- inferExpr e
	    (vs, t1, cs) <- checkArguments (getRange e) [arg] t0 t
	    blockTerm t (apply v0 vs) $ (cs ++) <$> equalType t1 t

	A.Lam i (A.DomainFull b) e ->
	    checkTypedBindings b $ \tel -> do
	    t1 <- newTypeMeta_
	    cs <- escapeContext (length tel) $ equalType t (telePi tel t1)
	    v <- checkExpr e t1
	    blockTerm t (buildLam (map name tel) v) (return cs)
	    where
		name (Arg h (x,_)) = Arg h x

	A.Lam i (A.DomainFree h x) e0 -> do
	    (t',cs) <- forcePi h (show x) t
	    case funView $ unEl t' of
		FunV (Arg h' a) _
		    | h == h' ->
			addCtx x a $ do
			let arg = Arg h (Var 0 [])
			    tb  = raise 1 t' `piApply'` [arg]
			v <- checkExpr e0 tb
			blockTerm t (Lam h (Abs (show x) v)) (return cs)
		    | otherwise ->
			typeError $ WrongHidingInLambda t'
		_   -> __IMPOSSIBLE__

	A.QuestionMark i -> do
	    setScope (Info.metaScope i)
	    newQuestionMark  t
	A.Underscore i   -> do
	    setScope (Info.metaScope i)
	    newValueMeta t

	A.Lit lit    -> checkLiteral lit t
	A.Let i ds e -> checkLetBindings ds $ checkExpr e t
	A.Pi _ tel e ->
	    checkTelescope tel $ \tel -> do
	    t' <- telePi tel <$> isType_ e
	    blockTerm t (unEl t') $ equalType (sort $ getSort t') t
	A.Fun _ (Arg h a) b -> do
	    a' <- isType_ a
	    b' <- isType_ b
	    let s = getSort a' `sLub` getSort b'
	    blockTerm t (Fun (Arg h a') b') $ equalType (sort s) t
	A.Set _ n    ->
	    blockTerm t (Sort (Type n)) $ equalType (sort $ Type $ n + 1) t
	A.Prop _     ->
	    blockTerm t (Sort Prop) $ equalType (sort $ Type 1) t
	A.Var _ _    -> __IMPOSSIBLE__
	A.Def _ _    -> __IMPOSSIBLE__
	A.Con _ _    -> __IMPOSSIBLE__


-- | Infer the type of a head thing (variable, function symbol, or constructor)
inferHead :: Head -> TCM (Term, Type)
inferHead (HeadVar _ x) = traceCall (InferVar x) $ getVarInfo x
inferHead (HeadCon i x) = inferDef Con i x
inferHead (HeadDef i x) = inferDef Def i x

inferDef :: (QName -> Args -> Term) -> NameInfo -> QName -> TCM (Term, Type)
inferDef mkTerm i x =
    traceCall (InferDef (getRange i) x) $ do
    d  <- getConstInfo x
    d' <- instantiateDef d
    gammaDelta <- getContextTelescope
    let t     = defType d'
	gamma = take (defFreeVars d) gammaDelta
	k     = length gammaDelta - defFreeVars d
	vs    = reverse [ Arg h $ Var (i + k) []
			| (Arg h _,i) <- zip gamma [0..]
			]
    return (mkTerm x vs, t)


-- | Check a list of arguments: @checkArgs args t0 t1@ checks that
--   @t0 = Delta -> t0'@ and @args : Delta@. Inserts hidden arguments to
--   make this happen. Returns @t0'@ and any constraints that have to be
--   solve for everything to be well-formed.
checkArguments :: Range -> [NamedArg A.Expr] -> Type -> Type -> TCM (Args, Type, Constraints)
checkArguments r [] t0 t1 =
    traceCall (CheckArguments r [] t0 t1) $ do
	t0' <- reduce t0
	t1' <- reduce t1
	case funView $ unEl t0' of -- TODO: clean
	    FunV (Arg Hidden a) _ | notHPi $ unEl t1'  -> do
		v  <- newValueMeta a
		let arg = Arg Hidden v
		(vs, t0'',cs) <- checkArguments r [] (piApply' t0' [arg]) t1'
		return (arg : vs, t0'',cs)
	    _ -> return ([], t0', [])
    where
	notHPi (Pi  (Arg Hidden _) _) = False
	notHPi (Fun (Arg Hidden _) _) = False
	notHPi _		      = True

checkArguments r args0@(Arg h e : args) t0 t1 =
    traceCall (CheckArguments r args0 t0 t1) $ do
	(t0', cs) <- forcePi h (name e) t0
	e' <- return $ namedThing e
	case (h, funView $ unEl t0') of
	    (NotHidden, FunV (Arg Hidden a) _) -> do
		u  <- newValueMeta a
		let arg = Arg Hidden u
		(us, t0'',cs') <- checkArguments r (Arg h e : args)
				       (piApply' t0' [arg]) t1
		return (arg : us, t0'', cs ++ cs')
	    (Hidden, FunV (Arg Hidden a) _)
		| not $ sameName (nameOf e) (nameInPi $ unEl t0') -> do
		    u  <- newValueMeta a
		    let arg = Arg Hidden u
		    (us, t0'',cs') <- checkArguments r (Arg h e : args)
					   (piApply' t0' [arg]) t1
		    return (arg : us, t0'', cs ++ cs')
	    (_, FunV (Arg h' a) _) | h == h' -> do
		u  <- checkExpr e' a
		let arg = Arg h u
		(us, t0'', cs') <- checkArguments (fuseRange r e) args (piApply' t0' [arg]) t1
		return (arg : us, t0'', cs ++ cs')
	    (Hidden, FunV (Arg NotHidden _) _) ->
		typeError $ WrongHidingInApplication t0'
	    _ -> __IMPOSSIBLE__
    where
	name (Named _ (A.Var _ x)) = show x
	name (Named (Just x) _)    = x
	name _			   = "x"

	sameName Nothing _  = True
	sameName n1	 n2 = n1 == n2

	nameInPi (Pi _ b)  = Just $ absName b
	nameInPi (Fun _ _) = Nothing
	nameInPi _	   = __IMPOSSIBLE__


-- | Check that a list of arguments fits a telescope.
checkArguments_ :: Range -> [NamedArg A.Expr] -> Telescope -> TCM (Args, Constraints)
checkArguments_ r args tel = do
    (args, _, cs) <- checkArguments r args (telePi tel $ sort Prop) (sort Prop)
    return (args, cs)


-- | Infer the type of an expression. Implemented by checking agains a meta
--   variable.
inferExpr :: A.Expr -> TCM (Term, Type)
inferExpr e = do
    t <- newTypeMeta_
    v <- checkExpr e t
    return (v,t)

---------------------------------------------------------------------------
-- * Literal
---------------------------------------------------------------------------

checkLiteral :: Literal -> Type -> TCM Term
checkLiteral lit t = do
    t' <- litType lit
    v  <- blockTerm t (Lit lit) $ equalType t t'
    return v
    where
	el t = El (Type 0) t
	litType l = case l of
	    LitInt _ _	  -> el <$> primNat
	    LitFloat _ _  -> el <$> primFloat
	    LitChar _ _   -> el <$> primChar
	    LitString _ _ -> el <$> primString

---------------------------------------------------------------------------
-- * Checking builtin pragmas
---------------------------------------------------------------------------

bindBuiltinType :: String -> A.Expr -> TCM ()
bindBuiltinType b e = do
    t <- checkExpr e (sort $ Type 0)
    bindBuiltinName b t

bindBuiltinBool :: String -> A.Expr -> TCM ()
bindBuiltinBool b e = do
    bool <- primBool
    t	 <- checkExpr e $ El (Type 0) bool
    bindBuiltinName b t

-- | Bind something of type @Set -> Set@.
bindBuiltinType1 :: String -> A.Expr -> TCM ()
bindBuiltinType1 thing e = do
    let set	 = sort (Type 0)
	setToSet = El (Type 1) $ Fun (Arg NotHidden set) set
    f <- checkExpr e setToSet
    bindBuiltinName thing f

bindBuiltinEqual :: A.Expr -> TCM ()
bindBuiltinEqual e = do
    let set = sort (Type 0)
	el  = El (Type 0)
	el1 = El (Type 1)
	vz  = Var 0 []
	nhid = Arg NotHidden
	t   = el1 $ Pi (Arg Hidden set) $ Abs "A"
	    $ el1 $ Fun (nhid $ el vz) $ el1 $ Fun (nhid $ el vz) set
    eq <- checkExpr e t
    bindBuiltinName builtinEquality eq

bindBuiltinRefl :: A.Expr -> TCM ()
bindBuiltinRefl e = do
    eq <- primEqual
    let set = sort (Type 0)
	el  = El (Type 0)
	el1 = El (Type 1)
	vz  = Var 0 []
	hpi x a t = Pi (Arg Hidden a) $ Abs x $ el t
	t   = el1 $ hpi "A" set $ hpi "x" (el vz)
		  $ eq `apply` 
		    (Arg Hidden (Var 1 []) : map (Arg NotHidden) [vz,vz])
    refl <- checkExpr e t
    bindBuiltinName builtinRefl refl

bindBuiltinZero :: A.Expr -> TCM ()
bindBuiltinZero e = do
    nat  <- primNat
    zero <- checkExpr e (El (Type 0) nat)
    bindBuiltinName builtinZero zero

bindBuiltinSuc :: A.Expr -> TCM ()
bindBuiltinSuc e = do
    nat  <- primNat
    let	nat' = El (Type 0) nat
	natToNat = El (Type 0) $ Fun (Arg NotHidden nat') nat'
    suc <- checkExpr e natToNat
    bindBuiltinName builtinSuc suc

-- | Built-in nil should have type @{A:Set} -> List A@
bindBuiltinNil :: A.Expr -> TCM ()
bindBuiltinNil e = do
    list' <- primList
    let set	= sort (Type 0)
	list a	= El (Type 0) (list' `apply` [Arg NotHidden a])
	nilType = telePi [Arg Hidden ("A",set)] $ list (Var 0 [])
    nil <- checkExpr e nilType
    bindBuiltinName builtinNil nil

-- | Built-in cons should have type @{A:Set} -> A -> List A -> List A@
bindBuiltinCons :: A.Expr -> TCM ()
bindBuiltinCons e = do
    list' <- primList
    let set	  = sort (Type 0)
	el	  = El (Type 0)
	a	  = Var 0 []
	list x	  = el $ list' `apply` [Arg NotHidden x]
	hPi x a b = telePi [Arg Hidden (x,a)] b
	fun a b	  = el $ Fun (Arg NotHidden a) b
	consType  = hPi "A" set $ el a `fun` (list a `fun` list a)
    cons <- checkExpr e consType
    bindBuiltinName builtinCons cons

bindBuiltinPrimitive :: String -> String -> A.Expr -> (Term -> TCM ()) -> TCM ()
bindBuiltinPrimitive name builtin e@(A.Def _ qx) verify = do
    PrimImpl t pf <- lookupPrimitiveFunction name
    v <- checkExpr e t

    verify v

    info <- getConstInfo qx
    let cls = defClauses info
	a   = TCM.defAbstract info
    bindPrimitive name $ pf { primFunName = qx }
    addConstant qx $ info { theDef = Primitive a name cls }

    -- needed? yes, for checking equations for mul
    bindBuiltinName builtin v
bindBuiltinPrimitive _ b _ _ = typeError $ GenericError $ "Builtin " ++ b ++ " must be bound to a function"

builtinPrimitives :: [ (String, (String, Term -> TCM ())) ]
builtinPrimitives =
    [ "NATPLUS"   |-> ("primNatPlus", verifyPlus)
    , "NATMINUS"  |-> ("primNatMinus", verifyMinus)
    , "NATTIMES"  |-> ("primNatTimes", verifyTimes)
    , "NATDIVSUC" |-> ("primNatDivSuc", verifyDivSuc)
    , "NATMODSUC" |-> ("primNatModSuc", verifyModSuc)
    , "NATEQUALS" |-> ("primNatEquals", verifyEquals)
    , "NATLESS"	  |-> ("primNatLess", verifyLess)
    ]
    where
	(|->) = (,)

	verifyPlus plus =
	    verify ["n","m"] $ \(@@) zero suc (==) choice -> do
		let m = Var 0 []
		    n = Var 1 []
		    x + y = plus @@ x @@ y

		-- We allow recursion on any argument
		choice
		    [ do n + zero  == n
			 n + suc m == suc (n + m)
		    , do suc n + m == suc (n + m)
			 zero  + m == m
		    ]

	verifyMinus minus =
	    verify ["n","m"] $ \(@@) zero suc (==) choice -> do
		let m = Var 0 []
		    n = Var 1 []
		    x - y = minus @@ x @@ y

		-- We allow recursion on any argument
		zero  - m     == zero
		suc n - zero  == suc n
		suc n - suc m == (n - m)

	verifyTimes times = do
	    plus <- primNatPlus
	    verify ["n","m"] $ \(@@) zero suc (==) choice -> do
		let m = Var 0 []
		    n = Var 1 []
		    x + y = plus  @@ x @@ y
		    x * y = times @@ x @@ y

		choice
		    [ do n * zero == zero
			 choice [ (n * suc m) == (n + (n * m))
				, (n * suc m) == ((n * m) + n)
				]
		    , do zero * n == zero
			 choice [ (suc n * m) == (m + (n * m))
				, (suc n * m) == ((n * m) + m)
				]
		    ]

	verifyDivSuc ds =
	    verify ["n","m"] $ \(@@) zero suc (==) choice -> do
		minus <- primNatMinus
		let x - y      = minus @@ x @@ y
		    divSuc x y = ds @@ x @@ y
		    m	       = Var 0 []
		    n	       = Var 1 []

		divSuc  zero   m == zero
		divSuc (suc n) m == suc (divSuc (n - m) m)

	verifyModSuc ms =
	    verify ["n","m"] $ \(@@) zero suc (==) choice -> do
		minus <- primNatMinus
		let x - y      = minus @@ x @@ y
		    modSuc x y = ms @@ x @@ y
		    m	       = Var 0 []
		    n	       = Var 1 []
		modSuc  zero   m == zero
		modSuc (suc n) m == modSuc (n - m) m

	verifyEquals eq =
	    verify ["n","m"] $ \(@@) zero suc (===) choice -> do
	    true  <- primTrue
	    false <- primFalse
	    let x == y = eq @@ x @@ y
		m      = Var 0 []
		n      = Var 1 []
	    (zero  == zero ) === true
	    (suc n == suc m) === (n == m)
	    (suc n == zero ) === false
	    (zero  == suc n) === false

	verifyLess leq =
	    verify ["n","m"] $ \(@@) zero suc (===) choice -> do
	    true  <- primTrue
	    false <- primFalse
	    let x < y = leq @@ x @@ y
		m     = Var 0 []
		n     = Var 1 []
	    (n     < zero)  === false
	    (suc n < suc m) === (n < m)
	    (zero  < suc m) === true

	verify :: [String] -> ( (Term -> Term -> Term) -> Term -> (Term -> Term) ->
				(Term -> Term -> TCM ()) ->
				([TCM ()] -> TCM ()) -> TCM a) -> TCM a
	verify xs f = do
	    nat	 <- El (Type 0) <$> primNat
	    zero <- primZero
	    s    <- primSuc
	    let x @@ y = x `apply` [Arg NotHidden y]
		x == y = noConstraints $ equalTerm nat x y
		suc n  = s @@ n
		choice = foldr1 (\x y -> x `catchError` \_ -> y)
	    xs <- mapM freshName_ xs
	    addCtxs xs nat $ f (@@) zero suc (==) choice

-- | Bind a builtin thing to an expression.
bindBuiltin :: String -> A.Expr -> TCM ()
bindBuiltin b e = do
    top <- null <$> getContextTelescope
    unless top $ typeError $ BuiltinInParameterisedModule b
    bind b e
    where
	bind b e
	    | elem b builtinTypes		 = bindBuiltinType b e
	    | elem b [builtinTrue, builtinFalse] = bindBuiltinBool b e
	    | elem b [builtinList, builtinIO]	 = bindBuiltinType1 b e
	    | b == builtinNil			 = bindBuiltinNil e
	    | b == builtinCons			 = bindBuiltinCons e
	    | b == builtinZero			 = bindBuiltinZero e
	    | b == builtinSuc			 = bindBuiltinSuc e
	    | Just (s,v) <- lookup b builtinPrimitives =
		bindBuiltinPrimitive s b e v
	    | b == builtinEquality		 = bindBuiltinEqual e
	    | b == builtinRefl			 = bindBuiltinRefl e
	    | otherwise				 = typeError $ NoSuchBuiltinName b

---------------------------------------------------------------------------
-- * To be moved somewhere else
---------------------------------------------------------------------------

buildLam :: [Arg String] -> Term -> Term
buildLam xs t = foldr (\ (Arg h x) t -> Lam h (Abs x t)) t xs


