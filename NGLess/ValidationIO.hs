{- Copyright 2013-2016 NGLess Authors
 - License: MIT
 -}

{-# LANGUAGE OverloadedStrings #-}
module ValidationIO
    ( validateIO
    ) where

import System.Directory
import System.FilePath.Posix (takeDirectory)
import Data.Maybe
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Reader
import Control.Monad.Trans.Writer
import qualified Data.Text as T

import Modules
import Language
import NGLess
import ReferenceDatabases


type ValidateIO = WriterT [T.Text] (ReaderT [Module] NGLessIO)
tell1 = tell . (:[])

validateIO :: [Module] -> Script -> NGLessIO (Maybe [T.Text])
validateIO mods sc = do
        err <- runReaderT (execWriterT (mapM ($sc) checks)) mods
        case err of
            [] -> return Nothing
            errors -> return (Just errors)
    where
        checks =
            [validate_files
            ,validate_write_output
            ,validate_def_genomes
            ]


-- | check that necessary files exist
validate_files :: Script -> ValidateIO ()
validate_files (Script _ es) = check_toplevel validate_files' es
    where
        validate_files' (FunctionCall (FuncName "fastq") f _ _) = check f
        validate_files' (FunctionCall (FuncName "paired") f args _) = check f >> validateArg check_can_read_file "second" args es
        validate_files' (FunctionCall (FuncName "annotate") _ args _) = validateArg check_can_read_file "gff" args es
        validate_files' (Assignment _ e) = validate_files' e
        validate_files' _ = return ()

        check (ConstStr fname) = check_can_read_file fname
        check (Lookup var) = validateVar check_can_read_file var es
        check _ = return ()

validate_def_genomes :: Script -> ValidateIO ()
validate_def_genomes (Script _ es) = check_toplevel validate_def_genomes' es
    where
        validate_def_genomes' (FunctionCall (FuncName "map") _ args _) = validateArg check_reference "reference" args es
                                                                            >> validateArg check_fafile "fafile" args es
        validate_def_genomes' (Assignment _ e) = validate_def_genomes' e
        validate_def_genomes' _ = return ()


validateArg :: (T.Text -> ValidateIO ()) -> T.Text -> [(Variable,Expression)] -> [(Int,Expression)] -> ValidateIO ()
validateArg f v args es = case lookup (Variable v) args of
        Just (ConstStr x) -> f x
        Just (Lookup   x) -> validateVar f x es
        _                 -> return ()

validateVar :: (T.Text -> ValidateIO ()) -> Variable -> [(Int,Expression)] -> ValidateIO ()
validateVar f v es = case get_const_val v es of
            Right (Just (NGOString t))  -> f t
            Left  err       -> tell1 err
            _               -> return ()
    where

get_const_val :: Variable -> [(Int,Expression)] -> Either T.Text (Maybe NGLessObject)
get_const_val var s = do
        let r = mapMaybe (getAssignment . snd) s
        case r of
            [] -> Left (T.concat ["Variable: ", T.pack . show $ var, "was never assigned to a value."])
            [val] -> Right . Just $ val
            _ -> Right Nothing -- do not validate
    where
        getAssignment :: Expression -> Maybe NGLessObject
        getAssignment (Assignment v val) | v == var = getConst val
        getAssignment _ = Nothing
        getConst (ConstStr t) = Just $ NGOString t
        getConst (ConstSymbol t) = Just $ NGOSymbol t
        getConst (ConstInt v) = Just $ NGOInteger v
        getConst (ConstDouble v) = Just $ NGODouble v
        getConst (ConstBool b) = Just $ NGOBool b
        getConst _ = Nothing


check_toplevel :: (Expression -> ValidateIO ()) -> [(Int,Expression)] -> ValidateIO ()
check_toplevel f es = forM_ es $ \(lno, e) ->
        censor (addLno lno) $ f e
    where
        addLno lno = map (addLno1 lno)
        addLno1 lno err = T.concat ["Line ", T.pack (show lno), ": ", err]


check_can_read_file :: T.Text -> ValidateIO ()
check_can_read_file fname = do
    let fname' = T.unpack fname
    r <- liftIO $ doesFileExist fname'
    if not r
        then tell1 $ T.concat ["File `", fname, "` does not exist."]
        else do
            p <- liftIO $ getPermissions fname'
            unless (readable p) $
                tell1 (T.concat ["File `", fname, "` is not readable (permissions problem)."])

check_reference :: T.Text -> ValidateIO ()
check_reference r
    | isDefaultReference (T.unpack r)  = return ()
    | otherwise = do
        mods <- ask
        let refs = concatMap modReferences mods
        unless (any ((==r) . refName) refs) $
            tell1 (T.concat ["Could not find reference ", r, " (it is neither built in nor in any of the loaded modules)"])

check_fafile fafile = do
        r <- liftIO $ doesFileExist (T.unpack fafile)
        unless r $
            tell1 (T.concat ["map function expects a file in argument 'fafile', got ", fafile, ", which is not the name of a file."])

validate_write_output (Script _ es) = check_toplevel validate_write es
    where
        validate_write (FunctionCall (FuncName "write") _ args _) = validateArg check_can_write_dir "ofile" args es
        validate_write _ = return ()

check_can_write_dir :: T.Text -> ValidateIO ()
check_can_write_dir ofile = do
    let dirname = takeDirectory (T.unpack ofile)
    exists <- liftIO $ doesDirectoryExist dirname
    if not exists
        then tell1 $ T.concat ["write call to file ", ofile, ", but directory ", T.pack dirname, " does not exist."]
        else do
            canWrite <- liftIO $ writable <$> getPermissions dirname
            unless canWrite $
                tell1 (T.concat ["write call to file ", ofile, ", but directory ", T.pack dirname, " is not writable."])
