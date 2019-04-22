module Lumi.Components.Form.Internal where

import Prelude

import Control.MonadZero (class Alt, class Alternative, class MonadZero, class Plus)
import Control.Parallel.Class (class Parallel)
import Data.Array as Array
import Data.Either (either)
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype, un)
import Effect (Effect)
import Effect.Aff (Aff, runAff_)
import Effect.Exception (throwException)
import Lumi.Components.LabeledField (RequiredField, ValidationMessage)
import Prim.TypeError (class Warn, Above, Text)
import React.Basic (JSX)

data Tree a
  = Child
      { key :: Maybe String
      , child :: a
      }
  | Wrapper
      { key :: Maybe String
      , children :: Forest a
      }
  | Node
      { label :: a
      , key :: Maybe String
      , required :: RequiredField
      , validationError :: Maybe ValidationMessage
      , children :: Forest a
      }

derive instance functorTree :: Functor Tree

type Forest a = Array (Tree a)

-- | Traverse a tree bottom-up, removing all "internal" nodes (i.e. `Wrapper`
-- | or `Node` constructors) which have empty `children` arrays. In the case
-- | where there's nothing left in the tree after pruning, we return `Nothing`.
-- |
-- | We need to perform the traversal bottom-up because, for example, a subtree
-- | such as
-- |
-- | ```
-- | let
-- |   w children = Wrapper { key: Nothing, children }
-- | in
-- |   w [w []]
-- | ```
-- |
-- | should be pruned, but a top-down operation would not be able to identify
-- | such a subtree as prunable.
pruneTree :: forall a. Tree a -> Maybe (Tree a)
pruneTree =
  case _ of
    t@(Child _) ->
      Just t
    Wrapper r@{ children } ->
      case Array.mapMaybe pruneTree children of
        [] ->
          Nothing
        children' ->
          Just (Wrapper r { children = children' })
    Node r@{ children } ->
      case Array.mapMaybe pruneTree children of
        [] ->
          Nothing
        children' ->
          Just (Node r { children = children' })

-- | An applicative functor which can be used to build forms.
-- | Forms can be turned into components using the `build` function.
newtype FormBuilder props unvalidated result = FormBuilder
  (props
  -- ^ additional props
  -> unvalidated
  -- ^ the current value
  -> { edit :: ((unvalidated -> unvalidated) -> Effect Unit) -> Forest JSX
     , validate :: Maybe result
     })

derive instance newtypeFormBuilder :: Newtype (FormBuilder props unvalidated result) _

derive instance functorFormBuilder :: Functor (FormBuilder props unvalidated)

instance applyFormBuilder :: Apply (FormBuilder props unvalidated) where
  apply (FormBuilder f) (FormBuilder x) = FormBuilder \props unvalidated ->
    let { edit: editF, validate: validateF } = f props unvalidated
        { edit: editX, validate: validateX } = x props unvalidated
     in { edit: \k -> editF k <> editX k
        , validate: validateF <*> validateX
        }

instance applicativeFormBuilder :: Applicative (FormBuilder props unvalidated) where
  pure a = FormBuilder \_ _ ->
    { edit: mempty
    , validate: pure a
    }

instance parallelFormBuilder
  :: Warn
      ( Above
          (Text "The `Parallel` instance to `FormBuilder` is deprecated.")
          (Text "Prefer using `Form.parallel` and `Form.sequential` instead.")
      )
  => Parallel (FormBuilder props unvalidated) (SeqFormBuilder props unvalidated) where
  parallel (SeqFormBuilder (FormBuilder f)) = FormBuilder \props value ->
    let { edit, validate } = f props value
     in { edit: \onChange -> [ Wrapper { key: Just "seq", children: edit onChange } ]
        , validate: validate
        }
  sequential = SeqFormBuilder

parallel :: forall props value. String -> SeqFormBuilder props value ~> FormBuilder props value
parallel key (SeqFormBuilder (FormBuilder f)) = FormBuilder \props value ->
  let { edit, validate } = f props value
   in { edit: \onChange -> [ Wrapper { key: Just key, children: edit onChange } ]
      , validate: validate
      }

sequential :: forall props value. String -> FormBuilder props value ~> SeqFormBuilder props value
sequential key (FormBuilder f) = SeqFormBuilder $ FormBuilder \props value ->
  let { edit, validate } = f props value
   in { edit: \onChange -> [ Wrapper { key: Just key, children: edit onChange } ]
      , validate: validate
      }

-- | A form builder where each field depends on the validity of the previous ones.
-- | That is, every field is only displayed if all the previous ones are valid.
-- | Forms can be turned into components using the `build` function.
newtype SeqFormBuilder props unvalidated result =
  SeqFormBuilder (FormBuilder props unvalidated result)

derive instance newtypeSeqFormBuilder :: Newtype (SeqFormBuilder props unvalidated result) _
derive newtype instance functorSeqFormBuilder :: Functor (SeqFormBuilder props unvalidated)

instance applySeqFormBuilder :: Apply (SeqFormBuilder props unvalidated) where
  apply = ap

derive newtype instance applicativeSeqFormBuilder :: Applicative (SeqFormBuilder props unvalidated)

instance bindSeqFormBuilder :: Bind (SeqFormBuilder props unvalidated) where
  bind (SeqFormBuilder f) g =
    SeqFormBuilder $ FormBuilder \props unvalidated ->
      let { edit: editF, validate: validateF } = (un FormBuilder f) props unvalidated
      in
        case g <$> validateF of
          Nothing ->
            { edit: editF, validate: Nothing }
          Just (SeqFormBuilder x) ->
            let { edit: editX, validate: validateX } = (un FormBuilder x) props unvalidated
             in { edit: \k -> editF k <> editX k
                 , validate: validateX
                 }

instance monadSeqFormBuilder :: Monad (SeqFormBuilder props unvalidated)

instance altSeqFormBuilder :: Alt (SeqFormBuilder props unvalidated) where
  alt (SeqFormBuilder f) (SeqFormBuilder g) =
    SeqFormBuilder $ FormBuilder \props unvalidated ->
      let rf@{ edit: editF, validate: validateF } = un FormBuilder f props unvalidated
          rg@{ edit: editG, validate: validateG } = un FormBuilder g props unvalidated
       in case validateF, validateG of
            Just _, _ -> rf
            _, _ -> rg

instance plusSeqFormBuilder :: Plus (SeqFormBuilder props unvalidated) where
  empty = SeqFormBuilder $ FormBuilder \_ _ -> { edit: mempty, validate:  Nothing }

instance alternativeSeqFormBuilder :: Alternative (SeqFormBuilder props unvalidated)
instance monadZeroSeqFormBuilder :: MonadZero (SeqFormBuilder props unvalidated)

-- | Create a `FormBuilder` from a function which produces a form
-- | element as `JSX` and a validated result.
formBuilder
  :: forall props unvalidated a
   . (props
      -> unvalidated
      -> { edit :: ((unvalidated -> unvalidated) -> Effect Unit) -> JSX
         , validate :: Maybe a
         })
  -> FormBuilder props unvalidated a
formBuilder f =
  FormBuilder \props value ->
    let { edit, validate } = f props value
     in { edit: \onChange -> [ Child { key: Nothing, child: edit onChange } ]
        , validate: validate
        }

-- | The simplest way to create a `FormBuilder`. Create a `FormBuilder`
-- | provided a function that, given the current value and a change callback,
-- | renders a form element as `JSX`.
formBuilder_
  :: forall props a
   . (props -> a -> (a -> Effect Unit) -> JSX)
  -> FormBuilder props a a
formBuilder_ f = formBuilder \props value ->
  { edit: f props value <<< (_ <<< const)
  , validate: pure value
  }

-- | Invalidate a form, keeping its user interface but discarding the result
-- | and possibly changing its type.
invalidate :: forall props unvalidated a b. FormBuilder props unvalidated a -> FormBuilder props unvalidated b
invalidate (FormBuilder f) = FormBuilder \props value ->
  { edit: (f props value).edit
  , validate: Nothing
  }

-- | Revalidate the form, in order to display error messages or create
-- | a validated result.
revalidate
  :: forall props unvalidated result
   . FormBuilder props unvalidated result
  -> props
  -> unvalidated
  -> Maybe result
revalidate editor props value = (un FormBuilder editor props value).validate

-- | Listens for changes in a form's value and allows for performing
-- | asynchronous effects and additional value changes.
listen
  :: forall props unvalidated result
   . (unvalidated -> Aff (unvalidated -> unvalidated))
  -> FormBuilder props unvalidated result
  -> FormBuilder props unvalidated result
listen cb (FormBuilder f) = FormBuilder \props unvalidated ->
  let { edit, validate } = f props unvalidated
   in { edit: \onChange ->
          edit \update ->
            runAff_ (either throwException onChange) (map (_ <<< update) (cb (update unvalidated)))
      , validate
      }