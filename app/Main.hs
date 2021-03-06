{-# LANGUAGE TemplateHaskell #-}

module Main where

import Control.DeepSeq
import Control.Exception hiding (TypeError)
import Control.Lens hiding (DefName)
import Control.Lens.Extras
import Control.Monad
import Control.Monad.IO.Class
import Data.Char
import Data.List
import Data.List.HT (viewR)
import Data.Maybe
import Data.Text.Zipper
import System.Environment
import System.Exit
import System.IO.Error
import System.Timeout
import Text.Read
import Brick hiding (Location)
import Brick.Widgets.Border
import Brick.Widgets.Edit
import Safe
import Diff
import Eval
import History
import Primitive
import Util
import qualified Data.Map as Map
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Vector as Vec
import qualified Brick.Types
import qualified Brick.Widgets.List as ListWidget
import qualified Graphics.Vty as Vty
import qualified PrettyPrint
import qualified Expr as E
import qualified Infer
import qualified Pattern as P
import qualified Type as T
import qualified Value as V

data AppState = AppState
    { _committedTypeDefs :: Map.Map TypeDefKey (History TypeDef) -- does not contain changes of any current edit
    , _committedExprDefs :: Map.Map ExprDefKey (History ExprDef) -- does not contain changes of any current edit
    , _committedLocations :: History Location -- does not contain selection changes of any current edit
    , _wrappingStyle :: WrappingStyle
    , _clipboard :: Clipboard
    , _editState :: EditState
    , _editorExtent :: Maybe (Extent AppResourceName)
    , _derivedState :: Maybe DerivedState
    }
data ExprDef = ExprDef
    { _name :: Maybe Name
    , _expr :: Expr
    } deriving (Read, Show)
data Clipboard = Clipboard
    { _clipboardTypeConstructor :: Maybe T.TypeConstructor
    , _clipboardDataConstructor :: Maybe DataConstructor
    , _clipboardType :: Maybe (T.Type T.VarName TypeDefKey)
    , _clipboardExpr :: Maybe Expr
    , _clipboardPattern :: Maybe Pattern
    }
data EditState
    = NotEditing
    | Naming EditorState
    | AddingTypeConstructorParam ParamIndex EditorState
    | EditingTypeConstructorParam ParamIndex EditorState
    | RenamingTypeConstructorParam ParamIndex T.VarName EditorState
    | AddingDataConstructor DataConstructorIndex EditorState
    | RenamingDataConstructor DataConstructorIndex EditorState
    | EditingDataConstructorParam DataConstructorIndex DataConstructor ParamIndex Path EditorState
        (Maybe (AutocompleteList (T.Type T.VarName TypeDefKey)))
    | RenamingDataConstructorParam T.VarName EditorState
    | SelectionRenaming EditorState
    | EditingExpr Expr PathsToBeEdited EditorState (Maybe (AutocompleteList (Name, Selectable)))
type DataConstructorIndex = Int
type ParamIndex = Int
type PathsToBeEdited = NonEmpty.NonEmpty Path -- the first is the currently edited one
data DerivedState = DerivedState
    { _inferResult :: InferResult
    , _evalResult :: EvalResult
    }
type Name = String
type TypeDef = T.TypeDef TypeDefKey
type DataConstructor = T.DataConstructor TypeDefKey
type TypeDefKey = Int
type ExprDefKey = Int
type Expr = E.Expr ExprDefKey DataConstructorKey
type DataConstructorKey = T.DataConstructorKey TypeDefKey
type Alternative = E.Alternative ExprDefKey DataConstructorKey
type Pattern = P.Pattern DataConstructorKey
type Value = V.Value DataConstructorKey
type InferResult = Infer.InferResult TypeDefKey
type TypeTree = Infer.TypeTree TypeDefKey
type TypeError = Infer.TypeError TypeDefKey
data AppResourceName = EditorName | AutocompleteName | DefListViewport | TypeDefViewport | ExprDefViewport
    deriving (Eq, Ord, Show)
type AppWidget = Widget AppResourceName
data WrappingStyle = Parens | NoParens | OneWordPerLine deriving (Eq, Enum, Bounded)
data Location = DefListView (Maybe SelectedDefKey) | TypeDefView TypeDefViewLocation | ExprDefView ExprDefViewLocation
type SelectedDefKey = DefKey
data DefKey = TypeDefKey TypeDefKey | ExprDefKey ExprDefKey deriving Eq
data TypeDefViewLocation = TypeDefViewLocation
    { _typeDefKey :: TypeDefKey
    , _typeDefViewSelection :: TypeDefViewSelection
    }
data TypeDefViewSelection
    = TypeConstructorSelection
        { _typeConstructorParamIndex :: Maybe Int
        }
    | DataConstructorSelection
        { _dataConstructorIndex :: Int
        , _pathInDataConstructor :: Path
        }
    deriving Eq
data ExprDefViewLocation = ExprDefViewLocation
    { _exprDefKey :: ExprDefKey
    , _exprDefViewSelection :: Path
    }
type EditorState = Editor String AppResourceName
type AutocompleteList e = ListWidget.List AppResourceName e
data EvalResult = Timeout | Error | Value Value
data Selectable = Expr Expr | Pattern Pattern deriving Eq
newtype RenderChild = RenderChild (ChildIndex -> Renderer -> RenderResult)
type Renderer = WrappingStyle -> RenderChild -> RenderResult
type RenderResult = (RenderResultType, AppWidget)
data RenderResultType = OneWord | OneLine | MultiLine deriving Eq
data Selection = ContainsSelection Path | WithinSelection | NoSelection deriving Eq

makeLenses ''AppState
makeLenses ''ExprDef
makeLenses ''TypeDefViewLocation
makeLenses ''TypeDefViewSelection
makeLenses ''ExprDefViewLocation
makeLenses ''Clipboard
makeLenses ''DerivedState
makePrisms ''Location
makePrisms ''Selectable

main :: IO AppState
main = getInitialState >>= defaultMain app

getInitialState :: IO AppState
getInitialState = do
    readTypeDefsResult <- tryJust (guard . isDoesNotExistError) readTypeDefs
    readExprDefsResult <- tryJust (guard . isDoesNotExistError) readExprDefs
    let typeDefs = either (const Map.empty) (Map.map History.create) readTypeDefsResult
    let exprDefs = either (const Map.empty) (Map.map History.create) readExprDefsResult
    let clipboard = Clipboard Nothing Nothing Nothing Nothing Nothing
    let defKeys = (TypeDefKey <$> Map.keys typeDefs) ++ (ExprDefKey <$> Map.keys exprDefs)
    let locationHistory = History.create $ DefListView $ listToMaybe defKeys
    return $ AppState typeDefs exprDefs locationHistory Parens clipboard NotEditing Nothing Nothing

readTypeDefs :: IO (Map.Map TypeDefKey TypeDef)
readTypeDefs = getTypeDefsPath >>= readDefs

readExprDefs :: IO (Map.Map ExprDefKey ExprDef)
readExprDefs = getExprDefsPath >>= readDefs

readDefs :: (Read k, Read d, Ord k) => FilePath -> IO (Map.Map k d)
readDefs filePath = do
    content <- readFile filePath
    case traverse readMaybe $ lines content of
        Just typeDefs -> return $ Map.fromList typeDefs
        Nothing -> die "Codebase is invalid"

writeTypeDefs :: AppState -> IO ()
writeTypeDefs appState = getTypeDefsPath >>= writeDefs (view committedTypeDefs appState)

writeExprDefs :: AppState -> IO ()
writeExprDefs appState = getExprDefsPath >>= writeDefs (view committedExprDefs appState)

writeDefs :: (Show k, Show d) => Map.Map k (History d) -> FilePath -> IO ()
writeDefs committedDefs filePath = writeFile filePath $ unlines $ map show $ Map.toList $ view present <$> committedDefs

getTypeDefsPath :: IO FilePath
getTypeDefsPath = getFullPath "type-defs"

getExprDefsPath :: IO FilePath
getExprDefsPath = getFullPath "expr-defs"

getFullPath :: FilePath -> IO FilePath
getFullPath relativePath = do
    maybeProjectPath <- getProjectPath
    return $ fromMaybe "" maybeProjectPath ++ relativePath

getProjectPath :: IO (Maybe FilePath)
getProjectPath = listToMaybe <$> getArgs

app :: App AppState e AppResourceName
app = App
    { appDraw = draw
    , appChooseCursor = showFirstCursor
    , appHandleEvent = handleEvent
    , appStartEvent = return
    , appAttrMap = const $ attrMap Vty.defAttr [] }

draw :: AppState -> [AppWidget]
draw appState = case getLocation appState of
    DefListView maybeSelectedDefKey -> drawDefListView appState maybeSelectedDefKey
    TypeDefView location -> drawTypeDefView appState location
    ExprDefView location -> drawExprDefView appState location

drawDefListView :: AppState -> Maybe SelectedDefKey -> [AppWidget]
drawDefListView appState maybeSelectedDefKey = [ title <=> body ] where
    title = renderTitle (str "Definitions")
    body = viewport DefListViewport Both list
    list = toGray $ vBox $ renderItem <$> getDefKeys appState
    renderItem key = (if Just key == maybeSelectedDefKey then visible . highlight else id) (str $ getDefNameOrUnnamed appState key)

getDefNameOrUnnamed :: AppState -> DefKey -> Name
getDefNameOrUnnamed appState key = case key of
    TypeDefKey k -> getTypeNameOrUnnamed appState k
    ExprDefKey k -> getExprNameOrUnnamed appState k

getTypeNameOrUnnamed :: AppState -> TypeDefKey -> Name
getTypeNameOrUnnamed appState key = fromMaybe "Unnamed" $ getTypeName appState key

getExprNameOrUnnamed :: AppState -> ExprDefKey -> Name
getExprNameOrUnnamed appState key = fromMaybe "unnamed" $ getExprName appState key

getTypeName :: AppState -> TypeDefKey -> Maybe Name
getTypeName appState key = view (T.typeConstructor . T.typeConstructorName) $ getTypeDefs appState Map.! key

getExprName :: AppState -> ExprDefKey -> Maybe Name
getExprName appState key = getExprDefs appState Map.! key ^. name

highlightIf :: Bool -> Widget n -> Widget n
highlightIf cond = if cond then highlight else id

toGray :: Widget n -> Widget n
toGray = modifyDefAttr $ flip Vty.withForeColor gray

gray :: Vty.Color
gray = Vty.rgbColor 128 128 128 -- this shade seems ok on both light and dark backgrounds

drawTypeDefView :: AppState -> TypeDefViewLocation -> [AppWidget]
drawTypeDefView appState (TypeDefViewLocation typeDefKey selection) = ui where
    ui = case (view editState appState, view editorExtent appState) of
        (EditingDataConstructorParam _ _ _ _ _ (Just autocompleteList), Just editorExtent) -> [ autocompleteLayer, mainLayer ] where
            autocompleteLayer = renderAutocomplete autocompleteList renderItem editorExtent
            renderItem = renderTypeOnOneLine appState
        _ -> [ mainLayer ]
    mainLayer = toGray $ renderedTitle <=> body
    renderedTitle = case view editState appState of
        Naming editor -> highlight $ str "Name: " <+> renderEditor (str . head) True editor
        _ -> renderTitle $ hBox $ intersperse (str " ") renderedTitleWords
    renderedTitleWords = case view editState appState of
        AddingTypeConstructorParam index editor -> str typeNameOrUnnamed : renderedParams where
            renderedParams = insertAt index (highlight $ renderExpandingSingleLineEditor editor) (str <$> typeConstructorParams)
        EditingTypeConstructorParam index editor -> str typeNameOrUnnamed : renderedParams where
            renderedParams = set (ix index) (highlight $ renderExpandingSingleLineEditor editor) (str <$> typeConstructorParams)
        RenamingTypeConstructorParam index _ editor -> str typeNameOrUnnamed : renderedParams where
            renderedParams = set (ix index) (highlight $ renderExpandingSingleLineEditor editor) (str <$> typeConstructorParams)
        _ -> renderedTypeName : renderedParams where
            renderedTypeName = highlightIf (selection == TypeConstructorSelection Nothing) (str typeNameOrUnnamed)
            renderedParams = zipWith (highlightIf . isSelected) [0..] (str <$> typeConstructorParams)
            isSelected index =
                selection == TypeConstructorSelection Nothing || selection == TypeConstructorSelection (Just index)
    typeNameOrUnnamed = getTypeNameOrUnnamed appState typeDefKey
    typeConstructorParams = view T.typeConstructorParams typeConstructor
    body = viewport TypeDefViewport Both $ vBox renderedDataConstructors
    renderedDataConstructors = zipWith renderDataConstructor [0..] dataConstructors
    renderDataConstructor dataConstructorIndex (T.DataConstructor name paramTypes) =
        (if selection == DataConstructorSelection dataConstructorIndex [] then visible . highlight else id)
        (snd $ foldl (renderCall $ appState ^. wrappingStyle) (OneWord, renderedName) renderedParamTypes)
        where
            renderedName = case view editState appState of
                AddingDataConstructor index editor | index == dataConstructorIndex ->
                    renderExpandingSingleLineEditor editor
                RenamingDataConstructor index editor | index == dataConstructorIndex ->
                    renderExpandingSingleLineEditor editor
                _ -> str name
            renderedParamTypes = zipWith render [0..] paramTypes
            render paramIndex = renderWithAttrs (view wrappingStyle appState) editorState selectionInType Nothing . renderType appState where
                selectionInType = case selection of
                    DataConstructorSelection selectedDataConstructorIndex (selectedParamIndex : selectedPathInParam)
                        | selectedDataConstructorIndex == dataConstructorIndex && selectedParamIndex == paramIndex ->
                            ContainsSelection selectedPathInParam
                    _ -> NoSelection
            editorState = case view editState appState of
                EditingDataConstructorParam _ _ _ _ editor _ -> Just editor
                RenamingDataConstructorParam _ editor -> Just editor
                _ -> Nothing
    T.TypeDef typeConstructor dataConstructors = getTypeDefs appState Map.! typeDefKey

renderTypeOnOneLine :: AppState -> T.Type T.VarName TypeDefKey -> AppWidget
renderTypeOnOneLine appState t = snd . renderWithAttrs Parens Nothing NoSelection Nothing $ renderType appState t

renderType :: AppState -> T.Type T.VarName TypeDefKey -> Renderer
renderType appState t wrappingStyle (RenderChild renderChild) = case t of
    T.Wildcard -> (OneWord, str "_")
    T.Var name -> (OneWord, str name)
    T.Call callee arg ->
        renderCall wrappingStyle (renderChild 0 $ renderType appState callee) (renderChild 1 $ renderType appState arg)
    T.Constructor typeDefKey -> (OneWord, str $ getTypeNameOrUnnamed appState typeDefKey)
    T.Fn -> (OneWord, str "λ")
    T.Integer -> (OneWord, str "Integer")
    T.String -> (OneWord, str "String")

printType :: AppState -> T.Type T.VarName TypeDefKey -> String
printType appState = snd . print where
    print t = case t of
        T.Wildcard -> (OneWord, "_")
        T.Var name -> (OneWord, name)
        T.Call callee arg -> (OneLine, calleeResult ++ " " ++ PrettyPrint.inParensIf (argResultType /= OneWord) argResult) where
            (_, calleeResult) = print callee
            (argResultType, argResult) = print arg
        T.Constructor typeDefKey -> (OneWord, getTypeNameOrUnnamed appState typeDefKey)
        T.Fn -> (OneWord, "λ")
        T.Integer -> (OneWord, "Integer")
        T.String -> (OneWord, "String")

insertAt :: Int -> a -> [a] -> [a]
insertAt index item = (!! index) . iterate _tail %~ (item :)

renderExpandingSingleLineEditor :: (Ord n, Show n) => Editor String n -> Widget n
renderExpandingSingleLineEditor editor = hLimit (textWidth editStr + 1) $ renderEditor (str . head) True editor where
    editStr = head $ getEditContents editor

renderAutocomplete :: (Ord n, Show n) => ListWidget.List n a -> (a -> Widget n) -> Extent n -> Widget n
renderAutocomplete autocompleteList renderItem editorExtent = Widget Greedy Greedy $ do
    ctx <- getContext
    let autocompleteListLength = length $ ListWidget.listElements autocompleteList
    let Brick.Types.Location (editorX, editorY) = extentUpperLeft editorExtent
    let availableWidth = ctx ^. availWidthL - 1 -- using the last column seems to cause issues
    let availableHeight = ctx ^. availHeightL
    let autocompleteWidth = min availableWidth 40
    let autocompleteHeight = min autocompleteListLength 5
    let autocompleteX = if availableWidth < editorX + autocompleteWidth then availableWidth - autocompleteWidth else editorX
    let autocompleteY = if availableHeight < editorY + 1 + autocompleteHeight then editorY - autocompleteHeight else editorY + 1
    let autocompleteOffset = Brick.Types.Location (autocompleteX, autocompleteY)
    let renderedList = ListWidget.renderList renderAutocompleteItem True $ renderItem <$> autocompleteList
    render $ translateBy autocompleteOffset $ hLimit autocompleteWidth $ vLimit autocompleteHeight renderedList

drawExprDefView :: AppState -> ExprDefViewLocation -> [AppWidget]
drawExprDefView appState (ExprDefViewLocation defKey selectionPath) = ui where
    AppState _ _ _ wrappingStyle _ editState _ (Just (DerivedState inferResult evalResult)) = appState
    ui = case (editState, view editorExtent appState) of
        (EditingExpr _ _ _ (Just autocompleteList), Just editorExtent) -> [ autocompleteLayer, mainLayer ] where
            autocompleteLayer = renderAutocomplete autocompleteList renderItem editorExtent
            renderItem = str . fst
        _ -> [ mainLayer ]
    mainLayer = renderedTitle <=> viewport ExprDefViewport Both coloredExpr <=> bottomStr
    renderedTitle = case editState of
        Naming editor -> str "Name: " <+> renderEditor (str . head) True editor
        _ -> renderTitle $ str $ getExprNameOrUnnamed appState defKey
    coloredExpr = toGray renderedExpr -- unselected parts of the expression are gray
    def = getExprDefs appState Map.! defKey
    renderedExpr = snd $ renderWithAttrs wrappingStyle editorState (ContainsSelection selectionPath) maybeTypeError renderer
    editorState = case editState of
        EditingExpr _ _ editor _ -> Just editor
        SelectionRenaming editor -> Just editor
        _ -> Nothing
    renderer = renderExpr appState $ view expr def
    maybeTypeError = preview Infer._Untyped inferResult
    maybeSelectionType = getTypeAtPathInInferResult selectionPath inferResult
    bottomStr = case maybeSelectionType of
        Right t -> str evalStr <+> str ": " <+> renderTypeOnOneLine appState (nameTypeVars t)
        Left errorMsg -> str errorMsg
    evalStr = case evalResult of
        Timeout -> "<eval timeout>"
        Error -> ""
        Value v -> fromMaybe "" $ PrettyPrint.prettyPrintValue (view T.constructorName) v

nameTypeVars :: T.Type Infer.TVarId d -> T.Type T.VarName d
nameTypeVars = T.mapTypeVars (fmap T.Var defaultTypeVarNames !!)

defaultTypeVarNames :: [String]
defaultTypeVarNames = [1..] >>= flip replicateM ['a'..'z']

renderTitle :: Widget n -> Widget n
renderTitle title = hBorderWithLabel $ str "  " <+> title <+> str "  "

renderAutocompleteItem :: Bool -> Widget n -> Widget n
renderAutocompleteItem isSelected content = color $ padRight Max content where
    color = modifyDefAttr $
        if isSelected
        then flip Vty.withBackColor Vty.brightCyan . flip Vty.withForeColor black
        else flip Vty.withBackColor Vty.blue . flip Vty.withForeColor white
    white = Vty.rgbColor 255 255 255
    black = Vty.rgbColor 0 0 0

renderWithAttrs :: WrappingStyle -> Maybe EditorState -> Selection -> Maybe TypeError -> Renderer -> RenderResult
renderWithAttrs wrappingStyle maybeEditorState selection maybeTypeError renderer = case maybeEditorState of
    Just editor | selected -> renderSelectionEditor editor
    _ -> (renderResultType, (if selected then visible . highlight else id) $ makeRedIfNeeded widget)
    where
        selected = selection == ContainsSelection []
        withinSelection = selection == WithinSelection
        makeRedIfNeeded = if hasError && (selected || withinSelection) then makeRed else id
        hasError = maybe False Infer.hasErrorAtRoot maybeTypeError
        makeRed = modifyDefAttr $ flip Vty.withForeColor Vty.red
        (renderResultType, widget) = renderer wrappingStyle $ RenderChild renderChild
        renderChild index = renderWithAttrs wrappingStyle maybeEditorState (getChildSelection selection index) (getChildTypeError maybeTypeError index)
        renderSelectionEditor editor = (OneWord, visible . highlight $ renderExpandingSingleLineEditor editor)

renderExpr :: AppState -> Expr -> Renderer
renderExpr appState expr wrappingStyle (RenderChild renderChild) = case expr of
    E.Hole -> (OneWord, str "_")
    E.Def key -> (OneWord, str $ getExprNameOrUnnamed appState key)
    E.Var var -> (OneWord, str var)
    E.Fn alternatives -> if length alternatives == 1 then NonEmpty.head altResults else (MultiLine, vBox altWidgets) where
        altResults = NonEmpty.zipWith (renderAlternative appState $ RenderChild renderChild) (NonEmpty.fromList [0..]) alternatives
        altWidgets = map snd $ NonEmpty.toList altResults
    E.Call callee arg -> case callee of
        E.Fn _ -> (MultiLine, renderedMatch) where
            renderedMatch =
                if argResultType == MultiLine
                then str "match" <=> indent renderedArg <=> indent renderedCallee
                else str "match " <+> renderedArg <=> indent renderedCallee
        _ -> renderCall wrappingStyle calleeResult argResult
        where
            calleeResult@(_, renderedCallee) = renderChild 0 $ renderExpr appState callee
            argResult@(argResultType, renderedArg) = renderChild 1 $ renderExpr appState arg
    E.Constructor key -> (OneWord, str $ view T.constructorName key)
    E.Integer n -> (OneWord, str $ show n)
    E.String s -> (OneWord, str $ show s)
    E.Primitive p -> (OneWord, str $ getDisplayName p)

renderCall :: WrappingStyle -> RenderResult -> RenderResult -> RenderResult
renderCall wrappingStyle (calleeResultType, renderedCallee) (argResultType, renderedArg) =
    if shouldBeMultiLine then multiLineResult else oneLineResult
    where
        shouldBeMultiLine = case wrappingStyle of
            Parens -> calleeResultType == MultiLine || argResultType == MultiLine
            NoParens -> calleeResultType == MultiLine || argResultType /= OneWord
            OneWordPerLine -> True
        multiLineResult = (MultiLine, renderedCallee <=> indent renderedArg)
        oneLineResult = (OneLine, renderedCallee <+> str " " <+> inParensIf (argResultType /= OneWord) renderedArg)

inParensIf :: Bool -> Widget n -> Widget n
inParensIf cond w = if cond then str "(" <+> w <+> str ")" else w

renderAlternative :: AppState -> RenderChild -> Int -> Alternative -> RenderResult
renderAlternative appState (RenderChild renderChild) alternativeIndex (patt, expr) =
    if exprResultType == MultiLine
    then (MultiLine, prefix <+> (renderedPattern <+> str " ->" <=> renderedExpr))
    else (OneLine, prefix <+> renderedPattern <+> str " -> " <+> renderedExpr)
    where
        prefix = str $ if alternativeIndex == 0 then "λ " else "| "
        (_, renderedPattern) = renderChild (2 * alternativeIndex) $ renderPattern patt
        (exprResultType, renderedExpr) = renderChild (2 * alternativeIndex + 1) $ renderExpr appState expr

renderPattern :: Pattern -> Renderer
renderPattern patt _ (RenderChild renderChild) = case patt of
    P.Wildcard -> (OneWord, str "_")
    P.Var var -> (OneWord, str var)
    P.Constructor key children -> (resultType, hBox $ intersperse (str " ") (str name : renderedChildren)) where
        resultType = if null children then OneWord else OneLine
        name = view T.constructorName key
        renderedChildren = addParensIfNeeded <$> zipWith renderChild [0..] childRenderers
        addParensIfNeeded (resultType, renderedChild) = inParensIf (resultType /= OneWord) renderedChild
        childRenderers = renderPattern <$> children
    P.Integer n -> (OneWord, str $ show n)
    P.String s -> (OneWord, str $ show s)

indent :: Widget n -> Widget n
indent w = str "  " <+> w

highlight :: Widget n -> Widget n
highlight = modifyDefAttr $ const Vty.defAttr -- the gray foreground color is changed back to the default

getChildSelection :: Selection -> ChildIndex -> Selection
getChildSelection selection index = case selection of
    ContainsSelection (i:childPath) -> if i == index then ContainsSelection childPath else NoSelection
    ContainsSelection [] -> WithinSelection
    WithinSelection -> WithinSelection
    NoSelection -> NoSelection

getChildTypeError :: Maybe TypeError -> ChildIndex -> Maybe TypeError
getChildTypeError maybeTypeError index = childResult >>= preview Infer._Untyped
    where childResult = (!! index) . view Infer.childResults <$> maybeTypeError

getTypeAtPathInInferResult :: Path -> InferResult -> Either Infer.ErrorMsg (T.Type Infer.TVarId TypeDefKey)
getTypeAtPathInInferResult path inferResult = case inferResult of
    Infer.Typed typeTree -> Right $ getTypeAtPathInTypeTree path typeTree
    Infer.Untyped (Infer.TypeError msg childResults) -> case path of
        [] -> Left msg
        index:restOfPath -> getTypeAtPathInInferResult restOfPath $ childResults !! index

getTypeAtPathInTypeTree :: Path -> TypeTree -> T.Type Infer.TVarId TypeDefKey
getTypeAtPathInTypeTree path (Infer.TypeTree t children) = case path of
    [] -> t
    index:restOfPath -> getTypeAtPathInTypeTree restOfPath $ children !! index

getItemAtPathInType :: Path -> T.Type v d -> Maybe (T.Type v d)
getItemAtPathInType path t = case path of
    [] -> Just t
    edge:restOfPath -> getChildInType edge t >>= getItemAtPathInType restOfPath

getChildInType :: ChildIndex -> T.Type v d -> Maybe (T.Type v d)
getChildInType index t = case t of
    T.Call callee arg -> case index of
        0 -> Just callee
        1 -> Just arg
        _ -> Nothing
    _ -> Nothing

getChildCountOfType :: T.Type v d -> Int
getChildCountOfType t = if is T._Call t then 2 else 0

getItemAtPathInExpr :: Path -> Expr -> Maybe Selectable
getItemAtPathInExpr path expr = getItemAtPathInSelectable path (Expr expr)

getItemAtPathInSelectable :: Path -> Selectable -> Maybe Selectable
getItemAtPathInSelectable path selectable = case path of
    [] -> Just selectable
    edge:restOfPath -> getChildInSelectable selectable edge >>= getItemAtPathInSelectable restOfPath

getChildInSelectable :: Selectable -> ChildIndex -> Maybe Selectable
getChildInSelectable selectable = case selectable of
    Expr e -> getChildInExpr e
    Pattern p -> getChildInPattern p

getChildInExpr :: Expr -> ChildIndex -> Maybe Selectable
getChildInExpr expr index = case (expr, index) of
    (E.Fn alternatives, _) -> do
        let altIndex = div index 2
        (patt, expr) <- getItemAtIndex altIndex (NonEmpty.toList alternatives)
        return $ if even index then Pattern patt else Expr expr
    (E.Call callee _, 0) -> Just $ Expr callee
    (E.Call _ arg, 1) -> Just $ Expr arg
    _ -> Nothing

getChildInPattern :: Pattern -> ChildIndex -> Maybe Selectable
getChildInPattern patt index = case patt of
    P.Constructor _ patterns -> Pattern <$> getItemAtIndex index patterns
    _ -> Nothing

handleEvent :: AppState -> BrickEvent n e -> EventM AppResourceName (Next AppState)
handleEvent appState event = do
    maybeEditorExtent <- lookupExtent EditorName
    handleEvent' (appState & editorExtent .~ maybeEditorExtent) event

handleEvent' :: AppState -> BrickEvent n e -> EventM AppResourceName (Next AppState)
handleEvent' appState brickEvent = case brickEvent of
    VtyEvent event -> case getLocation appState of
        DefListView maybeSelectedDefKey -> handleEventOnDefListView appState event maybeSelectedDefKey
        TypeDefView location -> handleEventOnTypeDefView appState event location
        ExprDefView location -> handleEventOnExprDefView appState event location
    _ -> continue appState

handleEventOnDefListView :: AppState -> Vty.Event -> Maybe SelectedDefKey -> EventM AppResourceName (Next AppState)
handleEventOnDefListView appState event maybeSelectedDefKey = case event of
    Vty.EvKey Vty.KEnter [] -> maybe continue goToDef maybeSelectedDefKey appState
    Vty.EvKey Vty.KUp [] -> selectPrev
    Vty.EvKey Vty.KDown [] -> selectNext
    Vty.EvKey (Vty.KChar 'i') [] -> selectPrev
    Vty.EvKey (Vty.KChar 'k') [] -> selectNext
    Vty.EvKey (Vty.KChar 'g') [] -> goBackInLocationHistory appState
    Vty.EvKey (Vty.KChar 'G') [] -> goForwardInLocationHistory appState
    Vty.EvKey (Vty.KChar 'O') [] -> openNewTypeDef appState
    Vty.EvKey (Vty.KChar 'o') [] -> openNewExprDef appState
    Vty.EvKey (Vty.KChar 'q') [] -> halt appState
    _ -> continue appState
    where
        selectPrev = maybe (continue appState) select maybePrevDefKey
        selectNext = maybe (continue appState) select maybeNextDefKey
        select defKey = continue $ appState & committedLocations . present . _DefListView ?~ defKey
        maybePrevDefKey = fmap (subtract 1) maybeSelectedIndex >>= flip getItemAtIndex defKeys
        maybeNextDefKey = fmap (+ 1) maybeSelectedIndex >>= flip getItemAtIndex defKeys
        maybeSelectedIndex = maybeSelectedDefKey >>= flip elemIndex defKeys
        defKeys = getDefKeys appState

openNewTypeDef :: AppState -> EventM AppResourceName (Next AppState)
openNewTypeDef appState = liftIO createNewAppState >>= continue where
    createNewAppState = handleTypeDefsChange $ appState
        & committedTypeDefs %~ Map.insert newDefKey (History.create $ T.TypeDef (T.TypeConstructor Nothing []) [])
        & committedLocations %~ push newLocation . selectNewDef
    newLocation = TypeDefView $ TypeDefViewLocation newDefKey $ TypeConstructorSelection Nothing
    newDefKey = createNewDefKey $ view committedTypeDefs appState
    selectNewDef = present . _DefListView ?~ TypeDefKey newDefKey

openNewExprDef :: AppState -> EventM AppResourceName (Next AppState)
openNewExprDef appState = liftIO createNewAppState >>= continue where
    createNewAppState = handleExprDefsChange $ appState
        & committedExprDefs %~ Map.insert newDefKey (History.create $ ExprDef Nothing E.Hole)
        & committedLocations %~ push newLocation . selectNewDef
    newLocation = ExprDefView $ ExprDefViewLocation newDefKey []
    newDefKey = createNewDefKey $ view committedExprDefs appState
    selectNewDef = present . _DefListView ?~ ExprDefKey newDefKey

createNewDefKey :: Map.Map Int a -> Int
createNewDefKey defs = if null defs then 0 else fst (Map.findMax defs) + 1

getDefKeys :: AppState -> [DefKey]
getDefKeys appState = (TypeDefKey <$> getTypeDefKeys appState) ++ (ExprDefKey <$> getExprDefKeys appState)

getTypeDefKeys :: AppState -> [TypeDefKey]
getTypeDefKeys = Map.keys . view committedTypeDefs

getExprDefKeys :: AppState -> [ExprDefKey]
getExprDefKeys = Map.keys . view committedExprDefs

handleEventOnTypeDefView :: AppState -> Vty.Event -> TypeDefViewLocation -> EventM AppResourceName (Next AppState)
handleEventOnTypeDefView appState event (TypeDefViewLocation typeDefKey selection) = case view editState appState of
    NotEditing -> case event of
        Vty.EvKey Vty.KEnter [] -> goToDefinition
        Vty.EvKey (Vty.KChar 'g') [] -> goBackInLocationHistory appState
        Vty.EvKey (Vty.KChar 'G') [] -> goForwardInLocationHistory appState
        Vty.EvKey (Vty.KChar 'N') [] -> initiateRenameDefinition appState
        Vty.EvKey (Vty.KChar 'n') [] -> initiateRenameSelection
        Vty.EvKey Vty.KLeft [] -> selectParent
        Vty.EvKey Vty.KRight [] -> selectChild
        Vty.EvKey Vty.KUp [] -> selectPrev
        Vty.EvKey Vty.KDown [] -> selectNext
        Vty.EvKey (Vty.KChar 'j') [] -> selectParent
        Vty.EvKey (Vty.KChar 'l') [] -> selectChild
        Vty.EvKey (Vty.KChar 'i') [] -> selectPrev
        Vty.EvKey (Vty.KChar 'k') [] -> selectNext
        Vty.EvKey (Vty.KChar 'e') [] -> initiateSelectionEdit
        Vty.EvKey (Vty.KChar 'a') [] -> initiateAddDataConstructorBelowSelection
        Vty.EvKey (Vty.KChar 'A') [] -> initiateAddDataConstructorAboveSelection
        Vty.EvKey (Vty.KChar '<') [] -> initiateAddParamBeforeSelection
        Vty.EvKey (Vty.KChar '>') [] -> initiateAddParamAfterSelection
        Vty.EvKey (Vty.KChar ')') [] -> initiateCallSelected
        Vty.EvKey (Vty.KChar '(') [] -> initiateApplyFnToSelected
        Vty.EvKey (Vty.KChar 'd') [] -> deleteSelected
        Vty.EvKey (Vty.KChar 'c') [] -> copy
        Vty.EvKey (Vty.KChar 'p') [] -> paste
        Vty.EvKey (Vty.KChar 'u') [] -> undo
        Vty.EvKey (Vty.KChar 'r') [] -> redo
        Vty.EvKey (Vty.KChar '\t') [] -> switchToNextWrappingStyle appState
        Vty.EvKey Vty.KBackTab [] -> switchToPrevWrappingStyle appState
        Vty.EvKey (Vty.KChar 'O') [] -> openNewTypeDef appState
        Vty.EvKey (Vty.KChar 'o') [] -> openNewExprDef appState
        Vty.EvKey (Vty.KChar 'q') [] -> halt appState
        _ -> continue appState
    Naming editor -> case event of
        Vty.EvKey Vty.KEsc [] -> cancelEdit appState
        Vty.EvKey Vty.KEnter [] -> commitDefName appState (head $ getEditContents editor) isValidTypeName
        _ -> handleEditorEvent event editor >>= setEditState appState . Naming
    AddingTypeConstructorParam index editor -> case event of
        Vty.EvKey Vty.KEsc [] -> cancelEdit appState
        Vty.EvKey Vty.KEnter [] -> commitAddTypeConstructorParam appState typeDefKey index (head $ getEditContents editor)
        _ -> handleEditorEvent event editor >>= setEditState appState . AddingTypeConstructorParam index
    EditingTypeConstructorParam index editor -> case event of
        Vty.EvKey Vty.KEsc [] -> cancelEdit appState
        Vty.EvKey Vty.KEnter [] -> commitEditTypeConstructorParam appState typeDefKey index (head $ getEditContents editor)
        _ -> handleEditorEvent event editor >>= setEditState appState . EditingTypeConstructorParam index
    RenamingTypeConstructorParam index oldName editor -> case event of
        Vty.EvKey Vty.KEsc [] -> cancelEdit appState
        Vty.EvKey Vty.KEnter [] -> commitRenameTypeVar appState typeDefKey oldName (head $ getEditContents editor)
        _ -> handleEditorEvent event editor >>= setEditState appState . RenamingTypeConstructorParam index oldName
    RenamingDataConstructorParam oldName editor -> case event of
        Vty.EvKey Vty.KEsc [] -> cancelEdit appState
        Vty.EvKey Vty.KEnter [] -> commitRenameTypeVar appState typeDefKey oldName (head $ getEditContents editor)
        _ -> handleEditorEvent event editor >>= setEditState appState . RenamingDataConstructorParam oldName
    AddingDataConstructor index editor -> case event of
        Vty.EvKey Vty.KEsc [] -> cancelEdit appState
        Vty.EvKey Vty.KEnter [] -> commitAddDataConstructor appState typeDefKey index (head $ getEditContents editor)
        _ -> handleEditorEvent event editor >>= setEditState appState . AddingDataConstructor index
    RenamingDataConstructor index editor -> case event of
        Vty.EvKey Vty.KEsc [] -> cancelEdit appState
        Vty.EvKey Vty.KEnter [] -> commitRenameDataConstructor appState typeDefKey index (head $ getEditContents editor)
        _ -> handleEditorEvent event editor >>= setEditState appState . RenamingDataConstructor index
    EditingDataConstructorParam dataConstructorIndex dataConstructor paramIndex path editor maybeAutocompleteList -> case event of
        Vty.EvKey Vty.KEsc [] -> cancelEdit appState
        Vty.EvKey (Vty.KChar '\t') [] -> case maybeAutocompleteList >>= ListWidget.listSelectedElement of
            Just (_, t) -> commit t
            Nothing -> continue appState
        Vty.EvKey Vty.KEnter []
            | editorContent == "" || editorContent == "_" ->
                commit T.Wildcard
            | isValidTypeVarName editorContent ->
                commit (T.Var editorContent)
            | otherwise -> continue appState
        Vty.EvKey (Vty.KChar c) [] | (c == 'λ' || c == '\\') && editorContent == "" -> commit T.Fn
        _ -> do
            newEditor <- handleEditorEventIgnoringAutocompleteControls event editor
            let newEditorContent = head $ getEditContents newEditor
            let editorContentChanged = newEditorContent /= editorContent
            let isMatch name = name `containsIgnoringCase` newEditorContent
            let items = Vec.fromList $
                    filter (isMatch . show) [T.Integer, T.String]
                    ++ (T.Constructor <$> filter (maybe False isMatch . getTypeName appState) typeDefKeys)
                    ++ (T.Var <$> filter isMatch (T.getTypeVarsInTypeDef def))
            newAutocompleteList <- case maybeAutocompleteList of
                Just autocompleteList | not editorContentChanged -> Just <$> ListWidget.handleListEvent event autocompleteList
                _ -> pure $ if null items then Nothing else Just $ ListWidget.list AutocompleteName items 1
            setEditState appState $
                EditingDataConstructorParam dataConstructorIndex dataConstructor paramIndex path newEditor newAutocompleteList
        where
            editorContent = head $ getEditContents editor
            commit = commitDataConstructorEdit appState typeDefKey dataConstructorIndex dataConstructor paramIndex path
    _ -> continue appState
    where
        defHistory = view committedTypeDefs appState Map.! typeDefKey
        def = currentTypeDefs Map.! typeDefKey
        currentTypeDefs = getTypeDefs appState
        typeDefKeys = getTypeDefKeys appState
        goToDefinition = case selection of
            DataConstructorSelection dataConstructorIndex (paramIndex : pathInParam) ->
                case getItemAtPathInType pathInParam param of
                    Just (T.Constructor defKey) | Map.member defKey currentTypeDefs ->
                        goToTypeDef defKey (TypeConstructorSelection Nothing) appState
                    _ -> continue appState
                where
                    param = (dataConstructor ^. T.dataConstructorParamTypes) !! paramIndex
                    dataConstructor = dataConstructors !! dataConstructorIndex
            _ -> continue appState
        selectPrev = setSelection $ case selection of
            TypeConstructorSelection Nothing -> TypeConstructorSelection Nothing
            TypeConstructorSelection (Just paramIndex) -> TypeConstructorSelection $ Just $ max (paramIndex - 1) 0
            DataConstructorSelection dataConstructorIndex path -> case viewR path of
                Nothing ->
                    if dataConstructorIndex > 0
                    then DataConstructorSelection (dataConstructorIndex - 1) []
                    else TypeConstructorSelection Nothing
                Just (parentPath, childIndex) -> DataConstructorSelection dataConstructorIndex newPath where
                    newPath = parentPath ++ [(childIndex - 1) `mod` siblingCount]
                    siblingCount = getChildCountAtPath parentPath dataConstructor
                    dataConstructor = dataConstructors !! dataConstructorIndex
        selectNext = setSelection $ case selection of
            TypeConstructorSelection Nothing ->
                if dataConstructorCount > 0
                then DataConstructorSelection 0 []
                else TypeConstructorSelection Nothing
            TypeConstructorSelection (Just paramIndex) ->
                TypeConstructorSelection $ Just $ min (paramIndex + 1) (typeConstructorParamCount - 1)
            DataConstructorSelection dataConstructorIndex path -> case viewR path of
                Nothing -> DataConstructorSelection (min (dataConstructorIndex + 1) (dataConstructorCount - 1)) []
                Just (parentPath, childIndex) -> DataConstructorSelection dataConstructorIndex newPath where
                    newPath = parentPath ++ [(childIndex + 1) `mod` siblingCount]
                    siblingCount = getChildCountAtPath parentPath dataConstructor
                    dataConstructor = dataConstructors !! dataConstructorIndex
        selectParent = setSelection $ case selection of
            TypeConstructorSelection _ -> TypeConstructorSelection Nothing
            DataConstructorSelection dataConstructorIndex path ->
                DataConstructorSelection dataConstructorIndex $ initDef [] path
        selectChild = setSelection $ case selection of
            TypeConstructorSelection Nothing ->
                TypeConstructorSelection $ if typeConstructorParamCount > 0 then Just 0 else Nothing
            TypeConstructorSelection (Just paramIndex) -> TypeConstructorSelection (Just paramIndex)
            DataConstructorSelection dataConstructorIndex path ->
                DataConstructorSelection dataConstructorIndex newPath where
                    newPath = if getChildCountAtPath path dataConstructor > 0 then path ++ [0] else path
                    dataConstructor = dataConstructors !! dataConstructorIndex
        getChildCountAtPath path dataConstructor = case path of
            [] -> length paramTypes
            paramIndex : pathInParam -> getChildCountOfType parent where
                parent = fromJustNote "current path invalid" $ getItemAtPathInType pathInParam $ paramTypes !! paramIndex
            where paramTypes = dataConstructor ^. T.dataConstructorParamTypes
        setSelection newSelection = continue $ appState
            & committedLocations . present . _TypeDefView . typeDefViewSelection .~ newSelection
        typeConstructorParamCount = length typeConstructorParams
        typeConstructorParams = currentTypeDefs ^. ix typeDefKey . T.typeConstructor . T.typeConstructorParams
        dataConstructorCount = length dataConstructors
        dataConstructors = getDataConstructors appState typeDefKey
        initiateRenameSelection = case selection of
            TypeConstructorSelection Nothing -> initiateRenameDefinition appState
            TypeConstructorSelection (Just paramIndex) -> setEditState appState initialEditState where
                initialEditState = RenamingTypeConstructorParam paramIndex paramName initialEditor
                initialEditor = applyEdit gotoEOL $ editor EditorName (Just 1) paramName
                paramName = typeConstructorParams !! paramIndex
            DataConstructorSelection dataConstructorIndex [] -> initiateRenameDataConstructor dataConstructorIndex
            DataConstructorSelection dataConstructorIndex (paramIndex : pathInParam) -> case getItemAtPathInType pathInParam param of
                Just (T.Var name) -> setEditState appState initialEditState where
                    initialEditState = RenamingDataConstructorParam name initialEditor
                    initialEditor = applyEdit gotoEOL $ editor EditorName (Just 1) name
                _ -> continue appState
                where
                    param = (dataConstructor ^. T.dataConstructorParamTypes) !! paramIndex
                    dataConstructor = dataConstructors !! dataConstructorIndex
        initiateSelectionEdit = case selection of
            TypeConstructorSelection Nothing -> initiateRenameDefinition appState
            TypeConstructorSelection (Just paramIndex) -> setEditState appState initialEditState where
                initialEditState = EditingTypeConstructorParam paramIndex initialEditor
                initialEditor = applyEdit gotoEOL $ editor EditorName (Just 1) paramName
                paramName = typeConstructorParams !! paramIndex
            DataConstructorSelection dataConstructorIndex [] -> initiateRenameDataConstructor dataConstructorIndex
            DataConstructorSelection dataConstructorIndex (paramIndex : pathInParam) -> setEditState appState initialEditState where
                initialEditState =
                    EditingDataConstructorParam dataConstructorIndex dataConstructor paramIndex pathInParam initialEditor Nothing
                dataConstructor = dataConstructors !! dataConstructorIndex
                initialEditor = applyEdit gotoEOL $ editor EditorName (Just 1) initialEditorContent
                initialEditorContent = case getItemAtPathInType pathInParam param of
                    Just t -> case t of
                        T.Wildcard -> ""
                        T.Var var -> var
                        T.Call _ _ -> ""
                        T.Constructor typeDefKey -> getTypeNameOrUnnamed appState typeDefKey
                        T.Fn -> ""
                        T.Integer -> "Integer"
                        T.String -> "String"
                    Nothing -> error "invalid path"
                param = (dataConstructor ^. T.dataConstructorParamTypes) !! paramIndex
        initiateRenameDataConstructor index = setEditState appState initialEditState where
            initialEditState = RenamingDataConstructor index initialEditor
            initialEditor = applyEdit gotoEOL $ editor EditorName (Just 1) dataConstructorName
            dataConstructorName = dataConstructors !! index ^. T.dataConstructorName
        initiateAddDataConstructorBelowSelection = initiateAddDataConstructor appState $ case selection of
            TypeConstructorSelection _ -> 0
            DataConstructorSelection index _ -> index + 1
        initiateAddDataConstructorAboveSelection = initiateAddDataConstructor appState $ case selection of
            TypeConstructorSelection _ -> 0
            DataConstructorSelection index _ -> index
        initiateAddParamBeforeSelection = case selection of
            TypeConstructorSelection Nothing -> initiateAddTypeConstructorParam appState 0
            TypeConstructorSelection (Just paramIndex) -> initiateAddTypeConstructorParam appState paramIndex
            DataConstructorSelection dataConstructorIndex [] ->
                initiateAddParamToDataConstructor dataConstructorIndex 0
            DataConstructorSelection dataConstructorIndex (paramIndex : _) ->
                initiateAddParamToDataConstructor dataConstructorIndex paramIndex
        initiateAddParamAfterSelection = case selection of
            TypeConstructorSelection Nothing -> initiateAddTypeConstructorParam appState typeConstructorParamCount
            TypeConstructorSelection (Just paramIndex) -> initiateAddTypeConstructorParam appState $ paramIndex + 1
            DataConstructorSelection dataConstructorIndex [] ->
                initiateAddParamToDataConstructor dataConstructorIndex paramCount where
                    paramCount = length $ dataConstructors !! dataConstructorIndex ^. T.dataConstructorParamTypes
            DataConstructorSelection dataConstructorIndex (paramIndex : _) ->
                initiateAddParamToDataConstructor dataConstructorIndex $ paramIndex + 1
        initiateAddParamToDataConstructor dataConstructorIndex paramIndex =
            setEditState appState $ EditingDataConstructorParam dataConstructorIndex dataConstructor paramIndex [] emptyEditor Nothing where
                dataConstructor = dataConstructors !! dataConstructorIndex & T.dataConstructorParamTypes %~ insertAt paramIndex T.Wildcard
        initiateCallSelected = initiateModification (`T.Call` T.Wildcard) [1]
        initiateApplyFnToSelected = initiateModification (T.Wildcard `T.Call`) [0]
        initiateModification modify pathWithinSelection = continue $ case selection of
            DataConstructorSelection dataConstructorIndex (paramIndex : path) ->
                appState & editState .~
                    EditingDataConstructorParam dataConstructorIndex dataConstructor paramIndex newPath emptyEditor Nothing where
                        newPath = path ++ pathWithinSelection
                        dataConstructor = dataConstructors !! dataConstructorIndex
                            & T.dataConstructorParamTypes . ix paramIndex %~ modifyAtPathInType path modify
            _ -> appState
        deleteSelected = case selection of
            TypeConstructorSelection (Just paramIndex) -> appState
                & committedLocations . present . _TypeDefView . typeDefViewSelection .~ newSelection
                & modifyTypeDef typeDefKey (T.typeConstructor . T.typeConstructorParams %~ removeItemAtIndex paramIndex)
                where
                    newSelection = TypeConstructorSelection $
                        if typeConstructorParamCount == 1
                            then Nothing
                            else Just $ min paramIndex (typeConstructorParamCount - 2)
            DataConstructorSelection dataConstructorIndex [] -> appState
                & committedLocations . present . _TypeDefView . typeDefViewSelection .~ newSelection
                & modifyTypeDef typeDefKey (T.dataConstructors %~ removeItemAtIndex dataConstructorIndex)
                where
                    newSelection =
                        if dataConstructorCount == 1
                            then TypeConstructorSelection Nothing
                            else DataConstructorSelection (min dataConstructorIndex (dataConstructorCount - 2)) []
            DataConstructorSelection dataConstructorIndex (paramIndex : pathInParam) ->
                case getItemAtPathInType pathInParam param of
                    Just T.Wildcard -> case viewR pathInParam of
                        Just (parentPathInParam, childIndex) -> appState
                            & committedLocations . present . _TypeDefView . typeDefViewSelection
                                .~ DataConstructorSelection dataConstructorIndex (paramIndex : parentPathInParam)
                            & modifyTypeDef typeDefKey
                                (T.dataConstructors . ix dataConstructorIndex . T.dataConstructorParamTypes . ix paramIndex
                                    %~ modifyAtPathInType parentPathInParam getOtherChild)
                            where
                                getOtherChild t = case t of
                                    T.Call callee arg
                                        | childIndex == 0 -> arg
                                        | childIndex == 1 -> callee
                                    _ -> error "invalid path"
                        Nothing -> appState
                            & committedLocations . present . _TypeDefView . typeDefViewSelection .~ newSelection
                            & modifyTypeDef typeDefKey
                                (T.dataConstructors . ix dataConstructorIndex . T.dataConstructorParamTypes
                                %~ removeItemAtIndex paramIndex)
                            where
                                newSelection = DataConstructorSelection dataConstructorIndex $
                                    if dataConstructorParamCount == 1
                                        then []
                                        else [min paramIndex (dataConstructorParamCount - 2)]
                                dataConstructorParamCount =
                                    length $ dataConstructors ^. ix dataConstructorIndex . T.dataConstructorParamTypes
                    _ -> appState
                        & modifyTypeDef typeDefKey
                            (T.dataConstructors . ix dataConstructorIndex . T.dataConstructorParamTypes . ix paramIndex
                            %~ modifyAtPathInType pathInParam (const T.Wildcard))
                where param = (dataConstructors !! dataConstructorIndex ^. T.dataConstructorParamTypes) !! paramIndex
            _ -> continue appState
        copy = continue $ appState & clipboard %~ case selection of
            TypeConstructorSelection Nothing -> clipboardTypeConstructor ?~ def ^. T.typeConstructor
            TypeConstructorSelection (Just paramIndex) ->
                clipboardType .~ (T.Var <$> (def ^? T.typeConstructor . T.typeConstructorParams . ix paramIndex))
            DataConstructorSelection dataConstructorIndex [] ->
                clipboardDataConstructor .~ dataConstructors ^? ix dataConstructorIndex
            DataConstructorSelection dataConstructorIndex (paramIndex : pathInParam) ->
                clipboardType .~ (maybeParam >>= getItemAtPathInType pathInParam) where
                    maybeParam = dataConstructors ^? ix dataConstructorIndex . T.dataConstructorParamTypes . ix paramIndex
        paste = case selection of
            TypeConstructorSelection Nothing -> case appState ^. clipboard . clipboardTypeConstructor of
                Just c -> modifyTypeDef typeDefKey (T.typeConstructor .~ c) appState
                Nothing -> continue appState
            TypeConstructorSelection (Just paramIndex) -> case appState ^. clipboard . clipboardType of
                Just (T.Var v) ->
                    modifyTypeDef typeDefKey (T.typeConstructor . T.typeConstructorParams . ix paramIndex .~ v) appState
                _ -> continue appState
            DataConstructorSelection dataConstructorIndex [] -> case appState ^. clipboard . clipboardDataConstructor of
                Just c -> modifyTypeDef typeDefKey (T.dataConstructors . ix dataConstructorIndex .~ c) appState
                Nothing -> continue appState
            DataConstructorSelection dataConstructorIndex (paramIndex : pathInParam) -> case appState ^. clipboard . clipboardType of
                Just t -> modifyTypeDef typeDefKey
                    (T.dataConstructors . ix dataConstructorIndex . T.dataConstructorParamTypes . ix paramIndex
                        %~ modifyAtPathInType pathInParam (const t))
                    appState
                Nothing -> continue appState
        undo = modifyDefHistory goBack
        redo = modifyDefHistory goForward
        modifyDefHistory modify = liftIO createAppState >>= continue where
            createAppState = handleTypeDefsChange $ appState
                & committedTypeDefs . ix typeDefKey .~ newDefHistory
                & committedLocations . present . _TypeDefView . typeDefViewSelection .~ newSelection
            newDefHistory = modify defHistory
            newSelection
                | newDef ^. T.typeConstructor /= def ^. T.typeConstructor || newDataConstructorCount == 0 =
                    TypeConstructorSelection Nothing
                | newDataConstructorCount /= dataConstructorCount =
                    DataConstructorSelection (newDataConstructorCount - 1) []
                | otherwise = case catMaybes $ zipWith (fmap . (,)) [0..] diffPaths of
                    [] -> selection
                    (dataConstructorIndex, path) : _ -> DataConstructorSelection dataConstructorIndex path
            newDef = view present newDefHistory
            newDataConstructorCount = length newDataConstructors
            newDataConstructors = newDef ^. T.dataConstructors
            diffPaths = zipWith getDiffPathBetweenDataConstructors newDataConstructors dataConstructors

commitDataConstructorEdit ::
    AppState
    -> TypeDefKey
    -> Int
    -> DataConstructor
    -> Int
    -> Path
    -> T.Type T.VarName TypeDefKey
    -> EventM AppResourceName (Next AppState)
commitDataConstructorEdit appState typeDefKey dataConstructorIndex dataConstructor paramIndex pathInParam t = appState
    & editState .~ NotEditing
    & committedLocations . present . _TypeDefView . typeDefViewSelection . pathInDataConstructor
        .~ (paramIndex : pathInParam)
    & modifyTypeDef typeDefKey (T.dataConstructors . ix dataConstructorIndex .~ newDataConstructor)
    where
        newDataConstructor = dataConstructor
            & T.dataConstructorParamTypes . ix paramIndex %~ modifyAtPathInType pathInParam (const t)

emptyEditor :: Editor String AppResourceName
emptyEditor = editor EditorName (Just 1) ""

getDataConstructors :: AppState -> TypeDefKey -> [DataConstructor]
getDataConstructors appState typeDefKey = getTypeDefs appState ^. ix typeDefKey . T.dataConstructors

setEditState :: AppState -> EditState -> EventM AppResourceName (Next AppState)
setEditState appState newEditState = continue $ appState & editState .~ newEditState

containsIgnoringCase :: String -> String -> Bool
containsIgnoringCase s1 s2 = map toLower s2 `isInfixOf` map toLower s1

handleEditorEventIgnoringAutocompleteControls :: Vty.Event
    -> Editor String AppResourceName
    -> EventM AppResourceName (Editor String AppResourceName)
handleEditorEventIgnoringAutocompleteControls event editor = case event of
    -- ignore up/down as they are used to control the autocomplete
    Vty.EvKey Vty.KUp [] -> pure editor
    Vty.EvKey Vty.KDown [] -> pure editor
    _ -> handleEditorEvent event editor

handleEventOnExprDefView :: AppState -> Vty.Event -> ExprDefViewLocation -> EventM AppResourceName (Next AppState)
handleEventOnExprDefView appState event (ExprDefViewLocation defKey selectionPath) = case currentEditState of
    Naming editor -> case event of
        Vty.EvKey Vty.KEsc [] -> cancelEdit appState
        Vty.EvKey Vty.KEnter [] -> commitDefName appState (head $ getEditContents editor) isValidExprName
        _ -> handleEditorEvent event editor >>= setEditState appState . Naming
    SelectionRenaming editor -> case event of
        Vty.EvKey Vty.KEsc [] -> cancelEdit appState
        Vty.EvKey Vty.KEnter [] -> commitSelectionRename $ head $ getEditContents editor
        _ -> do
            newEditor <- handleEditorEvent event editor
            setEditState appState $ SelectionRenaming newEditor
    EditingExpr editedExpr pathsToBeEdited editor maybeAutocompleteList -> case event of
        Vty.EvKey Vty.KEsc [] -> cancelEdit appState
        Vty.EvKey (Vty.KChar '\t') [] -> maybe (continue appState) (commitAutocompleteSelection editedExpr pathsToBeEdited) maybeAutocompleteList
        Vty.EvKey Vty.KEnter [] -> commitEditorContent editedExpr pathsToBeEdited editorContent
        Vty.EvKey (Vty.KChar c) [] | (c == 'λ' || c == '\\') && editorContent == "" ->
            editExprContainingSelection (const $ E.Fn $ pure (P.Wildcard, E.Hole)) ([0] NonEmpty.:| [[1]])
        _ -> do
            newEditor <- case event of
                Vty.EvKey (Vty.KChar '"') [] -> pure $ applyEdit edit editor where
                    edit textZipper
                        | editorContent == "" = moveLeft $ insertMany "\"\"" textZipper
                        | currentChar textZipper == Just '"' && previousChar textZipper /= Just '\\' = moveRight textZipper
                        | otherwise = insertChar '"' textZipper
                Vty.EvKey (Vty.KChar ' ') [] -> pure $
                    if "\"" `isPrefixOf` editorContent || elem ':' editorContent
                        then applyEdit (insertChar ' ') editor
                        else editor
                Vty.EvKey (Vty.KChar '\\') [] -> pure $ applyEdit (insertChar 'λ') editor
                _ -> handleEditorEventIgnoringAutocompleteControls event editor
            let newEditorContent = head $ getEditContents newEditor
            let editorContentChanged = newEditorContent /= editorContent
            let isMatch name = name `containsIgnoringCase` newEditorContent
            let search getName getType = mapMaybe $ \item -> case getName item of
                    Just name | isMatch label -> Just (label, item) where label = createLabel name (getType item)
                    _ -> Nothing
            let items = Vec.fromList $ case selected of
                    Expr _ -> fmap Expr <$> vars ++ primitives ++ defs ++ constructors where
                        vars = fmap E.Var <$> search Just (const Nothing) (getVarsAtPath selectionPath (view expr def))
                        primitives = fmap E.Primitive <$> search (Just . getDisplayName) (Just . getType) [minBound..]
                        defs = fmap E.Def <$> search (getExprName appState) (fmap nameTypeVars . getExprDefType) exprDefKeys
                        constructors = fmap E.Constructor <$> search (preview T.constructorName) getDataConstructorType dataConstructorKeys
                    Pattern _ -> do
                        typeDefKey <- typeDefKeys
                        T.DataConstructor constructorName paramTypes <- getDataConstructors typeDefKey
                        let constructorKey = T.DataConstructorKey typeDefKey constructorName
                        let label = createDataConstructorLabel constructorKey
                        let arity = length paramTypes
                        let wildcards = replicate arity P.Wildcard
                        [(label, Pattern $ P.Constructor constructorKey wildcards) | isMatch label]
            newAutocompleteList <- case maybeAutocompleteList of
                Just autocompleteList | not editorContentChanged -> Just <$> ListWidget.handleListEvent event autocompleteList
                _ -> pure $ if null items then Nothing else Just $ ListWidget.list AutocompleteName items 1
            setEditState appState $ EditingExpr editedExpr pathsToBeEdited newEditor newAutocompleteList
        where
            editorContent = head $ getEditContents editor
            typeDefKeys = getTypeDefKeys appState
            getExprDefType key = preview (Infer._Typed . Infer.typeTreeRootType) $
                createInferResult (currentTypeDefs Map.!) (view expr <$> currentExprDefs) key
            getDataConstructorType = T.getDataConstructorType (currentTypeDefs Map.!)
            dataConstructorKeys = typeDefKeys >>= getDataConstructorKeys
            getDataConstructorKeys typeDefKey = T.DataConstructorKey typeDefKey <$> getDataConstructorNames typeDefKey
            getDataConstructorNames typeDefKey = view T.dataConstructorName <$> getDataConstructors typeDefKey
            getDataConstructors typeDefKey = view T.dataConstructors $ currentTypeDefs Map.! typeDefKey
            createDataConstructorLabel key = createLabel (view T.constructorName key) (getDataConstructorType key)
            createLabel name maybeType = case maybeType of
                Just t -> name ++ ": " ++ printType appState t
                Nothing -> name
    NotEditing -> case event of
        Vty.EvKey Vty.KEnter [] -> goToDefinition
        Vty.EvKey (Vty.KChar 'g') [] -> goBackInLocationHistory appState
        Vty.EvKey (Vty.KChar 'G') [] -> goForwardInLocationHistory appState
        Vty.EvKey (Vty.KChar 'N') [] -> initiateRenameDefinition appState
        Vty.EvKey (Vty.KChar 'n') [] -> initiateRenameSelection
        Vty.EvKey Vty.KLeft [] -> selectParent
        Vty.EvKey Vty.KRight [] -> selectChild
        Vty.EvKey Vty.KUp [] -> selectPrev
        Vty.EvKey Vty.KDown [] -> selectNext
        Vty.EvKey (Vty.KChar 'j') [] -> selectParent
        Vty.EvKey (Vty.KChar 'l') [] -> selectChild
        Vty.EvKey (Vty.KChar 'i') [] -> selectPrev
        Vty.EvKey (Vty.KChar 'k') [] -> selectNext
        Vty.EvKey (Vty.KChar 'e') [] -> initiateSelectionEdit
        Vty.EvKey (Vty.KChar ')') [] -> callSelected
        Vty.EvKey (Vty.KChar '(') [] -> applyFnToSelected
        Vty.EvKey (Vty.KChar 'λ') [] -> wrapSelectedInFn
        Vty.EvKey (Vty.KChar '\\') [] -> wrapSelectedInFn
        Vty.EvKey (Vty.KChar '|') [] -> addAlternativeToSelected
        Vty.EvKey (Vty.KChar 'd') [] -> deleteSelected
        Vty.EvKey (Vty.KChar '\t') [] -> switchToNextWrappingStyle appState
        Vty.EvKey Vty.KBackTab [] -> switchToPrevWrappingStyle appState
        Vty.EvKey (Vty.KChar 'c') [] -> copy
        Vty.EvKey (Vty.KChar 'p') [] -> paste
        Vty.EvKey (Vty.KChar 'u') [] -> undo
        Vty.EvKey (Vty.KChar 'r') [] -> redo
        Vty.EvKey (Vty.KChar 'O') [] -> openNewTypeDef appState
        Vty.EvKey (Vty.KChar 'o') [] -> openNewExprDef appState
        Vty.EvKey (Vty.KChar 'q') [] -> halt appState
        _ -> continue appState
    _ -> error "invalid state"
    where
        currentTypeDefs = getTypeDefs appState
        currentExprDefs = getExprDefs appState
        exprDefKeys = Map.keys currentExprDefs
        def = currentExprDefs Map.! defKey
        currentEditState = view editState appState
        selectParent = select parentPath
        selectChild = select pathToFirstChildOfSelected
        selectPrev = select prevSiblingPath
        selectNext = select nextSiblingPath
        select path = if isJust $ getItemAtPath path then liftIO createNewAppState >>= continue else continue appState where
            createNewAppState = updateEvalResult $ appState
                & committedLocations . present . _ExprDefView . exprDefViewSelection .~ path
        parentPath = if null selectionPath then [] else init selectionPath
        pathToFirstChildOfSelected = selectionPath ++ [0]
        prevSiblingPath = if null selectionPath then [] else init selectionPath ++ [mod (last selectionPath - 1) siblingCount]
        nextSiblingPath = if null selectionPath then [] else init selectionPath ++ [mod (last selectionPath + 1) siblingCount]
        siblingCount = case getItemAtPath (init selectionPath) of
            Just (Expr (E.Fn alts)) -> 2 * length alts
            Just (Expr (E.Call _ _)) -> 2
            Just (Pattern (P.Constructor _ siblings)) -> length siblings
            _ -> 1
        selected = fromJustNote "selection path should be a valid path" $ getItemAtPath selectionPath
        getItemAtPath path = getItemAtPathInExpr path (view expr def)
        goToDefinition = case selected of
            Expr (E.Def defKey) | Map.member defKey currentExprDefs -> goToExprDef defKey appState
            Expr (E.Constructor dataConstructorKey) -> goToDataConstructor dataConstructorKey
            Pattern (P.Constructor dataConstructorKey _) -> goToDataConstructor dataConstructorKey
            _ -> continue appState
        goToDataConstructor (T.DataConstructorKey typeDefKey constructorName) =
            goToTypeDef typeDefKey selection appState where
                selection = case elemIndex constructorName dataConstructorNames of
                    Just dataConstructorIndex -> DataConstructorSelection dataConstructorIndex []
                    Nothing -> TypeConstructorSelection Nothing
                dataConstructorNames = view T.dataConstructorName <$> dataConstructors
                dataConstructors = typeDef ^. T.dataConstructors
                typeDef = currentTypeDefs Map.! typeDefKey
        initiateRenameSelection = case selected of
            Pattern (P.Var name) -> setEditState appState $ SelectionRenaming $ applyEdit gotoEOL $ editor EditorName (Just 1) name
            Expr (E.Var name) -> setEditState appState $ SelectionRenaming $ applyEdit gotoEOL $ editor EditorName (Just 1) name
            _ -> continue appState
        initiateSelectionEdit = setEditState appState $ EditingExpr (view expr def) (pure selectionPath) initialSelectionEditor Nothing
        initialSelectionEditor = applyEdit gotoEOL $ editor EditorName (Just 1) initialSelectionEditorContent
        initialSelectionEditorContent = case selected of
            Pattern p -> case p of
                P.Wildcard -> ""
                P.Var name -> name
                P.Constructor key _ -> view T.constructorName key
                P.Integer n -> show n
                P.String s -> show s
            Expr e -> case e of
                E.Hole -> ""
                E.Def key -> getExprNameOrUnnamed appState key
                E.Var name -> name
                E.Fn _ -> ""
                E.Call _ _ -> ""
                E.Constructor key -> view T.constructorName key
                E.Integer n -> show n
                E.String s -> show s
                E.Primitive p -> getDisplayName p
        commitSelectionRename editorContent = case selected of
            Pattern (P.Var name) | isValidVarName editorContent -> setExpr $ E.renameVar name editorContent (view expr def)
            Expr (E.Var name) | isValidVarName editorContent -> setExpr $ E.renameVar name editorContent (view expr def)
            _ -> continue appState
        commitEditorContent editedExpr (path NonEmpty.:| furtherPathsToBeEdited) editorContent = case readMaybe editorContent of
            Just int -> commitEdit path furtherPathsToBeEdited newExpr where
                newExpr = modifyAtPathInExpr path (const $ E.Integer int) (const $ P.Integer int) editedExpr
            _ | editorContent == "" || editorContent == "_" -> commitEdit path furtherPathsToBeEdited newExpr where
                newExpr = modifyAtPathInExpr path (const E.Hole) (const P.Wildcard) editedExpr
            _ | isValidVarName editorContent -> commitEdit path furtherPathsToBeEdited newExpr where
                newExpr = modifyAtPathInExpr path (const $ E.Var editorContent) (const $ P.Var editorContent) editedExpr
            _ -> case readMaybe editorContent of
                Just s -> commitEdit path furtherPathsToBeEdited newExpr where
                    newExpr = modifyAtPathInExpr path (const $ E.String s) (const $ P.String s) editedExpr
                _ -> continue appState
        commitAutocompleteSelection editedExpr (path NonEmpty.:| furtherPathsToBeEdited) autocompleteList =
            case ListWidget.listSelectedElement autocompleteList of
                Just (_, (_, selectedItem)) -> case selectedItem of
                    Expr expr -> commitEdit path furtherPathsToBeEdited newExpr where
                        newExpr = modifyAtPathInExpr path (const expr) id editedExpr
                    Pattern patt -> commitEdit path (newPathsToBeEdited ++ furtherPathsToBeEdited) newExpr where
                        newPathsToBeEdited = (path ++) <$> getWildcardPaths patt
                        newExpr = modifyAtPathInExpr path id (const patt) editedExpr
                _ -> continue appState
        commitEdit newSelectionPath furtherPathsToBeEdited newExpr = appState
            & editState .~ case NonEmpty.nonEmpty furtherPathsToBeEdited of
                Just paths -> EditingExpr newExpr paths emptyEditor Nothing
                Nothing -> NotEditing
            & committedLocations . present . _ExprDefView . exprDefViewSelection .~ newSelectionPath
            & modifyExprDef defKey (expr .~ newExpr)
        replaceSelected replacementIfExpr replacementIfPattern = modifySelected (const replacementIfExpr) (const replacementIfPattern)
        modifySelected modifyExpr modifyPattern = modifyAtPathInExpr selectionPath modifyExpr modifyPattern (view expr def)
        callSelected = editExprContainingSelection (`E.Call` E.Hole) (pure [1])
        applyFnToSelected = editExprContainingSelection (E.Hole `E.Call`) (pure [0])
        wrapSelectedInFn = editExprContainingSelection (\expr -> E.Fn $ pure (P.Wildcard, expr)) pathsToBeEdited where
            pathsToBeEdited = if isWrappingHole then pathToWildcard NonEmpty.:| [pathToHole] else pure pathToWildcard
            isWrappingHole = getItemAtPathInExpr pathToExprContainingSelection (view expr def) == Just (Expr E.Hole)
            pathToWildcard = [0]
            pathToHole = [1]
        editExprContainingSelection = editExpr pathToExprContainingSelection
        editExpr modificationPath modify pathsToBeEditedFromModificationPath =
            liftIO (updateDerivedState newAppState) >>= continue where
                newAppState = appState & editState .~ newEditState
                newEditState = EditingExpr editedExpr pathsToBeEdited emptyEditor Nothing
                editedExpr = modifyAtPathInExpr modificationPath modify id (view expr def)
                pathsToBeEdited = (modificationPath ++) <$> pathsToBeEditedFromModificationPath
        pathToExprContainingSelection = dropPatternPartOfPath (view expr def) selectionPath
        addAlternativeToSelected = maybe (continue appState) addAlternative (getContainingFunction selectionPath $ view expr def)
        addAlternative (fnPath, alts) = editExpr fnPath modify pathsToBeEditedFromFnPath where
            modify = const $ E.Fn $ alts <> pure (P.Wildcard, E.Hole)
            pathsToBeEditedFromFnPath = pathToWildcard NonEmpty.:| [pathToHole]
            pathToWildcard = [2 * newAltIndex]
            pathToHole = [2 * newAltIndex + 1]
            newAltIndex = length alts
        modifyExprAtPath path modify selectionPathInModifiedExpr = appState
            & committedLocations . present . _ExprDefView . exprDefViewSelection .~ path ++ selectionPathInModifiedExpr
            & modifyExprDef defKey (expr %~ modifyAtPathInExpr path modify id)
        deleteSelected = case selected of
            Expr E.Hole -> removeSelectedFromParent
            Pattern P.Wildcard -> removeSelectedFromParent
            _ -> setExpr $ replaceSelected E.Hole P.Wildcard
        removeSelectedFromParent = case viewR selectionPath of
            Just (parentPath, childIndex) -> case getItemAtPathInExpr parentPath (view expr def) of
                Just (Expr parent) -> modifyExprAtPath parentPath (const parentReplacement) selectionPathInParentReplacement where
                    (parentReplacement, selectionPathInParentReplacement) = case parent of
                        E.Fn alts -> case NonEmpty.nonEmpty $ removeItemAtIndex altIndex $ NonEmpty.toList alts of
                            Just altsWithoutSelected -> (E.Fn altsWithoutSelected, [newChildIndex]) where
                                newChildIndex = if altIndex == length altsWithoutSelected then childIndex - 2 else childIndex
                            Nothing -> (if selected == Pattern P.Wildcard then snd $ NonEmpty.head alts else E.Hole, [])
                        E.Call callee arg
                            | childIndex == 0 -> (arg, [])
                            | childIndex == 1 -> (callee, [])
                        _ -> error "invalid path"
                    altIndex = div childIndex 2
                _ -> continue appState
            Nothing -> continue appState
        setExpr newExpr = modifyExprDef defKey (expr .~ newExpr) (appState & editState .~ NotEditing)
        copy = continue $ appState & clipboard %~ case selected of
            Expr e -> clipboardExpr ?~ e
            Pattern p -> clipboardPattern ?~ p
        paste = setExpr $ modifySelected
            (maybe id const $ appState ^. clipboard . clipboardExpr)
            (maybe id const $ appState ^. clipboard . clipboardPattern)
        undo = modifyDefHistory goBack
        redo = modifyDefHistory goForward
        modifyDefHistory modify = liftIO createAppState >>= continue where
            createAppState = handleExprDefsChange $ appState
                & committedExprDefs . ix defKey .~ newDefHistory
                & committedLocations . present . _ExprDefView . exprDefViewSelection %~ modifySelectionPath
            newDefHistory = modify $ view committedExprDefs appState Map.! defKey
            modifySelectionPath = maybe id const $ getDiffPathBetweenExprs (view expr def) $ view (present . expr) newDefHistory

switchToNextWrappingStyle :: AppState -> EventM AppResourceName (Next AppState)
switchToNextWrappingStyle = modifyWrappingStyle getNext

switchToPrevWrappingStyle :: AppState -> EventM AppResourceName (Next AppState)
switchToPrevWrappingStyle = modifyWrappingStyle getPrev

modifyWrappingStyle :: (WrappingStyle -> WrappingStyle) -> AppState -> EventM AppResourceName (Next AppState)
modifyWrappingStyle modify appState = continue $ appState & wrappingStyle %~ modify

getNext :: (Eq a, Bounded a, Enum a) => a -> a
getNext current = if current == maxBound then minBound else succ current

getPrev :: (Eq a, Bounded a, Enum a) => a -> a
getPrev current = if current == minBound then maxBound else pred current

getWildcardPaths :: Pattern -> [Path]
getWildcardPaths patt = case patt of
    P.Wildcard -> [[]]
    P.Constructor _ children -> join $ zipWith (fmap . (:)) [0..] $ getWildcardPaths <$> children
    _ -> []

isValidTypeName :: Name -> Bool
isValidTypeName name = case name of
    firstChar : restOfChars -> isUpper firstChar && all isAlphaNum restOfChars
    _ -> False

isValidExprName :: Name -> Bool
isValidExprName name = case name of
    firstChar : restOfChars -> isLower firstChar && all isAlphaNum restOfChars
    _ -> False

isValidDataConstructorName :: Name -> Bool
isValidDataConstructorName = isValidTypeName

isValidTypeVarName :: Name -> Bool
isValidTypeVarName = isValidVarName

isValidVarName :: Name -> Bool
isValidVarName = isValidExprName

goToDef :: DefKey -> AppState -> EventM AppResourceName (Next AppState)
goToDef key = case key of
    TypeDefKey k -> goToTypeDef k (TypeConstructorSelection Nothing)
    ExprDefKey k -> goToExprDef k

goToTypeDef :: TypeDefKey -> TypeDefViewSelection -> AppState -> EventM AppResourceName (Next AppState)
goToTypeDef key = modifyLocationHistory . push . TypeDefView . TypeDefViewLocation key

goToExprDef :: ExprDefKey -> AppState -> EventM AppResourceName (Next AppState)
goToExprDef key = modifyLocationHistory $ push $ ExprDefView $ ExprDefViewLocation key []

goBackInLocationHistory :: AppState -> EventM AppResourceName (Next AppState)
goBackInLocationHistory = modifyLocationHistory goBack

goForwardInLocationHistory :: AppState -> EventM AppResourceName (Next AppState)
goForwardInLocationHistory = modifyLocationHistory goForward

modifyLocationHistory :: (History Location -> History Location) -> AppState -> EventM AppResourceName (Next AppState)
modifyLocationHistory modify appState = liftIO (updateDerivedState $ appState & committedLocations %~ modify) >>= continue

initiateRenameDefinition :: AppState -> EventM AppResourceName (Next AppState)
initiateRenameDefinition appState = continue $ appState & editState .~ Naming initialRenameEditor where
    initialRenameEditor = applyEdit gotoEOL $ editor EditorName (Just 1) $ fromMaybe "" $ getCurrentDefName appState

getCurrentDefName :: AppState -> Maybe Name
getCurrentDefName appState = case getLocation appState of
    TypeDefView loc -> join $ preview (ix (view typeDefKey loc) . T.typeConstructor . T.typeConstructorName) (getTypeDefs appState)
    ExprDefView loc -> join $ preview (ix (view exprDefKey loc) . name) (getExprDefs appState)
    _ -> Nothing

cancelEdit :: AppState -> EventM AppResourceName (Next AppState)
cancelEdit appState = liftIO (updateDerivedState (appState & editState .~ NotEditing)) >>= continue

commitDefName :: AppState -> String -> (String -> Bool) -> EventM AppResourceName (Next AppState)
commitDefName appState newName isValid = case newName of
    "" -> setCurrentDefName Nothing $ appState & editState .~ NotEditing
    _ | isValid newName -> setCurrentDefName (Just newName) $ appState & editState .~ NotEditing
    _ -> continue appState

setCurrentDefName :: Maybe Name -> AppState -> EventM AppResourceName (Next AppState)
setCurrentDefName newName appState = case getLocation appState of
    DefListView _ -> error "setCurrentDefName is not implemented for DefListView"
    TypeDefView loc -> modifyTypeDef (view typeDefKey loc) (T.typeConstructor . T.typeConstructorName .~ newName) appState
    ExprDefView loc -> modifyExprDef (view exprDefKey loc) (name .~ newName) appState

initiateAddTypeConstructorParam :: AppState -> ParamIndex -> EventM AppResourceName (Next AppState)
initiateAddTypeConstructorParam appState index =
    continue $ appState & editState .~ AddingTypeConstructorParam index (editor EditorName (Just 1) "")

initiateAddDataConstructor :: AppState -> DataConstructorIndex -> EventM AppResourceName (Next AppState)
initiateAddDataConstructor appState index =
    continue $ appState & editState .~ AddingDataConstructor index (editor EditorName (Just 1) "")

commitAddTypeConstructorParam :: AppState -> TypeDefKey -> Int -> Name -> EventM AppResourceName (Next AppState)
commitAddTypeConstructorParam = commitTypeConstructorParam insertAt

commitEditTypeConstructorParam :: AppState -> TypeDefKey -> Int -> Name -> EventM AppResourceName (Next AppState)
commitEditTypeConstructorParam = commitTypeConstructorParam $ set . ix

commitTypeConstructorParam :: (Int -> T.VarName -> [T.VarName] -> [T.VarName])
    -> AppState -> TypeDefKey -> Int -> Name -> EventM AppResourceName (Next AppState)
commitTypeConstructorParam modify appState typeDefKey index name =
    if isValidVarName name
    then appState
        & editState .~ NotEditing
        & committedLocations . present . _TypeDefView . typeDefViewSelection .~ TypeConstructorSelection (Just index)
        & modifyTypeDef typeDefKey (T.typeConstructor . T.typeConstructorParams %~ modify index name)
    else continue appState

commitRenameTypeVar :: AppState -> TypeDefKey -> T.VarName -> T.VarName -> EventM AppResourceName (Next AppState)
commitRenameTypeVar appState typeDefKey oldName newName =
    if isValidVarName newName
        then appState
            & editState .~ NotEditing
            & modifyTypeDef typeDefKey (T.renameTypeVar oldName newName)
        else continue appState

commitAddDataConstructor :: AppState -> TypeDefKey -> Int -> Name -> EventM AppResourceName (Next AppState)
commitAddDataConstructor appState typeDefKey index name =
    commitDataConstructorName (insertAt index (T.DataConstructor name [])) appState typeDefKey index name

commitRenameDataConstructor :: AppState -> TypeDefKey -> Int -> Name -> EventM AppResourceName (Next AppState)
commitRenameDataConstructor appState typeDefKey index name =
    commitDataConstructorName (ix index . T.dataConstructorName .~ name) appState typeDefKey index name

commitDataConstructorName :: ([DataConstructor] -> [DataConstructor])
    -> AppState -> TypeDefKey -> Int -> Name -> EventM AppResourceName (Next AppState)
commitDataConstructorName modify appState typeDefKey index name =
    if isValidDataConstructorName name
    then appState
        & editState .~ NotEditing
        & committedLocations . present . _TypeDefView . typeDefViewSelection .~ DataConstructorSelection index []
        & modifyTypeDef typeDefKey (T.dataConstructors %~ modify)
    else continue appState

modifyTypeDefs :: AppState -> (Map.Map TypeDefKey (History TypeDef) -> Map.Map TypeDefKey (History TypeDef)) -> EventM AppResourceName (Next AppState)
modifyTypeDefs appState modify = liftIO (handleTypeDefsChange $ appState & committedTypeDefs %~ modify) >>= continue

modifyExprDefs :: AppState -> (Map.Map ExprDefKey (History ExprDef) -> Map.Map ExprDefKey (History ExprDef)) -> EventM AppResourceName (Next AppState)
modifyExprDefs appState modify = liftIO (handleExprDefsChange $ appState & committedExprDefs %~ modify) >>= continue

modifyTypeDef :: TypeDefKey -> (TypeDef -> TypeDef) -> AppState -> EventM AppResourceName (Next AppState)
modifyTypeDef key modify appState = modifyTypeDefs appState $ ix key %~ History.step modify

modifyExprDef :: ExprDefKey -> (ExprDef -> ExprDef) -> AppState -> EventM AppResourceName (Next AppState)
modifyExprDef key modify appState = modifyExprDefs appState $ ix key %~ History.step modify

getVarsAtPath :: Path -> E.Expr d c -> [E.VarName]
getVarsAtPath path expr = case path of
    [] -> []
    edge:restOfPath -> case expr of
        E.Fn alts | odd edge -> getVars patt ++ getVarsAtPath restOfPath body where
            (patt, body) = alts NonEmpty.!! div edge 2
        E.Call callee _ | edge == 0 -> getVarsAtPath restOfPath callee
        E.Call _ arg | edge == 1 -> getVarsAtPath restOfPath arg
        _ -> error "invalid path"

getVars :: P.Pattern c -> [E.VarName]
getVars (P.Var name) = [name]
getVars (P.Constructor _ children) = children >>= getVars
getVars _ = []

modifyAtPathInType :: Path -> (T.Type v d -> T.Type v d) -> T.Type v d -> T.Type v d
modifyAtPathInType path modify t = case path of
    [] -> modify t
    edge:restOfPath -> case t of
        T.Call callee arg
            | edge == 0 -> T.Call (modifyAtPathInType restOfPath modify callee) arg
            | edge == 1 -> T.Call callee (modifyAtPathInType restOfPath modify arg)
        _ -> error "invalid path"

modifyAtPathInExpr :: Path -> (E.Expr d c -> E.Expr d c) -> (P.Pattern c -> P.Pattern c) -> E.Expr d c -> E.Expr d c
modifyAtPathInExpr path modifyExpr modifyPattern expr = case path of
    [] -> modifyExpr expr
    edge:restOfPath -> case expr of
        E.Fn alts -> E.Fn $ alts & ix (div edge 2) %~ modifyAlt where
            modifyAlt (patt, expr) =
                if even edge
                then (modifyAtPathInPattern restOfPath modifyPattern patt, expr)
                else (patt, modifyAtPathInExpr restOfPath modifyExpr modifyPattern expr)
        E.Call callee arg
            | edge == 0 -> E.Call (modifyAtPathInExpr restOfPath modifyExpr modifyPattern callee) arg
            | edge == 1 -> E.Call callee (modifyAtPathInExpr restOfPath modifyExpr modifyPattern arg)
        _ -> error "invalid path"

modifyAtPathInPattern :: Path -> (P.Pattern t -> P.Pattern t) -> P.Pattern t -> P.Pattern t
modifyAtPathInPattern path modify patt = case path of
    [] -> modify patt
    edge:restOfPath -> case patt of
        P.Constructor name children -> P.Constructor name $ children & ix edge %~ modifyAtPathInPattern restOfPath modify
        _ -> error "invalid path"

dropPatternPartOfPath :: E.Expr d c -> Path -> Path
dropPatternPartOfPath expr path = case path of
    [] -> []
    edge:restOfPath -> case expr of
        E.Fn alts -> if even edge then [] else edge : dropPatternPartOfPath (snd $ alts NonEmpty.!! div edge 2) restOfPath
        E.Call callee _ | edge == 0 -> 0 : dropPatternPartOfPath callee restOfPath
        E.Call _ arg | edge == 1 -> 1 : dropPatternPartOfPath arg restOfPath
        _ -> error "invalid path"

getContainingFunction :: Path -> E.Expr d c -> Maybe (Path, NonEmpty.NonEmpty (E.Alternative d c))
getContainingFunction selectionPath expr = case (expr, selectionPath) of
    (E.Fn alts, edge:restOfSelectionPath) | odd edge -> case getContainingFunction restOfSelectionPath childAtEdge of
        Just (path, alts) -> Just (edge : path, alts)
        _ -> Just ([], alts)
        where childAtEdge = snd $ alts NonEmpty.!! div edge 2
    (E.Fn alts, _) -> Just ([], alts)
    (E.Call callee _, 0:restOfSelectionPath) -> (_1 %~ (0:)) <$> getContainingFunction restOfSelectionPath callee
    (E.Call _ arg, 1:restOfSelectionPath) -> (_1 %~ (1:)) <$> getContainingFunction restOfSelectionPath arg
    _ -> Nothing

handleTypeDefsChange :: AppState -> IO AppState
handleTypeDefsChange appState = do
    writeTypeDefs appState
    updateDerivedState appState

handleExprDefsChange :: AppState -> IO AppState
handleExprDefsChange appState = do
    writeExprDefs appState
    updateDerivedState appState

updateDerivedState :: AppState -> IO AppState
updateDerivedState appState = do
    let getTypeDef = (getTypeDefs appState Map.!)
    let exprs = getExprs appState
    let location = getLocation appState
    maybeDerivedState <- traverse (createDerivedState getTypeDef exprs) (preview _ExprDefView location)
    return $ appState & derivedState .~ maybeDerivedState

updateEvalResult :: AppState -> IO AppState
updateEvalResult appState = do
    let exprs = getExprs appState
    let location = getLocation appState
    maybeEvalResult <- traverse (createEvalResult exprs) (preview _ExprDefView location)
    return $ appState & derivedState . _Just . evalResult %~ flip fromMaybe maybeEvalResult

getExprs :: AppState -> Map.Map ExprDefKey Expr
getExprs appState = view expr <$> getExprDefs appState

getTypeDefs :: AppState -> Map.Map TypeDefKey TypeDef
getTypeDefs appState = case (appState ^. editState, getLocation appState) of
    (AddingDataConstructor index editor, TypeDefView loc) -> committedDefs
        & ix (view typeDefKey loc)
        . T.dataConstructors
        %~ insertAt index (T.DataConstructor (head $ getEditContents editor) [])
    (EditingDataConstructorParam dataConstructorIndex dataConstructor _ _ _ _, TypeDefView loc) -> committedDefs
        & ix (view typeDefKey loc)
        . T.dataConstructors
        . ix dataConstructorIndex
        .~ dataConstructor
    _ -> committedDefs
    where committedDefs = view present <$> appState ^. committedTypeDefs

getExprDefs :: AppState -> Map.Map ExprDefKey ExprDef
getExprDefs appState = case (appState ^. editState, getLocation appState) of
    (EditingExpr e _ _ _, ExprDefView loc) -> committedDefs & ix (view exprDefKey loc) %~ expr .~ e
    _ -> committedDefs
    where committedDefs = view present <$> appState ^. committedExprDefs

getLocation :: AppState -> Location
getLocation appState = case appState ^. editState of
    AddingDataConstructor index _ ->
        committedLocation & _TypeDefView . typeDefViewSelection .~ DataConstructorSelection index []
    EditingDataConstructorParam dataConstructorIndex _ paramIndex path _ _ ->
        committedLocation & _TypeDefView . typeDefViewSelection
            .~ DataConstructorSelection dataConstructorIndex (paramIndex : path)
    EditingExpr _ path _ _ -> committedLocation & _ExprDefView . exprDefViewSelection .~ NonEmpty.head path
    _ -> committedLocation
    where committedLocation = appState ^. committedLocations . present

createDerivedState :: (TypeDefKey -> TypeDef) -> Map.Map ExprDefKey Expr -> ExprDefViewLocation -> IO DerivedState
createDerivedState getTypeDef defs location =
    DerivedState (createInferResult getTypeDef defs $ view exprDefKey location) <$> createEvalResult defs location

createInferResult :: (TypeDefKey -> TypeDef) -> Map.Map ExprDefKey Expr -> ExprDefKey -> InferResult
createInferResult getTypeDef defs defKey = Infer.inferType (T.getDataConstructorType getTypeDef) defs $ defs Map.! defKey

createEvalResult :: Map.Map ExprDefKey Expr -> ExprDefViewLocation -> IO EvalResult
createEvalResult exprs (ExprDefViewLocation defKey selectionPath) = do
    let maybeExpr = Map.lookup defKey exprs
    let maybeSelected = maybeExpr >>= getItemAtPathInExpr selectionPath
    let maybeSelectedExpr = maybeSelected >>= preview _Expr
    let maybeSelectionValue = maybeSelectedExpr >>= eval exprs
    timeoutResult <- timeout 10000 $ evaluate $ force maybeSelectionValue
    return $ case timeoutResult of
        Just (Just v) -> Value v
        Just Nothing -> Error
        Nothing -> Timeout
