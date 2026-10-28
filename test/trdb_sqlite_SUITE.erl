-module(trdb_sqlite_SUITE).
-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include("tr.hrl").

-define(ALL, [{'_', [], ['$_']}]).
-define(CALLS, [{{tr, '_', '_', call, '_', '_', '_', '_'}, [], ['$_']}]).
-define(INDEXES, [{{tr, '$1', '_', '_', '_', '_', '_', '_'}, [], ['$1']}]).

all() ->
    [basic,
     ordered_traversal,
     replace_same_key,
     select_all_and_filter,
     select_limit_and_continue,
     delete_cases,
     file_persistence,
     tab2file_snapshot,
     via_trdb,
     rejects_non_trace_objects,
     tr_backend,
     tr_backend_file,
     reserved_table_name].

row(I) ->
    #tr{index = I, pid = self(), event = call, mfa = {m, f, 1}, data = [I],
        ts = 1000 + I, info = no_info}.

row(I, Event) ->
    (row(I))#tr{event = Event}.

indexes(Objects) ->
    [I || #tr{index = I} <- Objects].

%% A default table accepts single and list inserts and reads them back.
basic(_Config) ->
    T = trdb_sqlite:new(basic_tab, [ordered_set, {keypos, 2}]),
    true = trdb_sqlite:insert(T, row(1)),
    true = trdb_sqlite:insert(T, [row(2), row(3)]),
    [#tr{index = 1, mfa = {m, f, 1}}] = trdb_sqlite:lookup(T, 1),
    [] = trdb_sqlite:lookup(T, 99),
    [1, 2, 3] = indexes(trdb_sqlite:tab2list(T)),
    3 = trdb_sqlite:info(T, size),
    ordered_set = trdb_sqlite:info(T, type),
    2 = trdb_sqlite:info(T, keypos),
    #{size := 3, name := basic_tab} = maps:from_list(trdb_sqlite:info(T)),
    3 = trdb_sqlite:foldl(fun(_Obj, Acc) -> Acc + 1 end, 0, T),
    true = trdb_sqlite:delete(T).

%% next/prev/last follow key order, with ETS's end marker.
ordered_traversal(_Config) ->
    T = trdb_sqlite:new(order_tab, [ordered_set, {keypos, 2}]),
    '$end_of_table' = trdb_sqlite:last(T),
    true = trdb_sqlite:insert(T, [row(I) || I <- lists:seq(1, 5)]),
    5 = trdb_sqlite:last(T),
    2 = trdb_sqlite:next(T, 1),
    3 = trdb_sqlite:next(T, 2),
    '$end_of_table' = trdb_sqlite:next(T, 5),
    4 = trdb_sqlite:prev(T, 5),
    1 = trdb_sqlite:prev(T, 2),
    '$end_of_table' = trdb_sqlite:prev(T, 1),
    true = trdb_sqlite:delete(T).

%% Inserting the same key replaces the object, as in an ETS set.
replace_same_key(_Config) ->
    T = trdb_sqlite:new(replace_tab, [ordered_set, {keypos, 2}]),
    true = trdb_sqlite:insert(T, row(1)),
    true = trdb_sqlite:insert(T, (row(1))#tr{data = [replaced]}),
    [#tr{data = [replaced]}] = trdb_sqlite:lookup(T, 1),
    1 = trdb_sqlite:info(T, size),
    true = trdb_sqlite:delete(T).

%% Match specifications are evaluated exactly, including field selection.
select_all_and_filter(_Config) ->
    T = trdb_sqlite:new(select_tab, [ordered_set, {keypos, 2}]),
    Rows = [row(I, case I rem 2 of 0 -> return; 1 -> call end) || I <- lists:seq(1, 6)],
    true = trdb_sqlite:insert(T, Rows),
    6 = length(trdb_sqlite:select(T, ?ALL)),
    [1, 3, 5] = indexes(trdb_sqlite:select(T, ?CALLS)),
    [1, 2, 3, 4, 5, 6] = trdb_sqlite:select(T, ?INDEXES),
    true = trdb_sqlite:delete(T).

%% select/3 returns a limited chunk; select/1 continues and ends correctly.
select_limit_and_continue(_Config) ->
    T = trdb_sqlite:new(limit_tab, [ordered_set, {keypos, 2}]),
    true = trdb_sqlite:insert(T, [row(I) || I <- lists:seq(1, 5)]),
    {Chunk1, C1} = trdb_sqlite:select(T, ?ALL, 2),
    [1, 2] = indexes(Chunk1),
    {Chunk2, C2} = trdb_sqlite:select(C1),
    [3, 4] = indexes(Chunk2),
    {Chunk3, End} = trdb_sqlite:select(C2),
    [5] = indexes(Chunk3),
    '$end_of_table' = End,
    %% And select/2 sees everything regardless of chunking.
    5 = length(trdb_sqlite:select(T, ?ALL)),
    true = trdb_sqlite:delete(T).

%% delete/2, delete_all_objects/1 and delete/1.
delete_cases(_Config) ->
    T = trdb_sqlite:new(delete_tab, [ordered_set, {keypos, 2}]),
    true = trdb_sqlite:insert(T, [row(1), row(2), row(3)]),
    true = trdb_sqlite:delete(T, 2),
    [1, 3] = indexes(trdb_sqlite:tab2list(T)),
    true = trdb_sqlite:delete_all_objects(T),
    0 = trdb_sqlite:info(T, size),
    true = trdb_sqlite:delete(T),
    undefined = trdb_sqlite:info(T),
    %% closing twice is harmless
    true = trdb_sqlite:delete(T).

%% A file-backed table keeps its rows across a restart.
file_persistence(Config) ->
    File = filename:join(?config(priv_dir, Config), "persist.db"),
    T1 = trdb_sqlite:new(persist_tab, [ordered_set, {keypos, 2}, {file, File}]),
    true = trdb_sqlite:insert(T1, [row(1), row(2)]),
    ok = gen_server:stop(T1),
    T2 = trdb_sqlite:new(persist_tab, [ordered_set, {keypos, 2}, {file, File}]),
    2 = trdb_sqlite:info(T2, size),
    [1, 2] = indexes(trdb_sqlite:tab2list(T2)),
    true = trdb_sqlite:delete(T2).

%% tab2file writes a SQLite snapshot that another connection can read.
tab2file_snapshot(Config) ->
    File = filename:join(?config(priv_dir, Config), "snapshot.db"),
    T = trdb_sqlite:new(snapshot_tab, [ordered_set, {keypos, 2}]),
    true = trdb_sqlite:insert(T, [row(I) || I <- lists:seq(1, 3)]),
    ok = trdb_sqlite:tab2file(T, File),
    {ok, Db} = esqlite3:open(File),
    {ok, St} = esqlite3:prepare(Db, "SELECT count(*) FROM \"snapshot_tab\""),
    [3] = esqlite3:step(St),
    ok = esqlite3:close(Db),
    true = trdb_sqlite:delete(T).

%% The whole contract works through trdb's tagged handle, continuations included.
via_trdb(_Config) ->
    H = trdb:new(trdb_traces, [named_table, public, ordered_set, {keypos, 2},
                               {backend, trdb_sqlite}]),
    {trdb, trdb_sqlite, Ref} = H,
    true = is_pid(Ref),
    true = trdb:insert(H, [row(1), row(2), row(3)]),
    [#tr{index = 2}] = trdb:lookup(H, 2),
    3 = trdb:info(H, size),
    2 = trdb:next(H, 1),
    3 = trdb:last(H),
    [1, 2, 3] = indexes(trdb:tab2list(H)),
    {Chunk1, C1} = trdb:select(H, ?ALL, 2),
    [1, 2] = indexes(Chunk1),
    {trdb_cont, trdb_sqlite, _} = C1,
    {Chunk2, End} = trdb:select(C1),
    [3] = indexes(Chunk2),
    '$end_of_table' = End,
    true = trdb:delete(H),
    undefined = trdb:info(H).

%% tr itself can run on the SQLite backend.
tr_backend(Config) ->
    catch tr:stop(),
    {ok, _} = tr:start(#{tab => tr_traces, backend => trdb_sqlite}),
    try
        {trdb, trdb_sqlite, _} = tr:tab(),
        ok = tr:trace([?MODULE]),
        _ = row(1),
        wait_for_traces(1, 200),
        ok = tr:stop_tracing(),
        Traces = tr:select(),
        true = length(Traces) >= 2,
        #tr{index = 1} = tr:lookup(1),
        _ = tr:next(1),
        Stats = tr:call_stat(fun(#tr{mfa = MFA}) -> MFA end),
        true = map_size(Stats) > 0,
        ok = tr:clean(),
        [] = tr:select(),
        ok = tr:dump(filename:join(?config(priv_dir, Config), "tr_snapshot.db")),
        {error, {unsupported_backend, trdb_sqlite}} =
            tr:load(filename:join(?config(priv_dir, Config), "ignored.ets"))
    after
        catch tr:stop()
    end.

%% Backend options reach the store: a file-backed trace table.
tr_backend_file(Config) ->
    catch tr:stop(),
    File = filename:join(?config(priv_dir, Config), "tr_traces.db"),
    {ok, _} = tr:start(#{tab => tr_file_traces,
                         backend => {trdb_sqlite, [{file, File}]}}),
    try
        {trdb, trdb_sqlite, _} = tr:tab(),
        ok = tr:trace([?MODULE]),
        _ = row(2),
        wait_for_traces(1, 200),
        ok = tr:stop_tracing(),
        true = length(tr:select()) > 0,
        ok = tr:clean()
    after
        catch tr:stop()
    end,
    true = filelib:is_regular(File).

%% SQLite reserves the sqlite_ prefix; say so instead of surfacing {error, 1}.
reserved_table_name(_Config) ->
    try
        trdb_sqlite:new(sqlite_traces, [ordered_set, {keypos, 2}]),
        ct:fail(expected_error)
    catch
        error:{reserved_table_name, sqlite_traces} -> ok
    end.

wait_for_traces(Min, Tries) ->
    case length(tr:select()) >= Min of
        true -> ok;
        false when Tries > 0 -> timer:sleep(10), wait_for_traces(Min, Tries - 1);
        false -> ct:fail(no_traces)
    end.

%% Objects that are not trace records are rejected without killing the table.
rejects_non_trace_objects(_Config) ->
    T = trdb_sqlite:new(reject_tab, [ordered_set, {keypos, 2}]),
    {'EXIT', {{unsupported_object, 2, {foo, bar}}, _Stacktrace}} =
        (catch trdb_sqlite:insert(T, {foo, bar})),
    true = trdb_sqlite:insert(T, row(1)),
    1 = trdb_sqlite:info(T, size),
    true = trdb_sqlite:delete(T).
