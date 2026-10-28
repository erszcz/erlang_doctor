%% @doc ETS facade used by {@link tr}.
%%
%% The module mirrors the subset of the `ets' interface that `tr' relies on.
%% Function names, arities, argument order, return values and exceptions are
%% the same as in `ets', and every function delegates to its `ets' counterpart
%% (the flooring function `fun2ms/1' included). The `table/0' and `tid/0' types
%% are the equivalents of `ets:table/0' and `ets:tid/0'.
%%
%% `tr' therefore never calls `ets' directly: it goes through `trdb', which
%% can be given a different backing store without touching `tr'.
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

-export_type([table/0, tid/0]).

-type table_access() :: public | protected | private.
-type table() :: atom() | tid().
-type table_type() :: set | ordered_set | bag | duplicate_bag.
-type new_options() :: [table_type() | table_access() | named_table | {keypos, pos_integer()} | term()].
-opaque tid() :: reference().
-type match_pattern() :: atom() | tuple().
-type match_spec() :: [{match_pattern(), [_], [_]}].
%% Opaque continuation returned by select/3 and consumed by select/1.
-type continuation() :: ets:continuation().

%% Tables

%% @doc Creates a new table. See {@link ets:new/2}.
-spec new(atom(), new_options()) -> table().
new(Name, Options) ->
    ets:new(Name, Options).

%% @doc Deletes a table. See {@link ets:delete/1}.
-spec delete(table()) -> true.
delete(Tab) ->
    ets:delete(Tab).

%% @doc Deletes an object from a table. See {@link ets:delete/2}.
-spec delete(table(), term()) -> true.
delete(Tab, Key) ->
    ets:delete(Tab, Key).

%% @doc Deletes all objects from a table. See {@link ets:delete_all_objects/1}.
-spec delete_all_objects(table()) -> true.
delete_all_objects(Tab) ->
    ets:delete_all_objects(Tab).

%% @doc Returns information about a table. See {@link ets:info/1}.
-spec info(table()) -> [{atom(), term()}] | undefined.
info(Tab) ->
    ets:info(Tab).

%% @doc Returns a specific item of information about a table. See {@link ets:info/2}.
-spec info(table(), atom()) -> term() | undefined.
info(Tab, Item) ->
    ets:info(Tab, Item).

%% Items

%% @doc Inserts an object (or a list of objects) into a table. See {@link ets:insert/2}.
-spec insert(table(), term()) -> true.
insert(Tab, ObjectOrObjects) ->
    ets:insert(Tab, ObjectOrObjects).

%% @doc Returns the objects with the given key. See {@link ets:lookup/2}.
-spec lookup(table(), term()) -> [term()].
lookup(Tab, Key) ->
    ets:lookup(Tab, Key).

%% @doc Returns all objects in a table as a list. See {@link ets:tab2list/1}.
-spec tab2list(table()) -> [term()].
tab2list(Tab) ->
    ets:tab2list(Tab).

%% Traversal and selection

%% @doc Returns the last key in an `ordered_set' table. See {@link ets:last/1}.
-spec last(table()) -> term() | '$end_of_table'.
last(Tab) ->
    ets:last(Tab).

%% @doc Returns the key following `Key1'. See {@link ets:next/2}.
-spec next(table(), term()) -> term() | '$end_of_table'.
next(Tab, Key1) ->
    ets:next(Tab, Key1).

%% @doc Returns the key preceding `Key1'. See {@link ets:prev/2}.
-spec prev(table(), term()) -> term() | '$end_of_table'.
prev(Tab, Key1) ->
    ets:prev(Tab, Key1).

%% @doc Continues a match started with {@link select/3}. See {@link ets:select/1}.
-spec select(continuation()) -> {[term()], continuation()} | '$end_of_table'.
select(Continuation) ->
    ets:select(Continuation).

%% @doc Returns the objects matching a match specification. See {@link ets:select/2}.
-spec select(table(), match_spec()) -> [term()].
select(Tab, MatchSpec) ->
    ets:select(Tab, MatchSpec).

%% @doc Returns at most `Limit' matching objects and a continuation. See {@link ets:select/3}.
-spec select(table(), match_spec(), pos_integer()) ->
          {[term()], continuation()} | '$end_of_table'.
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
foldl(Function, Acc0, Tab) ->
    ets:foldl(Function, Acc0, Tab).

%% Persistence

%% @doc Dumps a table to a file. See {@link ets:tab2file/2}.
-spec tab2file(table(), file:name_all()) -> ok | {error, term()}.
tab2file(Tab, Filename) ->
    ets:tab2file(Tab, Filename).

%% @doc Loads a table from a file. See {@link ets:file2tab/1}.
-spec file2tab(file:name_all()) -> {ok, table()} | {error, term()}.
file2tab(Filename) ->
    ets:file2tab(Filename).
