module Language.Boogie.Z3.Eval (evalExpr) where

import           Control.Applicative
import           Control.Lens (uses)
import           Control.Monad

import           Z3.Monad

import           Language.Boogie.AST
import           Language.Boogie.Position
import           Language.Boogie.PrettyAST ()
import           Language.Boogie.TypeChecker
import           Language.Boogie.Z3.GenMonad

-- | Evaluate an expression to a Z3 AST.
evalExpr :: Expression -- ^ Expression to evaluate
         -> Z3Gen AST
evalExpr expr = debug ("evalExpr: " ++ show expr) >>
    case node expr of
      Literal v -> evalValue v
      LogicalVar t ref -> uses refMap (lookup' "evalExpr" (LogicRef t ref))
      MapSelection m args ->
          do m' <- go m
             arg <- tupleArg args
             mkSelect m' arg
      MapUpdate m args val ->
          do m' <- go m
             arg <- tupleArg args
             val' <- go val
             mkStore m' arg val'
      UnaryExpression op e -> go e >>= unOp op
      BinaryExpression op e1 e2 -> join (binOp op <$> go e1 <*> go e2)
      IfExpr c e1 e2 -> join (mkIte <$> go c <*> go e1 <*> go e2)
      e -> error $ "solveConstr.evalExpr: " ++ show e
    where
      evalValue :: Value -> Z3Gen AST
      evalValue v =
          case v of
            IntValue i      -> mkInt i
            BoolValue True  -> mkTrue
            BoolValue False -> mkFalse
            Reference t ref -> uses refMap (lookup' "evalValue" (MapRef t ref))
            CustomValue (IdType ident types) ref ->
                do ctor <- lookupCustomCtor ident types
                   refAst <- mkInt ref
                   mkApp ctor [refAst]
            MapValue _ _    -> error "evalValue: map value found"
            _ -> error $ "evalValue: can't handle value: " ++ show v

      go = evalExpr

      tupleArg :: [Expression] -> Z3Gen AST
      tupleArg es =
          do let ts = map (exprType emptyContext) es
             debug (show ts)
             (_sort, ctor, _projs) <- lookupCtor ts
             es' <- mapM go es
             c <- mkApp ctor es'
             return c

      unOp :: UnOp -> AST -> Z3Gen AST
      unOp Neg = mkUnaryMinus
      unOp Not = mkNot

      binOp :: BinOp -> AST -> AST -> Z3Gen AST
      binOp op =
          case op of
            Eq -> mkEq
            Gt -> mkGt
            Ls -> mkLt
            Leq -> mkLe
            Geq -> mkGe
            Neq -> \ x y -> mkEq x y >>= mkNot

            Plus -> list2 mkAdd
            Minus -> list2 mkSub
            Times -> list2 mkMul
            Div   -> mkDiv
            Mod   -> mkMod

            And   -> list2 mkAnd
            Or    -> list2 mkOr
            Implies -> mkImplies
            Equiv -> mkIff
            Explies -> flip mkImplies
            Lc -> error "solveConstr.binOp: Lc not implemented"
          where list2 o x y = o [x, y]
