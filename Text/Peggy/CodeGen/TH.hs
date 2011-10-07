{-# LANGUAGE TemplateHaskell, TupleSections, FlexibleContexts #-}

module Text.Peggy.CodeGen.TH (
  genDecs,
  genQQ,
  ) where

import Control.Applicative
import Control.Monad
import qualified Data.HashTable.ST.Basic as HT
import Data.List
import qualified Data.ListLike as LL
import Data.Maybe
import Data.Typeable ()
-- import qualified Language.Haskell.Interpreter as HINT
import Language.Haskell.Meta
import Language.Haskell.TH
import Language.Haskell.TH.Syntax
import Language.Haskell.TH.Quote
import Text.Peggy.Prim
import Text.Peggy.Syntax
import Text.Peggy.SrcLoc
import Text.Peggy.Normalize
import Text.Peggy.LeftRec

genQQ :: Syntax -> (String, String) -> Q [Dec]
genQQ syn (qqName, parserName) = do
  sig <- sigD (mkName qqName) (conT ''QuasiQuoter)
  dat <- valD (varP $ mkName qqName) (normalB con) []
  return [sig, dat]
  where
    con = do
      e <- [| \str -> do
               loc <- location
               case parse $(varE $ mkName parserName) (SrcPos (loc_filename loc) 0 (fst $ loc_start loc) (snd $ loc_start loc)) str of
                 Left err -> error $ show err
                 Right a -> a
            |]
      u <- [| undefined |]
      recConE 'QuasiQuoter [ return ('quoteExp, e)
                           , return ('quoteDec, u)
                           , return ('quotePat, u)
                           , return ('quoteType, u)
                           ]

genDecs :: Syntax -> Q [Dec]
genDecs = generate . normalize . removeLeftRecursion

generate :: Syntax -> Q [Dec]
generate defs = do
  tblTypName <- newName "MemoTable"
  tblDatName <- newName "MemoTable"
  ps <- parsers tblTypName
  sequence $ [ defTbl tblTypName tblDatName
             , instTbl tblTypName tblDatName
             ] ++ ps
  where
  n = length defs
  
  defTbl :: Name -> Name -> DecQ
  defTbl tblTypName tblDatName = do
    s <- newName "s"
    str <- newName "str"
    dataD (cxt []) tblTypName [PlainTV str, PlainTV s] [con s str] []
    where
      con s str = recC tblDatName $ map toMem defs where
        toMem (Definition nont typ _) = do
          let tt | isExp nont = [t| ExpQ |]
                 | otherwise = parseType' typ
          t <- [t| HT.HashTable $(varT s) Int
                   (Result $(varT str) $tt) |]
          return (mkName $ "tbl_" ++nont, NotStrict, t)

  instTbl :: Name -> Name -> DecQ
  instTbl tblTypName tblDatName = do
    str <- newName "str"
    instanceD (cxt []) (conT ''MemoTable `appT` (conT tblTypName `appT` varT str))
      [ valD (varP 'newTable) (normalB body) [] ]
    where
    body = do
      names <- replicateM n (newName "t")
      doE $ map (\name -> bindS (varP name) [| HT.new |]) names
            ++ [ noBindS $ appsE [varE 'return, appsE $ conE tblDatName : map varE names]]

  parsers tblName = concat <$> mapM (gen tblName) defs

  isExp name = isJust $ find f defs where
    f (Definition nont typ _)
      | nont == name && head (words typ) == "Exp" = True
      | otherwise = False
  
  gen tblName (Definition nont typ e)
    | isExp nont = return $
        [ genSig tblName nont [t| ExpQ |]
        , funD (mkName nont)
          [clause [] (normalB [| memo $(varE $ mkName $ "tbl_" ++ nont) $ $(genP True e) |]) []]]
    | otherwise = return $
        [ genSig tblName nont (parseType' typ)
        , funD (mkName nont)
          [clause [] (normalB [| memo $(varE $ mkName $ "tbl_" ++ nont) $ $(genP False e) |]) []]]
  
  genSig tblName name typ = do
      str <- newName "str"
      s <- newName "s"
      sigD (mkName name) $
          forallT [PlainTV str, PlainTV s]
                  (cxt [classP ''LL.ListLike [varT str, conT ''Char]]) $
          conT ''Parser `appT`
          (conT tblName `appT` varT str) `appT`
          varT str `appT`
          varT s `appT`
          typ
  
  -- Generate Parser
  genP isE e = case (isE, e) of
    (False, Terminals False False str) ->
      [| string str |]
    (True,  Terminals False False str) ->
      [| lift <$> string str |]

    (False, TerminalSet rs) ->
      [| satisfy $(genRanges rs) |]
    (True,  TerminalSet rs) ->
      [| lift <$> satisfy $(genRanges rs) |]

    (False, TerminalCmp rs) ->
      [| satisfy $ not . $(genRanges rs) |]
    (True,  TerminalCmp rs) ->
      [| lift <$> (satisfy $ not . $(genRanges rs)) |]

    (False, TerminalAny) ->
      [| anyChar |]
    (True,  TerminalAny) ->
      [| lift <$> anyChar |]

    (False, NonTerminal nont) ->
      [| $(varE $ mkName nont) |]
    (True,  NonTerminal nont) ->
      [| lift <$> $(varE $ mkName nont) |]

    (False, Primitive name) ->
      [| $(varE $ mkName name) |]
    (True,  Primitive name) ->
      [| lift <$> $(varE $ mkName name) |]

    (False, Empty) ->
      [| return () |]
    (True,  Empty) ->
      [| lift <$> return () |]

    (False, Many f) ->
      [| many $(genP isE f) |]
    (True,  Many f) ->
      [| do eQs <- many $(genP isE f); return $ listE eQs |]

    (False, Some f) ->
      [| some $(genP isE f) |]
    (True,  Some f) ->
      [| do eQs <- some $(genP isE f); return $ listE eQs |]

    (False, Optional f) ->
      [| optional $(genP isE f) |]
    (True,  Optional f) ->
      [| do eQm <- optional $(genP isE f); case eQm of Nothing -> lift Nothing; Just q -> do ee <- q; lift (Just ee) |]

    (False, And f) ->
      [| expect $(genP isE f) |]
    (True,  And f) ->
      [| lift () <$ expect $(genP isE f) |]

    (False, Not f) ->
      [| unexpect $(genP isE f) |]
    (True,  Not f) ->
      [| lift () <$ unexpect $(genP isE f) |]

    (_, Token f) ->
      [| token $(varE skip) $(varE delimiter) ( $(genP isE f) ) |]

    -- simply, ignoreing result value
    (False, Named "_" f) ->
      [| () <$ $(genP isE f) |]
    (True,  Named "_" f) ->
      [| () <$ $(genP isE f) |]

    (_,  Named {}) -> error "named expr must has semantic."

    (False, Choice es) ->
      foldl1 (\a b -> [| $a <|> $b |]) $ map (genP isE) es
    (True,  Choice es) ->
      [| $(foldl1 (\a b -> [| $a <|> $b |]) $ map (genP isE) es) |]

    (False, Sequence es) -> do
      binds <- sequence $ genBinds 1 es
      let vn = length $ filter isBind binds
      doE $ do
        map return binds ++
          [ noBindS [| return $ $(tupE $ map (varE .mkName  . var) [1..vn]) |] ]
    (True,  Sequence es) -> do
      binds <- sequence $ genBinds 1 es
      let vn = length $ filter isBind binds
      doE $ do
        map return binds ++
          [ noBindS [| return $(foldl fmapE (lamN vn) $ map varE (names vn)) |] ]
      where
        names nn = map (mkName . var) [1..nn]
        lamN nn = lamE (map varP $ names n) $ tupE (map varE $ names nn)
        fmapE a b = [| $a `appE` $b |]

    -- Semancit Code

    -- Generates a Normal, value constructing code.
    -- It cannot has anti-quotes, values dependent on anti-quotes.
    (False, Semantic (Sequence es) cf) -> do
      -- TODO: make it syntax-sugar
      let needSt = hasPos cf || hasSpan cf
          needEd = hasSpan cf
          st = if needSt then [bindS (varP $ mkName stName) [| getPos |]] else []
          ed = if needEd then [bindS (varP $ mkName edName) [| getPos |]] else []
      doE $ st ++ genBinds 1 es ++ ed ++ [ noBindS [| return $(genCF isE cf) |] ]

    -- Generates a Exp constructing code.
    -- It can contain anti-quotes.
    -- Anti-quoted value must be Normal values.
    (True,  Semantic (Sequence es) cf) -> do
      bs <- sequence $ genBinds 1 es
      let vn = length $ filter isBind bs
      let gcf = genCF isE (ccf vn)
      doE $ map return bs ++
            [ noBindS [| return $ foldl appE (return $(lift =<< gcf)) $(eQnames vn) |]]
      where
        ccf nn = [Snippet $ "\\" ++ unwords (names nn ++ qames nn) ++ " -> ("] ++ cf ++ [Snippet ")"]
        eQnames nn =
          listE $ [ [| lift $(varE (mkName $ var i)) |] | i <- [1..nn]] ++
                  [ if hasAQ i cf
                    then [| varE $ mkName $(varE $ mkName $ var i) |]
                    else [| litE $ integerL 0 |]
                  | i <- [1..nn]]
        names nn = map var [1..nn]
        qames nn = map qar [1..nn]

    _ ->
      error $ "internal compile error: " ++ show e

    where
      genBinds _ [] = []
      genBinds ix (f:fs) = case f of
        Named "_" g ->
          noBindS (genP False g) :
          genBinds ix fs
        Named name g ->
          bindS (asP (mkName name) $ varP $ mkName (var ix)) (genP False g) :
          genBinds (ix+1) fs
        _ | shouldBind f ->
          bindS (varP $ mkName $ var ix) (genP False f) :
          genBinds (ix+1) fs
        _ ->
          noBindS (genP False f) :
          genBinds ix fs

  genRanges rs =
    let c = mkName "c" in
    lamE [varP c] $ foldl1 (\a b -> [| $a || $b |]) $ map (genRange c) rs
  genRange c (CharRange l h) =
    [| l <= $(varE c) && $(varE c) <= h |]
  genRange c (CharOne v) =
    [| $(varE c) == v |]

  genCF isE cf =
    case parsed of
      Left _ ->
        error $ "code fragment parse error: " ++ scf
      Right ret ->
        return ret
    where
    parsed = parseExp scf
    scf = concatMap toStr cf
    toStr (Snippet str) = str
    toStr (Argument a)  = var a
    toStr (AntiArgument nn)
      | not isE = error "Anti-quoter is not allowed in non-AQ parser"
      | otherwise = qar nn
    toStr ArgPos = "(LocPos " ++ stName ++ ")"
    toStr ArgSpan = "(LocSpan " ++ stName ++ " " ++ edName ++ ")"

  hasAQ x cf = not . null $ filter (isAQ x) cf where
    isAQ i (AntiArgument j) = i == j
    isAQ _ _ = False

  hasPos  = any (==ArgPos)
  hasSpan = any (==ArgSpan)

  isBind (BindS _ _) = True
  isBind _ = False

  shouldBind f = case f of
    Terminals _ _ _ -> False
    And _ -> False
    Not _ -> False
    Token g -> shouldBind g
    _ -> True

  skip = mkName "skip"
  delimiter = mkName "delimiter"

  var nn = "v" ++ show (nn :: Int)
  qar nn = "q" ++ show (nn :: Int)
  stName = "st_Pos"
  edName = "ed_Pos"

parseExp' str =
  case parseExp str of
    Left _ ->
      error $ "code fragment parse error: " ++ str
    Right ret ->
      return ret

parseType' typ =
  case parseType typ of
    Left err -> error $ "type parse error :" ++ typ ++ ", " ++ err
    Right t -> case t of
      -- GHC.Unit.() is not a type name. Is it a bug of haskell-src-meta?
      -- Use (TupleT 0) insted.
      ConT con | show con == "GHC.Unit.()" ->
        return $ TupleT 0
      _ ->
        return t

{-
-- Currently, it is not need
eval :: Typeable a => String -> Q a
eval str = do
  res <- runIO $ HINT.runInterpreter $ do
    HINT.setImports ["Prelude"]
    HINT.interpret str HINT.infer
  case res of
    Left err -> error $ show err
    Right ret -> return ret
-}
