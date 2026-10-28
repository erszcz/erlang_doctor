%% @doc ETS facade used by {@link tr}, with a pluggable backend.
%%
%% The module mirrors the subset of the `ets' interface that `tr' relies on.
%% Function names, arities, argument order, return values and exceptions are
%% the same as in `ets'. The `table/0' and `tid/0' types are the equivalents of
%% `ets:table/0' and `ets:tid/0'.
%%
%% == Backends ==
%%
%% {@link new/2} accepts a `{backend, Module}' option. With the default backend,
%% `ets', the table handle is the ETS table itself (an atom or a `t()'), exactly
%% as `ets:new/2' returns it, so nothing changes for existing callers and the
%% tables remain plain ETS tables. Any other backend is called as a module
%% exporting the same functions, and its handle is wrapped in an opaque
%% `{trdb, Module, Ref}' tuple. Every function here dispatches on the handle:
%% a tagged handle names its backend, anything else is an ETS handle.
%%
%% A backend module is expected to export `new/2' plus the operations below,
%% with the same signature as its `ets' counterpart except that the table is
%% the backend's own reference (so `foldl(Fun, Acc, Ref)' keeps ETS's argument
%% order). `fun2ms/1' and `file2tab/1' never reach the backend because they do
%% not operate on a table.
-module(trdb).

%% Tables
-export([new/2,
         delete/1, delete/2,
         delete_all_objects/1,
         info/1, info/2]).
%% Items
-export([insert/2,
         lookup/2,
         tab2list/1]).
%% Traversal and selection
-export([last/1,
         next/2,
         prev/2,
         select/1, select/2, select/3,
         fun2ms/1,
         foldl/3]).
%% Persistence
-export([tab2file/2,
         file2tab/1]).

-export_type([table/0, tid/0, handle/0]).

-type table_access() :: public | protected | private.
-type table_type() :: set | ordered_set | bag | duplicate_bag.
-type backend() :: ets | module().
-type new_option() :: table_type() | table_access() | named_table
                    | {keypos, pos_integer()}
                    | {backend, backend()}
                    | term().
-type table() :: atom() | tid() | handle().
-opaque tid() :: reference().
-opaque handle() :: {trdb, module(), term()}.
-type match_pattern() :: atom() | tuple().
-type match_spec() :: [{match_pattern(), [_], [_]}].
%% ETS continuation, or a backend continuation wrapped as {trdb_cont, ..., ...}.
-type continuation() :: term().

%% Tables

%% @doc Creates a new table. See {@link ets:new/2}.
%%
%% Recognises the `{backend, Module}' option, which is removed before the
%% remaining options reach the backend. With `ets' (the default) the return
%% value is the ETS table itself; any other backend returns an opaque handle.
-spec new(atom(), [new_option()]) -> table().
new(Name, Options) ->
    Backend = proplists:get_value(backend, Options, ets),
    StoreOpts = proplists:delete(backend, Options),
    case Backend of
        ets ->
            ets:new(Name, StoreOpts);
        Store when is_atom(Store) ->
            {trdb, Store, Store:new(Name, StoreOpts)}
    end.

%% @doc Deletes a table. See {@link ets:delete/1}.
-spec delete(table()) -> true.
delete({trdb, Store, Ref}) -> Store:delete(Ref);
delete(Tab) -> ets:delete(Tab).

%% @doc Deletes an object from a table. See {@link ets:delete/2}.
-spec delete(table(), term()) -> true.
delete({trdb, Store, Ref}, Key) -> Store:delete(Ref, Key);
delete(Tab, Key) -> ets:delete(Tab, Key).

%% @doc Deletes all objects from a table. See {@link ets:delete_all_objects/1}.
-spec delete_all_objects(table()) -> true.
delete_all_objects({trdb, Store, Ref}) -> Store:delete_all_objects(Ref);
delete_all_objects(Tab) -> ets:delete_all_objects(Tab).

%% @doc Returns information about a table. See {@link ets:info/1}.
-spec info(table()) -> [{atom(), term()}] | undefined.
info({trdb, Store, Ref}) -> Store:info(Ref);
info(Tab) -> ets:info(Tab).

%% @doc Returns a specific item of information about a table. See {@link ets:info/2}.
-spec info(table(), atom()) -> term() | undefined.
info({trdb, Store, Ref}, Item) -> Store:info(Ref, Item);
info(Tab, Item) -> ets:info(Tab, Item).

%% Items

%% @doc Inserts an object (or a list of objects) into a table. See {@link ets:insert/2}.
-spec insert(table(), term()) -> true.
insert({trdb, Store, Ref}, ObjectOrObjects) -> Store:insert(Ref, ObjectOrObjects);
insert(Tab, ObjectOrObjects) -> ets:insert(Tab, ObjectOrObjects).

%% @doc Returns the objects with the given key. See {@link ets:lookup/2}.
-spec lookup(table(), term()) -> [term()].
lookup({trdb, Store, Ref}, Key) -> Store:lookup(Ref, Key);
lookup(Tab, Key) -> ets:lookup(Tab, Key).

%% @doc Returns all objects in a table as a list. See {@link ets:tab2list/1}.
-spec tab2list(table()) -> [term()].
tab2list({trdb, Store, Ref}) -> Store:tab2list(Ref);
tab2list(Tab) -> ets:tab2list(Tab).

%% Traversal and selection

%% @doc Returns the last key in an `ordered_set' table. See {@link ets:last/1}.
-spec last(table()) -> term() | '$end_of_table'.
last({trdb, Store, Ref}) -> Store:last(Ref);
last(Tab) -> ets:last(Tab).

%% @doc Returns the key following `Key1'. See {@link ets:next/2}.
-spec next(table(), term()) -> term() | '$end_of_table'.
next({trdb, Store, Ref}, Key1) -> Store:next(Ref, Key1);
next(Tab, Key1) -> ets:next(Tab, Key1).

%% @doc Returns the key preceding `Key1'. See {@link ets:prev/2}.
-spec prev(table(), term()) -> term() | '$end_of_table'.
prev({trdb, Store, Ref}, Key1) -> Store:prev(Ref, Key1);
prev(Tab, Key1) -> ets:prev(Tab, Key1).

%% @doc Continues a match started with {@link select/3}. See {@link ets:select/1}.
%%
%% A continuation produced by a backend comes back wrapped, so it can be
%% handed straight back here; ETS continuations pass through untouched.
-spec select(continuation()) -> {[term()], continuation()} | '$end_of_table'.
select({trdb_cont, Store, Cont}) ->
    wrap_cont(Store, Store:select(Cont));
select('$end_of_table' = End) ->
    End;
select(Cont) ->
    ets:select(Cont).

%% @doc Returns the objects matching a match specification. See {@link ets:select/2}.
-spec select(table(), match_spec()) -> [term()].
select({trdb, Store, Ref}, MatchSpec) -> Store:select(Ref, MatchSpec);
select(Tab, MatchSpec) -> ets:select(Tab, MatchSpec).

%% @doc Returns at most `Limit' matching objects and a continuation. See {@link ets:select/3}.
-spec select(table(), match_spec(), pos_integer()) ->
          {[term()], continuation()} | '$end_of_table'.
select({trdb, Store, Ref}, MatchSpec, Limit) ->
    wrap_cont(Store, Store:select(Ref, MatchSpec, Limit));
select(Tab, MatchSpec, Limit) ->
    ets:select(Tab, MatchSpec, Limit).

%% @doc Translates a literal fun into a match specification. See {@link ets:fun2ms/1}.
%%
%% As with `ets:fun2ms/1', calls written literally in source are transformed at
%% compile time by the `ms_transform' parse transform; the function is a
%% fallback for funs passed at run time.
-spec fun2ms(LiteralFun) -> match_spec() when
      LiteralFun :: function().
fun2ms(LiteralFun) ->
    ets:fun2ms(LiteralFun).

%% @doc Folds a function over all objects of a table. See {@link ets:foldl/3}.
-spec foldl(Function, Acc0, table()) -> Acc1 when
      Function :: fun((Element :: term(), AccIn) -> AccOut),
      AccIn :: Acc0,
      AccOut :: Acc1,
      Acc0 :: term(),
      Acc1 :: term().
foldl(Function, Acc0, {trdb, Store, Ref}) -> Store:foldl(Function, Acc0, Ref);
foldl(Function, Acc0, Tab) -> ets:foldl(Function, Acc0, Tab).

%% Persistence

%% @doc Dumps a table to a file. See {@link ets:tab2file/2}.
-spec tab2file(table(), file:name_all()) -> ok | {error, term()}.
tab2file({trdb, Store, Ref}, Filename) -> Store:tab2file(Ref, Filename);
tab2file(Tab, Filename) -> ets:tab2file(Tab, Filename).

%% @doc Loads a table from a file. See {@link ets:file2tab/1}.
%%
%% The file format is ETS's, so this always uses the ETS backend; a backend
%% with its own persistence needs its own loader.
-spec file2tab(file:name_all()) -> {ok, table()} | {error, term()}.
file2tab(Filename) ->
    ets:file2tab(Filename).

%% Helpers

%% Tag the continuation of a non-ETS backend so select/1 can route it back.
%% '$end_of_table' is terminal and carries no backend.
wrap_cont(_Store, '$end_of_table') -> '$end_of_table';
wrap_cont(_Store, {Matches, '$end_of_table'}) when is_list(Matches) ->
    {Matches, '$end_of_table'};
wrap_cont(Store, {Matches, Cont}) when is_list(Matches) ->
    {Matches, {trdb_cont, Store, Cont}}.
