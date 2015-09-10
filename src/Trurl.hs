{-# LANGUAGE OverloadedStrings #-}

module Trurl where

import GHC.Exts
import System.Directory
import System.FilePath
import Network.HTTP.Conduit
import Codec.Archive.Tar
import Data.List hiding (find)
import Text.Hastache
import Text.Hastache.Context
import Data.Aeson
import Data.Scientific
import Data.String.Utils
import System.FilePath.Find (find, always, fileName, extension, (==?), liftOp)
import Safe

import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Lazy.IO as TL
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC8
import qualified Data.HashMap.Strict as HM

constProjectName :: String
constProjectName = "ProjectName"

mainRepoFile :: String
mainRepoFile = "mainRepo.tar"

mainRepo :: String
mainRepo = "https://github.com/dbushenko/trurl/raw/master/repository/" ++ mainRepoFile

templateExt :: String
templateExt = ".template"

getLocalRepoDir :: IO String
getLocalRepoDir = do
  home <- getHomeDirectory
  return $ home ++ "/.trurl/repo/"

printFile :: FilePath -> FilePath -> IO ()
printFile dir fp = do
  file <- readFile (dir ++ fp)
  putStrLn file

printFileHeader :: FilePath -> FilePath -> IO ()
printFileHeader dir fp = do
  file <- readFile (dir ++ fp)
  putStrLn $ headDef "No info found..." $ lines file

processTemplate :: String -> String -> String -> IO ()
processTemplate projName paramsStr filePath  = do
  template <- T.readFile filePath
  generated <- hastacheStr defaultConfig template (mkProjContext projName paramsStr)
  TL.writeFile (dropExtension filePath) generated
  removeFile filePath
  return ()

getFileName :: FilePath -> FilePath
getFileName template =
  if hasExtension template
    then template
    else template <.> "hs"

getFullFileName :: String -> String -> String
getFullFileName repoDir template = repoDir ++ getFileName template

mkVariable :: Monad m => Value -> MuType m
mkVariable (String s) = MuVariable s
mkVariable (Bool b) = MuBool b
mkVariable (Number n) = let e = floatingOrInteger n
                            mkval (Left r) = MuVariable (r :: Double)
                            mkval (Right i) = MuVariable (i :: Integer)
                        in mkval e

mkVariable (Array ar) = mkMuList (toList ar)
mkVariable o@(Object _) = mkMuList [o]
mkVariable Null = MuVariable ("" :: String)

mkMuList :: Monad m => [Value] -> MuType m
mkMuList = MuList . map aesonContext

aesonContext :: Monad m => Value -> MuContext m
aesonContext obj  =
  case obj of
    Object o -> mkStrContext $ \k -> mkVariable $ HM.lookupDefault Null (T.pack k) o
    _        -> const $ return $ mkVariable Null

mkContext :: Monad m => String -> MuContext m
mkContext paramsStr =
  case decode $ BLC8.pack paramsStr of
    Nothing  -> const $ return $ mkVariable Null
    Just obj -> aesonContext obj

mkProjContext :: Monad m => String -> String -> MuContext m
mkProjContext projName paramsStr =
  assoc "ProjectName" projName $ mkContext paramsStr

mkFileContext :: Monad m => String -> String -> MuContext m
mkFileContext fileName paramsStr =
  assoc "FileName" fileName $ mkContext paramsStr

assoc :: Monad m => String -> String -> MuContext m -> MuContext m
assoc newKey newVal oldCtx k =
  if decodeStr k == newKey
    then return $ MuVariable newVal
    else oldCtx k

-------------------------------------
-- API
--

-- Команда "update"
-- 1) Создать $HOME/.trurl/repo
-- 2) Забрать из репозитория свежий tar-архив с апдейтами
-- 3) Распаковать его в $HOME/.trurl/repo
--
updateFromRepository :: IO ()
updateFromRepository = do
  repoDir <- getLocalRepoDir
  createDirectoryIfMissing True repoDir
  let tarFile = repoDir ++ mainRepoFile
  simpleHttp mainRepo >>= BL.writeFile tarFile
  extract repoDir tarFile
  removeFile tarFile

-- Команда "create <name> <project> [parameters]"
-- 1) Найти в $HOME/.trurl/repo архив с именем project.tar
-- 2) Создать директорию ./name
-- 3) Распаковать в ./name содержимое project.tar
-- 4) Найти все файлы с расширением ".template"
-- 5) Отрендерить эти темплейты c учетом переданных parameters
-- 6) Сохранить отрендеренные файлы в новые файлы без ".template"
-- 7) Удалить все файлы с расширением ".template"
-- 8) Найти все файлы с именем ProjectName независимо от расширения
-- 9) Переименовать эти файлы в соотествии с указанным ProjectName
--
createProject :: String -> String -> String -> IO ()
createProject name project paramsStr = do
  -- Extract the archive
  repoDir <- getLocalRepoDir
  createDirectoryIfMissing True name
  extract name $ repoDir ++ project ++ ".tar"

  -- Process all templates
  templatePaths <- find always (extension ==? templateExt) name
  mapM_ (processTemplate name paramsStr) templatePaths

  -- Find 'ProjectName' files
  let checkFileName fname templname = isInfixOf templname fname
  projNamePaths <- find always (liftOp checkFileName fileName constProjectName) name

  -- Rename 'ProjectName' files
  let renameProjNameFile fpath = let (fdir, fname) = splitFileName fpath
                                     newfname = replace constProjectName name fname
                                 in renameFile fpath (fdir ++ newfname)
  mapM_ renameProjNameFile projNamePaths


-- Команда "new <file> [parameters]"
-- 1) Найти в $HOME/.trurl/repo архив с именем file.hs.
--    Если имя файла передано с расширением, то найти точное имя файла, не подставляя *.hs
-- 2) Прочитать содержимое шаблона
-- 3) Отрендерить его с применением hastache и переданных параметров
-- 4) Записать файл в ./
--
newTemplate :: String -> String -> String -> IO ()
newTemplate name templateName paramsStr = do
  repoDir <- getLocalRepoDir
  let templPath = getFullFileName repoDir templateName
  template <- T.readFile templPath
  generated <- hastacheStr defaultConfig template (mkFileContext name paramsStr)
  TL.writeFile (getFileName name) generated

-- Команда "list"
-- 1) Найти все файлы с расширением '.metainfo'
-- 2) Для каждого найденного файла вывести первую строчку
--
listTemplates :: IO ()
listTemplates = do
  repoDir <- getLocalRepoDir
  files <- getDirectoryContents repoDir
  let mpaths = filter (endswith ".metainfo") files
  mapM_ (printFileHeader repoDir) mpaths

-- Команда "help <template>"
-- 1) Найти указанный файл с расширением '.metainfo'
-- 2) Вывести его содержимое
--
helpTemplate :: String -> IO ()
helpTemplate template = do
  repoDir <- getLocalRepoDir
  templExists <- doesFileExist $ repoDir ++ template ++ ".metainfo"
  if templExists then printFile repoDir $ template ++ ".metainfo"
  else printFile repoDir ((getFileName template) ++ ".metainfo")
