%% @doc SQLite backend for {@link trdb}.
%%
%% Implements the {@link trdb} backend contract on top of SQLite, through the
%% `esqlite' NIF. {@link trdb:new/2} with `{backend, trdb_sqlite}' returns a
%% handle whose reference is a `gen_server' owning one SQLite connection:
%%
%% ```erlang
%% Tab = trdb:new(traces, [named_table, public, ordered_set, {keypos, 2},
%%                         {backend, trdb_sqlite}]),
%% ```
%%
%% == Storage ==
%%
%% Rows are stored as typed columns rather than opaque terms, so the trace
%% table can be queried with SQL directly:
%%
%% <ul>
%%  <li>`idx' - `#tr.index', the primary key, `INTEGER'</li>
%%  <li>`pid' - `pid_to_list/1' text, `TEXT'</li>
%%  <li>`event' - `TEXT'</li>
%%  <li>`module', `func', `arity' - the MFA, `NULL' for messages</li>
%%  <li>`data' - `term_to_binary/1' blob</li>
%%  <li>`ts' - `INTEGER'</li>
%%  <li>`info' - `term_to_binary/1' blob</li>
%% </ul>
%%
%% Only `#tr{}' objects are accepted, which is what {@link tr} stores in its
%% trace table. The helper tables `tr' builds for call-tree statistics are
%% different records and must stay on another backend.
%%
%% Keys must be non-negative integers, so `ordered_set' ordering matches ETS
%% for the trace table. `bag' and `duplicate_bag' are not supported.
%%
%% `esqlite' is a soft dependency. It is not declared in this application's
%% `deps' (it would force a native dependency on every user of
%% `erlang_doctor'), it is not listed in `erlang_doctor.app' `applications'
%% (it has no supervision tree, and requiring it at startup would break
%% applications that start `erlang_doctor' alone), and it is loaded lazily on
%% first use. An application enabling this backend adds `esqlite' to its own
%% dependencies; here it is a test-profile dependency.
%%
%% A table lives in memory unless `{file, Path}' is passed to {@link new/2}.
%% A file-backed table keeps its rows across restarts; {@link delete/1} drops
%% them, {@link delete_all_objects/1} does not.
%%
%% == Limits ==
%%
%% Pids are stored as text (`pid_to_list/1'), so a row can only be read back on
%% the node that wrote it; traces are local, which is what `tr' records.
%%
%% `select/2,3' evaluates the match specification in Erlang
%% (`ets:match_spec_run/2') over rows fetched from SQLite, so results are
%% exact but filtering is not pushed down to the database. `public' is accepted
%% but not enforced: any caller holding the handle can write.
-module(trdb_sqlite).

-behaviour(gen_server).

%% trdb backend API
-export([new/2,
         delete/1, delete/2,
         delete_all_objects/1,
         info/1, info/2,
         insert/2,
         lookup/2,
         tab2list/1,
         last/1,
         next/2,
         prev/2,
         select/1, select/2, select/3,
         foldl/3,
         tab2file/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("tr.hrl").

-type tr() :: #tr{}.

-define(BATCH, 1000).           % rows fetched per round trip
-define(TIMEOUT, 30_000).

-record(st, {name :: atom(),
             table :: string(),  % quoted SQL table name
             db :: term(),       % esqlite3 handle
             keypos :: pos_integer(),
             type :: set | ordered_set,
             protection :: public | protected | private,
             named_table :: boolean(),
             owner :: pid()}).

%% Backend API

%% @doc Opens a table. Options: `named_table', `public' | `protected' |
%% `private', `set' | `ordered_set', `{keypos, Pos}' and `{file, Path}'.
-spec new(atom(), [term()]) -> pid().
new(Name, Options) when is_atom(Name), is_list(Options) ->
    %% The server is linked (a table should die with its owner, as an ETS table
    %% does), so a failing init would kill the caller with an exit signal
    %% before start_link could return {error, Reason}. Trap exits across the
    %% call, drop the matching signal, and raise the error here instead.
    Trapping = process_flag(trap_exit, true),
    Result = gen_server:start_link(?MODULE, {Name, Options}, []),
    process_flag(trap_exit, Trapping),
    case Result of
        {ok, Pid} -> Pid;
        {error, Reason} -> flush_exit(Reason), error(unwrap_crash(Reason))
    end.

flush_exit(Reason) ->
    receive {'EXIT', _Pid, Reason} -> ok after 0 -> ok end.

%% A crash in init/1 comes back as {Reason, Stacktrace}; raise the reason.
unwrap_crash({Reason, [{M, F, A, _} | _]}) when is_atom(M), is_atom(F), is_integer(A) ->
    Reason;
unwrap_crash(Reason) ->
    Reason.

%% @doc Closes the table and drops its rows.
-spec delete(pid()) -> true.
delete(Ref) ->
    _ = catch call(Ref, delete_table),
    stop(Ref),
    true.

%% @doc Deletes the object with the given key.
-spec delete(pid(), term()) -> true.
delete(Ref, Key) ->
    call(Ref, {delete, Key}),
    true.

%% @doc Deletes all objects, keeping the table.
-spec delete_all_objects(pid()) -> true.
delete_all_objects(Ref) ->
    call(Ref, delete_all_objects),
    true.

%% @doc Returns information about the table, or `undefined' if it was closed.
-spec info(pid()) -> [{atom(), term()}] | undefined.
info(Ref) ->
    try
        gen_server:call(Ref, info, ?TIMEOUT)
    catch
        exit:_ -> undefined
    end.

%% @doc Returns one information item about the table, or `undefined'.
-spec info(pid(), atom()) -> term() | undefined.
info(Ref, Item) ->
    case info(Ref) of
        undefined -> undefined;
        Info -> proplists:get_value(Item, Info)
    end.

%% @doc Inserts an object or a list of objects. Existing keys are replaced.
-spec insert(pid(), tr() | [tr()]) -> true.
insert(Ref, Objects) when is_list(Objects) ->
    call(Ref, {insert_many, Objects}),
    true;
insert(Ref, Object) ->
    call(Ref, {insert_one, Object}),
    true.

%% @doc Returns the object with the given key, or `[]'.
-spec lookup(pid(), term()) -> [tr()].
lookup(Ref, Key) ->
    call(Ref, {lookup, Key}).

%% @doc Returns all objects in key order.
-spec tab2list(pid()) -> [tr()].
tab2list(Ref) ->
    lists:reverse(foldl(fun(Object, Acc) -> [Object | Acc] end, [], Ref)).

%% @doc Returns the greatest key, or `'$end_of_table''.
-spec last(pid()) -> term() | '$end_of_table'.
last(Ref) ->
    call(Ref, last).

%% @doc Returns the smallest key greater than `Key1', or `'$end_of_table''.
-spec next(pid(), term()) -> term() | '$end_of_table'.
next(Ref, Key1) ->
    call(Ref, {next, Key1}).

%% @doc Returns the greatest key less than `Key1', or `'$end_of_table''.
-spec prev(pid(), term()) -> term() | '$end_of_table'.
prev(Ref, Key1) ->
    call(Ref, {prev, Key1}).

%% @doc Continues a match started with {@link select/3}.
-spec select(term()) -> {[term()], term()} | '$end_of_table'.
select({trdb_sqlite_cont, Ref, Cursor, Compiled, Limit}) ->
    {Matches, Next} = call(Ref, {select, Compiled, Cursor, Limit}),
    {Matches, cont(Ref, Next, Compiled, Limit)}.

%% @doc Returns all objects matching the match specification, in key order.
-spec select(pid(), list()) -> [term()].
select(Ref, MatchSpec) ->
    select_all(Ref, ets:match_spec_compile(MatchSpec), none, []).

%% @doc Returns at most `Limit' matches and a continuation.
-spec select(pid(), list(), pos_integer()) ->
          {[term()], term()} | '$end_of_table'.
select(Ref, MatchSpec, Limit) ->
    Compiled = ets:match_spec_compile(MatchSpec),
    {Matches, Next} = call(Ref, {select, Compiled, none, Limit}),
    {Matches, cont(Ref, Next, Compiled, Limit)}.

%% @doc Folds over all objects in key order, like `ets:foldl/3'.
-spec foldl(fun((term(), term()) -> term()), term(), pid()) -> term().
foldl(Fun, Acc0, Ref) ->
    fold_batches(Fun, Acc0, Ref, none).

%% @doc Writes a snapshot of the database to `Filename' (SQLite `VACUUM INTO').
%%
%% The file is a SQLite database, not an ETS table file.
-spec tab2file(pid(), file:name_all()) -> ok | {error, term()}.
tab2file(Ref, Filename) ->
    call(Ref, {tab2file, Filename}).

%% Client-side streaming

fold_batches(Fun, Acc, Ref, From) ->
    case call(Ref, {fetch, From, ?BATCH}) of
        {[], _Last} -> Acc;
        {Rows, Last} -> fold_batches(Fun, lists:foldl(Fun, Acc, Rows), Ref, Last)
    end.

select_all(Ref, Compiled, From, Acc) ->
    case call(Ref, {select, Compiled, From, infinity}) of
        {Matches, '$end_of_table'} ->
            lists:reverse(Acc, Matches);
        {Matches, Next} ->
            select_all(Ref, Compiled, Next, lists:reverse(Matches, Acc))
    end.

cont(_Ref, '$end_of_table', _Compiled, _Limit) -> '$end_of_table';
cont(Ref, Cursor, Compiled, Limit) -> {trdb_sqlite_cont, Ref, Cursor, Compiled, Limit}.

%% gen_server callbacks

%% @private
init({Name, Options}) ->
    KeyPos = proplists:get_value(keypos, Options, 1),
    File = proplists:get_value(file, Options, ":memory:"),
    {ok, Db} = esqlite3:open(File),
    ok = esqlite3:exec(Db, "PRAGMA journal_mode=WAL"),
    ok = esqlite3:exec(Db, "PRAGMA synchronous=NORMAL"),
    Table = quote_string(table_name(Name)),
    ok = esqlite3:exec(Db, "CREATE TABLE IF NOT EXISTS " ++ Table ++ " ("
                       "idx INTEGER PRIMARY KEY,"
                       " pid TEXT,"
                       " event TEXT,"
                       " module TEXT,"
                       " func TEXT,"
                       " arity INTEGER,"
                       " data BLOB,"
                       " ts INTEGER,"
                       " info BLOB)"),
    {ok, #st{name = Name, table = Table, db = Db, keypos = KeyPos,
             type = table_type(Options), protection = protection(Options),
             named_table = proplists:get_bool(named_table, Options),
             owner = self()}}.

table_type(Options) ->
    case [T || T <- [set, ordered_set, bag, duplicate_bag], lists:member(T, Options)] of
        [] -> set;
        [Type] when Type =:= set; Type =:= ordered_set -> Type;
        [Other] -> error({unsupported_table_type, Other});
        Many -> error({ambiguous_table_type, Many})
    end.

protection(Options) ->
    case [P || P <- [public, protected, private], lists:member(P, Options)] of
        [] -> protected;
        [Prot] -> Prot;
        Many -> error({ambiguous_protection, Many})
    end.

%% @private
%%
%% Errors are caught here and reported as {trdb_error, Reason}, which call/2
%% re-raises in the caller. A bad argument must not take the table server down:
%% it is linked to whoever created the table.
handle_call(Req, _From, St) ->
    case safe(fun() -> do_call(Req, St) end) of
        {trdb_error, _} = Error -> {reply, Error, St};
        Reply -> {reply, Reply, St}
    end.

do_call({insert_one, Object}, St) -> insert_rows(St, [Object]);
do_call({insert_many, Objects}, St) -> insert_rows(St, Objects);
do_call({lookup, Key}, St) -> objects(St, where_key(St, Key));
do_call({delete, Key}, St) ->
    ok = esqlite3:exec(St#st.db, ["DELETE FROM ", St#st.table, " WHERE idx = ",
                                  integer_to_list(key(Key))]),
    true;
do_call(delete_all_objects, St) ->
    ok = esqlite3:exec(St#st.db, "DELETE FROM " ++ St#st.table),
    true;
do_call(delete_table, St) ->
    ok = esqlite3:exec(St#st.db, "DROP TABLE IF EXISTS " ++ St#st.table),
    true;
do_call({fetch, From, Limit}, St) -> fetch(St, From, Limit);
do_call(last, St) -> scalar_or_end(St, "SELECT max(idx) FROM " ++ St#st.table);
do_call({next, Key}, St) ->
    Sql = "SELECT min(idx) FROM " ++ St#st.table ++ " WHERE idx > " ++ integer_to_list(key(Key)),
    scalar_or_end(St, Sql);
do_call({prev, Key}, St) ->
    Sql = "SELECT max(idx) FROM " ++ St#st.table ++ " WHERE idx < " ++ integer_to_list(key(Key)),
    scalar_or_end(St, Sql);
do_call({select, Compiled, From, Limit}, St) ->
    scan(St, From, Compiled, Limit, 0, []);
do_call(info, St = #st{name = Name, table = Table, type = Type, keypos = KeyPos,
                       protection = Protection, named_table = Named, owner = Owner}) ->
    Size = scalar(St, "SELECT count(*) FROM " ++ Table),
    [{id, self()}, {name, Name}, {size, Size}, {type, Type},
     {keypos, KeyPos}, {protection, Protection},
     {named_table, Named}, {owner, Owner}];
do_call({tab2file, Filename}, St) ->
    snapshot(St, to_list(Filename));
do_call(_Req, _St) ->
    {error, badarg}.

safe(Fun) ->
    try
        Fun()
    catch
        Class:Reason -> {trdb_error, {Class, Reason}}
    end.

%% @private
handle_cast(_Msg, St) -> {noreply, St}.

%% @private
handle_info(_Msg, St) -> {noreply, St}.

%% @private
terminate(_Reason, #st{db = Db}) ->
    _ = esqlite3:close(Db),
    ok.

%% @private
code_change(_OldVsn, St, _Extra) -> {ok, St}.

%% Statements

insert_rows(_St, []) ->
    true;
insert_rows(St, Objects) ->
    ok = esqlite3:exec(St#st.db, "BEGIN"),
    try
        {ok, Stmt} = esqlite3:prepare(St#st.db, insert_sql(St)),
        lists:foreach(fun(Object) ->
                              ok = esqlite3:bind(Stmt, row_of(St, Object)),
                              '$done' = esqlite3:step(Stmt),
                              ok = esqlite3:reset(Stmt)
                      end, Objects),
        ok = esqlite3:exec(St#st.db, "COMMIT"),
        true
    catch
        Class:Reason:Stacktrace ->
            _ = esqlite3:exec(St#st.db, "ROLLBACK"),
            erlang:raise(Class, Reason, Stacktrace)
    end.

insert_sql(#st{table = Table}) ->
    "INSERT OR REPLACE INTO " ++ Table ++
        " (idx, pid, event, module, func, arity, data, ts, info)"
        " VALUES (?,?,?,?,?,?,?,?,?)".

row_of(#st{keypos = 2}, Object) when is_tuple(Object), tuple_size(Object) =:= 8 ->
    #tr{index = Index, pid = Pid, event = Event, mfa = MFA, data = Data, ts = TS, info = Info} = Object,
    {Module, Func, Arity} = split_mfa(MFA),
    [Index,
     list_to_binary(pid_to_list(Pid)),
     atom_to_binary(Event, utf8),
     Module, Func, Arity,
     {blob, term_to_binary(Data)},
     TS,
     {blob, term_to_binary(Info)}];
row_of(#st{keypos = KeyPos}, Object) ->
    error({unsupported_object, KeyPos, Object}).

split_mfa(no_mfa) -> {undefined, undefined, undefined};
split_mfa({Module, Func, Arity}) ->
    {atom_to_binary(Module, utf8), atom_to_binary(Func, utf8), Arity}.

%% Reading

columns() ->
    "idx, pid, event, module, func, arity, data, ts, info".

where_key(#st{table = Table}, Key) ->
    ["SELECT ", columns(), " FROM ", Table, " WHERE idx = ", integer_to_list(key(Key))].

key(Key) when is_integer(Key), Key >= 0 -> Key;
key(Key) -> error({unsupported_key, Key}).

fetch(St = #st{table = Table}, From, Limit) ->
    Where = case From of
                none -> "";
                _ -> [" WHERE idx > ", integer_to_list(key(From))]
            end,
    Sql = ["SELECT ", columns(), " FROM ", Table, Where, " ORDER BY idx LIMIT ",
           integer_to_list(Limit)],
    case objects(St, Sql) of
        [] -> {[], none};
        Objects -> {Objects, (lists:last(Objects))#tr.index}
    end.

objects(St, Sql) ->
    [row_to_object(Row) || Row <- query(St, Sql)].

query(#st{db = Db}, Sql) ->
    {ok, Stmt} = esqlite3:prepare(Db, iolist_to_binary(Sql)),
    collect(Stmt, []).

collect(Stmt, Acc) ->
    case esqlite3:step(Stmt) of
        '$done' -> lists:reverse(Acc);
        Row when is_list(Row) -> collect(Stmt, [Row | Acc])
    end.

row_to_object([Index, Pid, Event, Module, Func, Arity, Data, TS, Info]) ->
    #tr{index = Index,
        pid = list_to_pid(binary_to_list(Pid)),
        event = binary_to_atom(Event, utf8),
        mfa = join_mfa(Module, Func, Arity),
        data = binary_to_term(Data),
        ts = TS,
        info = binary_to_term(Info)}.

join_mfa(undefined, undefined, undefined) -> no_mfa;
join_mfa(Module, Func, Arity) ->
    {binary_to_atom(Module, utf8), binary_to_atom(Func, utf8), Arity}.

%% Null reads as `undefined'; no key is 0, so that doubles as "no row".
scalar(St, Sql) ->
    case query(St, Sql) of
        [[Value]] when is_integer(Value) -> Value;
        _ -> 0
    end.

scalar_or_end(St, Sql) ->
    case scalar(St, Sql) of
        0 -> '$end_of_table';
        N -> N
    end.

%% Persistence

%% SQLite's backup API; `VACUUM INTO' is not available in every build.
snapshot(#st{db = Db}, File) ->
    _ = file:delete(File),
    {ok, Dest} = esqlite3:open(File),
    try
        {ok, Backup} = esqlite3:backup_init(Dest, "main", Db, "main"),
        ok = backup_all(Backup),
        _ = esqlite3:backup_finish(Backup),
        ok
    after
        _ = esqlite3:close(Dest)
    end.

backup_all(Backup) ->
    case esqlite3:backup_step(Backup, 100) of
        ok -> backup_all(Backup);
        '$done' -> ok;
        error -> error(backup_failed)
    end.

%% Matching

scan(St, From, Compiled, Limit, Count, Acc) ->
    {Rows, Last} = fetch(St, From, ?BATCH),
    {Acc1, Count1, Reached, Examined} = run_ms(Rows, Compiled, Limit, Count, Acc),
    if
        Reached ->
            {lists:reverse(Acc1), Examined};
        Rows =:= [] ->
            {lists:reverse(Acc1), '$end_of_table'};
        length(Rows) < ?BATCH ->
            {lists:reverse(Acc1), '$end_of_table'};
        true ->
            scan(St, Last, Compiled, Limit, Count1, Acc1)
    end.

run_ms([], _Compiled, _Limit, Count, Acc) ->
    {Acc, Count, false, none};
run_ms([Object | Rest], Compiled, Limit, Count, Acc) ->
    Matches = ets:match_spec_run([Object], Compiled),
    Acc1 = lists:reverse(Matches, Acc),
    Count1 = Count + length(Matches),
    case Limit =/= infinity andalso Count1 >= Limit of
        true -> {Acc1, Count1, true, Object#tr.index};
        false -> run_ms(Rest, Compiled, Limit, Count1, Acc1)
    end.

%% Helpers

call(Ref, Req) ->
    case gen_server:call(Ref, Req, ?TIMEOUT) of
        {trdb_error, {error, Reason}} -> erlang:error(Reason);
        {trdb_error, {Class, Reason}} -> erlang:raise(Class, Reason, []);
        Reply -> Reply
    end.

stop(Ref) ->
    try gen_server:stop(Ref, normal, ?TIMEOUT)
    catch exit:_ -> ok
    end.

%% SQLite reserves names starting with `sqlite_' for its own tables and fails
%% with a bare {error, 1}, so reject them here with something readable.
table_name(Name) ->
    String = atom_to_list(Name),
    case string:lowercase(String) of
        "sqlite_" ++ _ -> error({reserved_table_name, Name});
        _ -> String
    end.

quote_string(String) ->
    [$" | [escape(C) || C <- String] ++ [$"]].

escape($") -> [$", $"];
escape(C) -> C.

to_list(Bin) when is_binary(Bin) -> binary_to_list(Bin);
to_list(List) when is_list(List) -> List.
