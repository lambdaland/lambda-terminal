{-# LANGUAGE DeriveFunctor #-}

module Pattern where

type VarName = String
type ConstructorName = String

data Pattern constructorKey
    = Wildcard
    | Var VarName
    | Constructor constructorKey [Pattern constructorKey]
    | Integer Integer
    | String String
    deriving (Eq, Read, Show, Functor)

renameVar :: VarName -> VarName -> Pattern c -> Pattern c
renameVar oldName newName patt = case patt of
    Var name | name == oldName -> Var newName
    Constructor key children -> Constructor key $ renameVar oldName newName <$> children
    _ -> patt
