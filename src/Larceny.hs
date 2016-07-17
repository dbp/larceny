{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}

module Larceny where

import           Control.Monad       (filterM)
import           Control.Monad.State (StateT, evalStateT)
import           Control.Monad.Trans (MonadIO, liftIO)
import           Data.Hashable       (Hashable)
import qualified Data.HashSet        as HS
import           Data.Map            (Map)
import qualified Data.Map            as M
import           Data.Maybe          (fromMaybe, mapMaybe)
import           Data.Monoid         ((<>))
import qualified Data.Set            as S
import           Data.Text           (Text)
import qualified Data.Text           as T
import qualified Data.Text.Lazy      as LT
import qualified Data.Text.Lazy.IO   as LT
import           Data.Traversable    (for)
import           System.Directory    (doesDirectoryExist, getDirectoryContents,
                                      listDirectory)
import           System.FilePath     (dropExtension, takeExtension)
import qualified Text.HTML.DOM       as D
import           Text.Read           (readMaybe)
import qualified Text.XML            as X
------------
import           Html                (plainNodes)


newtype Blank = Blank Text deriving (Eq, Show, Ord, Hashable)
type AttrArgs = Map Text Text
newtype Fill s = Fill { unFill :: AttrArgs
                               -> (Path, Template s)
                               -> Library s
                               -> StateT s IO Text }
type Substitutions s = Map Blank (Fill s)
type Path = [Text]
newtype Template s = Template { runTemplate :: Path
                                            -> Substitutions s
                                            -> Library s
                                            -> StateT s IO Text }
type Library s = Map Path (Template s)

data Overrides = Overrides { customPlainNodes :: HS.HashSet Text
                           , overridePlainNodes :: HS.HashSet Text}

defaultOverrides :: Overrides
defaultOverrides = Overrides mempty mempty


render :: Library s -> s -> Path -> IO (Maybe Text)
render l = renderWith l mempty

renderWith :: Library s -> Substitutions s -> s -> Path -> IO (Maybe Text)
renderWith l sub s p = M.lookup p l `for` \(Template run) -> evalStateT (run p rc) s
  where rc = defaultRenderContext l sub

loadTemplates :: FilePath -> Overrides -> IO (Library s)
loadTemplates path o =
  do tpls <- getAllTemplates path
     M.fromList <$> mapM (\file -> do content <- LT.readFile (path <> "/" <> file)
                                      return (mkPath file, parseWithOverrides o content))
                         tpls
  where mkPath p = T.splitOn "/" $ T.pack $ dropExtension p

getAllTemplates :: FilePath -> IO [FilePath]
getAllTemplates path =
  do cs <- listDirectory path
     let tpls = filter ((== ".tpl") . takeExtension) cs
     dirs <- filterM (doesDirectoryExist . (\d -> path <> "/" <> d)) cs
     rs <- mapM (\dir -> do r <- getAllTemplates (path <> "/" <> dir)
                            return $ map (\p -> dir <> "/" <> p) r) dirs
     return $ tpls ++ concat rs

need :: Path -> Substitutions s -> [Blank] -> Text -> Text
need pth m keys rest =
  let d = S.difference (S.fromList keys) (M.keysSet m)
  in if S.null d
     then rest
     else error $ "Template " <> show pth
          <> " is missing substitutions for blanks: " <> show d

add :: Substitutions s -> Template s -> Template s
add mouter tpl =
  Template (\pth rc -> runTemplate tpl pth rc { substitutions = ((substitutions rc) `M.union` mouter) })

textFill :: Text -> Fill s
textFill t = textFill' (return t)

textFill' :: StateT s IO Text -> Fill s
textFill' t = Fill $ \_m _t _l -> t

useAttrs :: (AttrArgs -> Fill s) -> Fill s
useAttrs f = Fill $ \atrs (pth, tpl) lib ->
     unFill (f atrs) atrs (pth, tpl) lib

data AttrError = AttrMissing
               | AttrUnparsable Text
               | AttrOtherError Text deriving (Eq, Show)

class FromAttr a where
  readAttr :: Maybe Text -> Either AttrError a

instance FromAttr Text where
  readAttr = maybe (Left AttrMissing) Right
instance FromAttr Int where
  readAttr (Just attr) = maybe (Left $ AttrUnparsable "Int") Right $ readMaybe $ T.unpack attr
  readAttr Nothing = Left AttrMissing
instance FromAttr a => FromAttr (Maybe a) where
  readAttr = traverse $ readAttr . Just

a :: FromAttr a => Text -> (a -> b) -> AttrArgs -> b
a attrName k attrs =
  let mAttr = M.lookup attrName attrs in
  k (either (error . T.unpack . attrError) id (readAttr mAttr))
  where attrError AttrMissing        = "Attribute error: Unable to find attribute \"" <>
                                       attrName <> "\"."
        attrError (AttrUnparsable t) = "Attribute error: Unable to parse attribute \""
                                       <> attrName <> "\" as type " <> t <> "."
        attrError (AttrOtherError t) = "Attribute error: " <> t

(%) :: (a -> AttrArgs -> b) -> (b -> AttrArgs -> c) ->  a -> AttrArgs -> c
(%) f1 f2 fun attrs = f2 (f1 fun attrs) attrs

mapSubs :: (a -> Substitutions s)
        -> [a]
        -> Fill s
mapSubs f xs = Fill $ \_attrs (pth, tpl) lib ->
    T.concat <$>  mapM (\n -> runTemplate tpl pth (f n) lib) xs

mapSubs' :: (a -> StateT s IO (Substitutions s)) -> [a] -> Fill s
mapSubs' f xs = Fill $
  \_m (pth, tpl) lib ->
    T.concat <$>  mapM (\x -> do
                           s' <- f x
                           runTemplate tpl pth s' lib) xs

subs :: [(Text, Fill s)] -> Substitutions s
subs = M.fromList . map (\(x, y) -> (Blank x, y))

fillChildren :: Fill s
fillChildren = fillChildrenWith mempty

fillChildrenWith :: Substitutions s -> Fill s
fillChildrenWith m = maybeFillChildrenWith (Just m)

fillChildrenWith' :: StateT s IO (Substitutions s) -> Fill s
fillChildrenWith' m = maybeFillChildrenWith' (Just <$> m)

maybeFillChildrenWith :: Maybe (Substitutions s) -> Fill s
maybeFillChildrenWith Nothing = textFill ""
maybeFillChildrenWith (Just s) = Fill $ \m (pth, Template tpl) l ->
  tpl pth s l

maybeFillChildrenWith' :: StateT s IO (Maybe (Substitutions s)) -> Fill s
maybeFillChildrenWith' sMSubs = Fill $ \m (pth, Template tpl) l -> do
  mSubs <- sMSubs
  case mSubs of
    Nothing -> return ""
    Just s  -> tpl pth s l

parseWithOverrides :: Overrides -> LT.Text -> Template s
parseWithOverrides o t =
  let (X.Document _ (X.Element _ _ nodes) _) = D.parseLT ("<div>" <> t <> "</div>")
  in mk o nodes

parse :: LT.Text -> Template s
parse = parseWithOverrides defaultOverrides

mk :: Overrides -> [X.Node] -> Template s
mk o nodes = let unbound = findUnbound o nodes
           in Template $ \pth rc ->
                need pth (substitutions rc) (map Blank unbound) <$>
                (T.concat <$> process pth rc unbound nodes)

fillIn :: Text -> Substitutions s -> Fill s
fillIn tn m =
  fromMaybe
     (error $ "Missing fill for blank: \"" <> T.unpack tn <> "\"")
     (M.lookup (Blank tn) m)

process :: Path -> RenderContext s -> [Text] -> [X.Node] -> StateT s IO [Text]
process _ _ _ [] = return []
process pth rc unbound (X.NodeElement (X.Element "bind" atr kids):ns) =
  let tagName = atr M.! "tag"
      newSubs = subs [(tagName, Fill $ \_a _t _l -> runTemplate (mk kids) pth m l)] in
  process pth (newSubs `M.union` m) l unbound ns
process pth m l unbound (n:ns) = do
  processedNode <-
    case n of
      X.NodeElement (X.Element "apply" atr kids) -> processApply pth rc atr kids
      X.NodeElement (X.Element tn atr kids) | HS.member (X.nameLocalName tn) os
                                                 -> processFancy pth rc tn atr kids
      X.NodeElement (X.Element tn atr kids) | HS.member (X.nameLocalName tn) plainNodes
                                                 -> processPlain pth rc unbound tn atr kids
      X.NodeElement (X.Element tn atr kids)      -> processFancy pth rc tn atr kids
      X.NodeContent t                            -> return [t]
      X.NodeComment c                            -> return ["<!--" <> c <> "-->"]
      X.NodeInstruction _                        -> return []
  restOfNodes <- process pth rc unbound ns
  return $ processedNode ++ restOfNodes

-- Add the open tag and attributes, process the children, then close
-- the tag.
processPlain :: Path -> RenderContext s -> [Text] ->
                 X.Name -> Map X.Name Text -> [X.Node] -> StateT s IO [Text]
processPlain pth rc unbound tn atr kids = do
  atrs <- attrsToText atr
  processed <- process pth rc unbound kids
  let tagName = X.nameLocalName tn
  return $ ["<" <> tagName <> atrs <> ">"]
           ++ processed
           ++ ["</" <> tagName <> ">"]
  where attrsToText attrs = T.concat <$> mapM attrToText (M.toList attrs)
        attrToText (k,v) =
          let name = X.nameLocalName k in
          case mUnboundAttr (k,v) of
            Just hole -> do filledIn <- unFill (fillIn hole m) mempty ([], mk []) l
                            return $ " " <> name <> "=\"" <> filledIn  <> "\""
            Nothing   -> return $ " " <> name <> "=\"" <> v <> "\""

-- Look up the Fill for the hole.  Apply the Fill to a map of
-- attributes, a Template made from the child nodes (adding in the
-- outer substitution) and the library.
processFancy :: Path -> RenderContext s ->
                X.Name -> Map X.Name Text -> [X.Node] -> StateT s IO [Text]
processFancy pth rc tn atr kids =
  let tagName = X.nameLocalName tn in
  sequence [ unFill (fillIn tagName m) (M.mapKeys X.nameLocalName atr) (pth, add m (mk kids)) l

-- Look up the template that's supposed to be applied in the library,
-- create a substitution for the content hole using the child elements
-- of the apply tag, then run the template with that substitution
-- combined with outer substitution and the library. Phew.
processApply :: Path -> RenderContext s ->
                 Map X.Name Text -> [X.Node] -> StateT s IO [Text]
processApply pth rc atr kids = do
  let tplPath = T.splitOn "/" $ fromMaybe (error "No template name given.")
                                          (M.lookup "template" atr)
  let (absolutePath, tplToApply) = case findTemplate (init pth) tplPath of
                                    (_, Nothing) -> error $ "Couldn't find " <> show tplPath <> " relative to " <> show pth <> "."
                                    (targetPath, Just tpl) -> (targetPath, tpl)
  contentTpl <- runTemplate (mk kids) pth m l
  let contentSub = subs [("apply-content",
                        textFill contentTpl)]
  sequence [ runTemplate tplToApply absolutePath (contentSub `M.union` m) l ]
  where findTemplate [] targetPath = (targetPath, M.lookup targetPath l)
        findTemplate pth' targetPath =
          case M.lookup (pth' ++ targetPath) l of
            Just tpl -> (pth' ++ targetPath, Just tpl)
            Nothing -> findTemplate (init pth') targetPath

findUnbound :: Overrides -> [X.Node] -> [Text]
findUnbound _ [] = []
findUnbound o (X.NodeElement (X.Element name atr kids):ns) =
     let os = overridePlainNodes o
         tn = X.nameLocalName name in
     if tn == "apply" || tn == "bind" || HS.member tn plainNodes
     then
       if HS.member tn os
       then tn : findUnboundAttrs atr ++ findUnbound o ns
       else findUnboundAttrs atr ++ findUnbound o kids
     else tn : findUnboundAttrs atr ++ findUnbound o ns
findUnbound o (_:ns) = findUnbound o ns

findUnboundAttrs :: Map X.Name Text -> [Text]
findUnboundAttrs atrs = mapMaybe mUnboundAttr (M.toList atrs)

mUnboundAttr :: (X.Name, Text) -> Maybe Text
mUnboundAttr (_, value) = do
  endVal <- T.stripPrefix "${" value
  T.stripSuffix "}" endVal


{-# ANN module ("HLint: ignore Redundant lambda" :: String) #-}
{-# ANN module ("HLint: ignore Use first" :: String) #-}
