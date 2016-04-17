{- Copyright 2013-2016 NGLess Authors
 - License: MIT
 -}

module Language
    ( Expression(..)
    , OptimizedExpression(..)
    , Variable(..)
    , UOp(..)
    , BOp(..)
    , Index(..)
    , Block(..)
    , FuncName(..)
    , MethodName(..)
    , NGLType(..)
    , ReadSet(..)
    , Header(..)
    , ModInfo(..)
    , Script(..)
    , NGLessObject(..)
    , methodSelfType
    , methodArgType
    , methodReturnType
    , methodKwargType
    , recursiveAnalyse
    , recursiveTransform
    , typeOfConstant
    ) where

{- This module defines the internal representation the language -}
import qualified Data.Text as T
import Control.Monad

import Data.FastQ
import Data.Sam

newtype Variable = Variable T.Text
    deriving (Eq, Ord, Show)

newtype FuncName = FuncName { unwrapFuncName :: T.Text }
    deriving (Eq, Ord)

instance Show FuncName where
    show (FuncName f) = T.unpack f

data MethodName =
        Mflag
        | Mfilter
        | Mpe_filter
        | Munique
    deriving (Eq, Ord, Show)


-- | method name -> ((method self type, method first argtype if any), method return type)
methodArgTypeReturnType :: MethodName -> ((NGLType, Maybe NGLType), NGLType)
methodArgTypeReturnType Mflag = ((NGLMappedRead, Just NGLSymbol), NGLBool)
methodArgTypeReturnType Mpe_filter = ((NGLMappedRead, Nothing), NGLMappedRead)
methodArgTypeReturnType Mfilter = ((NGLMappedRead, Nothing), NGLMappedRead)
methodArgTypeReturnType Munique = ((NGLMappedRead, Nothing), NGLMappedRead)

methodSelfType :: MethodName -> NGLType
methodSelfType = fst . fst . methodArgTypeReturnType

methodArgType :: MethodName -> (Maybe NGLType)
methodArgType = snd . fst. methodArgTypeReturnType

methodReturnType :: MethodName -> NGLType
methodReturnType = snd . methodArgTypeReturnType

methodKwargType :: MethodName -> Variable -> NGLType
methodKwargType Mfilter (Variable "min_identity_pc") = NGLInteger
methodKwargType _ _ = NGLVoid

typeOfConstant :: T.Text -> Maybe NGLType
typeOfConstant "STDIN"        = Just NGLString
typeOfConstant "STDOUT"       = Just NGLString
typeOfConstant _              = Nothing

-- | unary operators
data UOp = UOpLen | UOpMinus | UOpNot
    deriving (Eq, Ord, Show)

-- | binary operators
data BOp = BOpAdd | BOpMul | BOpGT | BOpGTE | BOpLT | BOpLTE | BOpEQ | BOpNEQ
    deriving (Eq, Ord, Show)

-- | index expression encodes what is inside an index variable
-- either [a] (IndexOne) or [a:b] (IndexTwo)
data Index = IndexOne Expression
            | IndexTwo (Maybe Expression) (Maybe Expression)
    deriving (Eq, Ord, Show)

-- | a block is
--  f(a) using |inputvariables|:
--      expression
data Block = Block
                { blockVariable :: [Variable] -- ^ input arguments
                , blockBody :: Expression -- ^ block body, will likely be Sequence
                }
    deriving (Eq, Ord, Show)

data NGLType =
        NGLString
        | NGLInteger
        | NGLDouble
        | NGLBool
        | NGLSymbol
        | NGLFilename
        | NGLRead
        | NGLReadSet
        | NGLMappedRead
        | NGLMappedReadSet
        | NGLCounts
        | NGLVoid
        | NGLAny
        | NGList !NGLType
    deriving (Eq, Show)

data ReadSet =
        ReadSet1 FastQEncoding FilePath -- ^ encoding file_on_disk
        | ReadSet2 FastQEncoding FilePath FilePath -- ^ encoding file_on_disk
        | ReadSet3 FastQEncoding FilePath FilePath FilePath-- ^ encoding file_on_disk
        deriving (Eq, Show, Ord)

data NGLessObject =
        NGOString T.Text
        | NGOBool Bool
        | NGOInteger Integer
        | NGODouble Double
        | NGOSymbol T.Text
        | NGOFilename FilePath
        | NGOShortRead ShortRead
        | NGOReadSet T.Text ReadSet
        | NGOMappedReadSet
                    { nglgroupName :: T.Text
                    , nglSamFile :: FilePath
                    , nglReference :: Maybe T.Text
                    }
        | NGOMappedRead [SamLine]
        | NGOCounts FilePath
        | NGOVoid
        | NGOList [NGLessObject]
        | NGOExpression Expression
    deriving (Eq, Show, Ord)


-- | 'Expression' is the main type for holding the AST.

data Expression =
        Lookup Variable -- ^ This looks up the variable name
        | ConstStr T.Text -- ^ constant string
        | ConstInt Integer -- ^ integer
        | ConstDouble Double -- ^ integer
        | ConstBool Bool -- ^ true/false
        | ConstSymbol T.Text -- ^ a symbol
        | BuiltinConstant Variable -- ^ built-in constant
        | ListExpression [Expression] -- ^ a list
        | Continue -- ^ continue
        | Discard -- ^ discard
        | UnaryOp UOp Expression  -- ^ op ( expr )
        | BinaryOp BOp Expression Expression -- ^ expr bop expr
        | Condition Expression Expression Expression -- ^ if condition: true-expr else: false-expr
        | IndexExpression Expression Index -- ^ expr [ index ]
        | Assignment Variable Expression -- ^ var = expr
        | FunctionCall FuncName Expression [(Variable, Expression)] (Maybe Block)
        | MethodCall MethodName Expression (Maybe Expression) [(Variable, Expression)] -- ^ expr.method(expre)
        | Sequence [Expression]
        | Optimized OptimizedExpression -- This is a special case, used internally
    deriving (Eq, Ord)

data OptimizedExpression =
        LenThresholdDiscard Variable BOp Int -- if len(r) <op> <int>: discard
        | SubstrimReassign Variable Int -- r = substrim(r, min_quality=<int>)
    deriving (Eq, Ord, Show)

instance Show Expression where
    show (Lookup (Variable v)) = "Lookup '"++T.unpack v++"'"
    show (ConstStr t) = show t
    show (ConstInt n) = show n
    show (ConstDouble f) = show f
    show (ConstBool b) = show b
    show (ConstSymbol t) = "{"++T.unpack t++"}"
    show (BuiltinConstant (Variable v)) = T.unpack v
    show (ListExpression e) = show e
    show Continue = "continue"
    show Discard = "discard"
    show (UnaryOp UOpLen a) = "len("++show a++")"
    show (UnaryOp op a) = show op ++ " " ++ show a
    show (BinaryOp op a b) = show a ++ show op ++ show b
    show (Condition c a b) = "if ["++show c ++"] then {"++show a++"} else {"++show b++"}"
    show (IndexExpression a ix) = show a ++ "[" ++ show ix ++ "]"
    show (Assignment (Variable v) a) = T.unpack v++" = "++show a
    show (FunctionCall fname a args block) = show fname ++ "(" ++ show a ++ showArgs args ++ ")"
                                    ++ (case block of
                                        Nothing -> ""
                                        Just b -> "using {"++show b ++ "}")
    show (MethodCall mname self a args) = "(" ++ show self ++ ")." ++ show mname ++ "( " ++ show a ++ showArgs args ++ " )"
    show (Sequence e) = "Sequence " ++ show e
    show (Optimized se) = "Optimized (" ++ show se ++ ")"

-- 'recursiveAnalyse f e' will call the function 'f' for all the subexpression inside 'e'
recursiveAnalyse :: (Monad m) => (Expression -> m ()) -> Expression -> m ()
recursiveAnalyse f e = f e >> recursiveAnalyse' e
    where
        rf = recursiveAnalyse f
        recursiveAnalyse' (ListExpression es) = mapM_ rf es
        recursiveAnalyse' (UnaryOp _ eu) = rf eu
        recursiveAnalyse' (BinaryOp _ e1 e2) = rf e1 >> rf e2
        recursiveAnalyse' (Condition cE tE fE) = rf cE >> rf tE >> rf fE
        recursiveAnalyse' (IndexExpression ei _) = rf ei
        recursiveAnalyse' (Assignment _ ea) =  rf ea
        recursiveAnalyse' (FunctionCall _ ef args block) = rf ef >> mapM_ rf (snd <$> args) >> maybe (return ()) (rf . blockBody) block
        recursiveAnalyse' (MethodCall _ em eargs args) = rf em >> maybe (return ()) rf eargs >> mapM_ rf (snd <$> args)
        recursiveAnalyse' (Sequence es) =  mapM_ rf es
        recursiveAnalyse' _ = return ()

-- 'recursiveTransform' calls 'f' for every sub-expression in its argument,
-- 'f' will get called with expression where the sub-expressions have already been replaced!
recursiveTransform :: (Monad m) => (Expression -> m Expression) -> Expression -> m Expression
recursiveTransform f e = f =<< recursiveTransform' e
    where
        rf = recursiveTransform f
        recursiveTransform' (ListExpression es) = ListExpression <$> mapM rf es
        recursiveTransform' (UnaryOp op eu) = UnaryOp op <$> rf eu
        recursiveTransform' (BinaryOp op e1 e2) = BinaryOp op <$> rf e1 <*> rf e2
        recursiveTransform' (Condition cE tE fE) = Condition <$> rf cE <*> rf tE <*> rf fE
        recursiveTransform' (IndexExpression ei ix) = flip IndexExpression ix <$> rf ei
        recursiveTransform' (Assignment v ea) = Assignment v <$> rf ea
        recursiveTransform' (FunctionCall fname ef args block) = FunctionCall fname
                                    <$> rf ef
                                    <*> forM args (\(n,av) -> (n,) <$> rf av)
                                    <*> forM block (\(Block vars body) -> Block vars <$> rf body)
        recursiveTransform' (MethodCall mname em earg args) = MethodCall mname
                                    <$> rf em
                                    <*> forM earg rf
                                    <*> forM args (\(n, av) -> (n,) <$> rf av)
        recursiveTransform' (Sequence es) = Sequence <$> mapM rf es
        recursiveTransform' esimple = return esimple


showArgs [] = ""
showArgs ((Variable v, e):args) = "; "++T.unpack v++"="++show e++showArgs args

data ModInfo = ModInfo
    { modName :: !T.Text
    , modVersion :: !T.Text
    } deriving (Eq, Show)

data Header = Header
    { nglVersion :: T.Text
    , nglModules :: [ModInfo]
    } deriving (Eq, Show)

-- | Script is a version declaration followed by a series of expressions
data Script = Script
    { nglHeader :: Maybe Header -- ^ optional if -e option is used
    , nglBody :: [(Int,Expression)] -- ^ (line number, expression)
    } deriving (Eq,Show)

