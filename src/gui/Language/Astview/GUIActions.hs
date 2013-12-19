{- contains the GUIActions connected to menuItems
 -
 -}

module Language.Astview.GUIActions where

-- gui data types
import Language.Astview.GUIData 

-- base
import Prelude hiding (writeFile)
import Data.List (find)
import Control.Monad (when,unless,void,zipWithM_)
import Data.Char (toLower)
-- io
import System.IO (withFile,IOMode(..),hPutStr,hClose)

-- filepath
import System.FilePath (takeExtension,takeFileName)

-- bytestring
import qualified Data.ByteString.Char8 as BS (hGetContents,unpack)

-- containers
import Data.Tree ( Tree(Node) )

-- gtk
import Graphics.UI.Gtk hiding (Language,get,response,bufferChanged) 

-- gtksourceview
import Graphics.UI.Gtk.SourceView 

import Language.Astview.Language 
import Language.Astview.SourceLocation 

-- |unsaved document
unsavedDoc :: String
unsavedDoc = "Unsaved document"

-- | a list of pairs of gtk-ids and GUIActions 
menuActions :: [(String,AstAction ())]
menuActions = 
  [("mNew",actionEmptyGUI)
  ,("mReparse",actionReparse)
  ,("mSaveAs",actionSaveAs)
  ,("mOpen",actionDlgOpen)
  ,("mSave",actionSave)
  ,("mCut",actionCutSource)
  ,("mCopy",actionCopySource)
  ,("mPaste",actionPasteSource)
  ,("mDelete",actionDeleteSource)
  ,("mSrcLoc",actionJumpToSrcLoc)
  ,("mTextLoc",actionJumpToTextLoc)
  ,("mAbout",actionAbout)
  ,("mQuit",actionQuit)
  ]


-- -------------------------------------------------------------------
-- * filemenu menu actions
-- -------------------------------------------------------------------

clearTreeView :: TreeView -> IO ()
clearTreeView t = do
  c <- treeViewGetColumn t 0
  case c of 
    Just col-> treeViewRemoveColumn t col
    Nothing -> return 0 
  return ()

-- | resets the GUI, 
actionEmptyGUI :: AstAction ()
actionEmptyGUI ref = do
  g <- getGui ref
  clearTreeView =<< getTreeView ref
  flip textBufferSetText [] =<< getSourceBuffer ref
  windowSetTitleSuffix (window g) unsavedDoc

-- | updates the sourceview with a given file, chooses a language by 
-- extension and parses the file
actionLoadHeadless :: FilePath -> AstAction ()
actionLoadHeadless file ref = do
  setcFile file ref
  s <- getAstState ref

  windowSetTitleSuffix 
    (window $ gui s) 
    (takeFileName file)
  contents <- withFile 
    file ReadMode (fmap BS.unpack . BS.hGetContents)
  buffer <- getSourceBuffer ref 
  textBufferSetText buffer contents
  deleteStar ref
  whenJustM
    (getLanguage ref) $
    \l -> void $ actionParse l ref 

-- |tries to find a language based on the extension of 
-- current file name
getLanguage :: AstAction (Maybe Language)
getLanguage ref = do
  file <- getFile ref
  langs <- getLangs ref
  return $ find (elem (takeExtension file) . exts) langs


actionGetAst :: Language -> AstAction (Either Error Ast)
actionGetAst l ref = fmap (parse l) . getText =<< getSourceBuffer ref 

-- | parses the contents of the sourceview with the selected language
actionParse :: Language -> AstAction (Tree String) 
actionParse l ref = do
  buffer <- getSourceBuffer ref
  view <- getTreeView ref
  sourceBufferSetHighlightSyntax buffer True
  setupSyntaxHighlighting buffer l
  plain <- getText buffer
  clearTreeView view
  let ast = buildAst l plain 
  model <- treeStoreNew [ast]
  treeViewSetModel view model
  col <- treeViewColumnNew
  renderer <- cellRendererTextNew
  cellLayoutPackStart col renderer True 
  cellLayoutSetAttributes 
    col 
    renderer 
    model 
    (\row -> [ cellText := row ] )
  treeViewAppendColumn view col 
  return ast

-- |given a language and input string buildAst constructs the tree
--which will be presented by our gtk-treeview
buildAst :: Language -> String -> Tree String
buildAst l s =
  case parse l s of
     Left Err                  -> Node "Parse error" []
     Left (ErrMessage m)       -> Node m []
     Left (ErrLocation pos message) -> 
         Node ("Parse error at:"++show pos++": "++message) [] 
     Right (Ast ast)       -> fmap label  ast
    
-- |uses the name of given language to establish syntax highlighting in 
-- source buffer
setupSyntaxHighlighting :: SourceBuffer -> Language -> IO ()
setupSyntaxHighlighting buffer language = do
  langManager <- sourceLanguageManagerGetDefault
  maybeLang <- sourceLanguageManagerGetLanguage 
        langManager 
        (map toLower $ syntax language)
  case maybeLang of
    Just lang -> do
      sourceBufferSetHighlightSyntax buffer True
      sourceBufferSetLanguage buffer (Just lang) 
    Nothing -> sourceBufferSetHighlightSyntax buffer False   

-- |saves current file if a file is active or calls "save as"-dialog
actionSave :: AstAction ()
actionSave ref = do
  file <- getFile ref
  text <- getText =<< getSourceBuffer ref
  case file of
    "Unsaved document"  -> actionDlgSave ref
    _                   -> do 
      deleteStar ref 
      writeFile file text 

-- |sets up a simple filechooser dialog, whose response to Ok 
-- is given by argument function
actionMkDialog :: FileChooserAction -> (FileChooserDialog  -> t -> IO ()) -> t -> IO()
actionMkDialog fileChooser actionOnOkay ref = do
  dia <- fileChooserDialogNew 
    (Just "astview") 
    Nothing 
    fileChooser 
    []

  zipWithM_ (dialogAddButton dia) [stockCancel   ,stockOpen] 
                                  [ResponseCancel,ResponseOk]

  widgetShowAll dia
  response <- dialogRun dia
  case response of 
    ResponseCancel -> return ()
    ResponseOk     -> actionOnOkay dia ref
    _ -> return ()
  widgetHide dia

-- |lanches the "save as"-dialog
actionSaveAs :: AstAction ()
actionSaveAs = actionMkDialog FileChooserActionSave onOkay where
  onOkay dia ref = do
    maybeFile <- fileChooserGetFilename dia 
    case maybeFile of
       Nothing-> return () 
       Just file -> do
         setcFile file ref
         writeFile file =<< getText =<< getSourceBuffer ref

-- |removes @*@ from window title if existing and updates state
deleteStar :: AstAction ()
deleteStar ref = do
  w <- getWindow ref
  t <- windowGetTitle w
  bufferChanged <- getChanged ref
  when bufferChanged (windowSetTitle w (tail t))
  setChanged False ref
 
-- -------------------------------------------------------------------
-- ** editmenu menu actions
-- -------------------------------------------------------------------

-- |moves selected source to clipboard (cut)
actionCutSource :: AstAction ()  
actionCutSource ref = do
  actionCopySource ref 
  actionDeleteSource ref 
  return ()

-- |copies selected source to clipboard  
actionCopySource :: AstAction () 
actionCopySource ref = do
  buffer <- getSourceBuffer ref
  (start,end) <- textBufferGetSelectionBounds buffer 
  clipBoard <- clipboardGet selectionClipboard
  clipboardSetText clipBoard =<< textBufferGetText buffer start end True

-- |pastes text from clipboard at current cursor position  
actionPasteSource :: AstAction ()
actionPasteSource ref = do 
  buffer <- getSourceBuffer ref
  clipBoard <- clipboardGet selectionClipboard
  clipboardRequestText clipBoard (insertAt buffer) where
    insertAt :: SourceBuffer -> Maybe String -> IO ()
    insertAt buff m = whenJust m (textBufferInsertAtCursor buff)

-- |deletes selected source
actionDeleteSource :: AstAction ()
actionDeleteSource ref = void $ do
  buffer <- getSourceBuffer ref
  textBufferDeleteSelection buffer False False 

-- |launches a dialog which displays the text position associated to
-- last clicked tree node.
actionJumpToTextLoc :: AstAction ()
actionJumpToTextLoc ref = do
  maybeLang <- getLanguage ref
  case maybeLang of
    Nothing -> return () 
    Just lang -> do 
      astOrError <- actionGetAst lang ref 
      case astOrError of
        Left _    -> return () 
        Right (Ast ast) -> do
          gtkPath <- getPath ref
          let astPath = tail gtkPath
              loc = ast `at` astPath 
          showDialogSrcLoc loc 

-- |launches a dialog which displays the text position associated to
-- last clicked tree node.
showDialogSrcLoc :: Maybe SrcLocation -> IO ()
showDialogSrcLoc mbSrcLoc= do
  let message = case mbSrcLoc of
        Nothing -> "No matching source location found."
        Just loc -> "Selected tree represents text position "++ show loc++"."
  dia <- messageDialogNew Nothing [] MessageInfo ButtonsOk message 
  dialogRun dia
  widgetHide dia
      

at :: Tree AstNode -> TreePath -> Maybe SrcLocation 
at (Node n _ )  []     = srcloc n
at (Node _ cs) (i:is)  = cs!!i `at` is

-- |returns the current cursor position in a source view.
-- return type: (line,row)
getCursorPosition :: AstAction CursorSelection 
getCursorPosition ref = do
  (startIter,endIter) <- textBufferGetSelectionBounds =<< getSourceBuffer ref
  lineStart <- textIterGetLine startIter 
  rowStart <- textIterGetLineOffset startIter 
  lineEnd <- textIterGetLine endIter  
  rowEnd <- textIterGetLineOffset endIter 
  return $ CursorSelection (lineStart+1) (rowStart+1) (lineEnd+1) (rowEnd+1)

-- |opens tree position associated with current cursor position.
-- Right now we are picking the first path in the list, but there
-- should be some kind of user interaction.
actionJumpToSrcLoc :: AstAction ()
actionJumpToSrcLoc ref = do
  treePaths <- actionGetAssociatedPaths ref 
  putStrLn $ "Matching results: "++ show treePaths
  case fmap toList treePaths of
    Just ((_,p):_)  -> activatePath p ref
    _               -> return ()

-- |returns the paths in tree which are associated with the
-- current selected source location.
actionGetAssociatedPaths :: AstAction (Maybe PathList)
actionGetAssociatedPaths ref = do  
  sele <- getCursorPosition ref 
  maybeLang <- getLanguage ref
  case maybeLang of
    Nothing -> return Nothing
    Just lang -> do 
      astOrError <- actionGetAst lang ref 
      case astOrError of
        Left _    -> return Nothing 
        Right ast -> do
           putStrLn $ show sele ++ " selected"
           return $ Just $ select sele ast 


-- |select tree path 
activatePath :: TreePath -> AstAction ()
activatePath p ref = do 
  view <- getTreeView ref
  treeViewExpandToPath view p
  treeViewSetCursor view p Nothing

-- -------------------------------------------------------------------
-- ** helpmenu menu actions
-- -------------------------------------------------------------------

-- | launches info dialog
actionAbout :: AstAction ()
actionAbout ref = do
  dlg <- fmap dlgAbout (getGui ref)
  aboutDialogSetUrlHook (\_ -> return ())
  widgetShow dlg

-- -------------------------------------------------------------------
-- ** other actions 
-- -------------------------------------------------------------------

-- | adds '*' to window title if file changed and sets state
actionBufferChanged :: AstAction ()
actionBufferChanged ref = do
  w <- fmap window (getGui ref)
  t <- windowGetTitle w 
  c <- getChanged ref
  unless c (windowSetTitle w ('*':t))
  setChanged True ref

-- | destroys window widget 
actionQuit :: AstAction ()
actionQuit ref = do 
  isChanged <- getChanged ref 
  when isChanged $ actionQuitWorker ref
  widgetDestroy =<< fmap window (getGui ref)


actionQuitWorker :: AstAction ()  
actionQuitWorker ref = do
  dia <- dialogNew
  dialogAddButton dia stockYes ResponseYes
  dialogAddButton dia stockNo ResponseNo
  dialogAddButton dia stockCancel ResponseCancel
  contain <- dialogGetUpper dia

  windowSetTitleSuffix dia "Quit" 
  containerSetBorderWidth dia 2
  file <- getFile ref
  lbl <- labelNew 
    (Just $ "Save changes to document \""++
            takeFileName file ++
            "\" before closing?")
  boxPackStartDefaults contain lbl

  widgetShowAll dia
  response <- dialogRun dia
  case response of 
    ResponseYes   -> actionSave ref
    _             -> return ()
  widgetHide dia


-- | launches open dialog
actionDlgOpen :: AstAction ()
actionDlgOpen = actionMkDialog FileChooserActionOpen onOkay where
  onOkay dia ref = whenJustM (fileChooserGetFilename dia) $ \file -> 
    actionLoadHeadless file ref

-- | launches save dialog
actionDlgSave :: AstAction ()
actionDlgSave = actionMkDialog FileChooserActionSave onOkay where
  onOkay dia ref = do
     maybeFile <- fileChooserGetFilename dia
     case maybeFile of
       Nothing-> return () 
       Just file -> do
          g <- getGui ref
          setChanged False ref
          setcFile file ref
          writeFile file =<< getText =<< getSourceBuffer ref
          windowSetTitle 
            (window g) 
            (takeFileName file)

-- |applies current parser to sourcebuffer 
actionReparse :: AstAction ()
actionReparse ref = 
  whenJustM (getLanguage ref) $ \l -> void $ actionParse l ref 

-- |prints the current selected path to console. Mainly used for 
-- debugging purposes.
actionShowPath :: AstAction ()
actionShowPath ref = actionGetPath ref >>= print

actionGetPath :: AstAction [Int]
actionGetPath ref = do 
  rows <- treeSelectionGetSelectedRows =<< treeViewGetSelection =<< getTreeView ref
  return $ case rows of 
    []    -> [] 
    (p:_) -> p

-- -------------------------------------------------------------------
-- ** Helpers
-- -------------------------------------------------------------------

-- |similar to @when@ 
whenJust :: Monad m => Maybe a -> (a -> m ()) -> m ()
whenJust Nothing _       = return ()
whenJust (Just x) action = action x 
  
-- |similar to @whenJust@, but value is inside a monad
whenJustM :: Monad m => m(Maybe a) -> (a -> m ()) -> m ()
whenJustM val action = do
  m <- val
  maybe (return ()) action m

-- |returns the text in given text buffer
getText :: TextBufferClass c => c -> IO String
getText tb = do
  start <- textBufferGetStartIter tb
  end <- textBufferGetEndIter tb
  textBufferGetText tb start end True

-- |uses the given string to set the title of given window with suffix "-astview"
windowSetTitleSuffix :: WindowClass w => w -> String -> IO ()
windowSetTitleSuffix win title = windowSetTitle win (title++" - astview")
  
-- |safe function to write files
writeFile :: FilePath -> String -> IO ()
writeFile f str = withFile f WriteMode (\h -> hPutStr h str >> hClose h)
