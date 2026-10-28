%%%-------------------------------------------------------------------
%% @doc erlang_doctor top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(erlang_doctor_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% API functions

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% Supervisor callbacks

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{}, [tr_spec()]}}.

%% Internal functions

%% The trace table can be configured before the application starts, e.g.
%% `application:set_env(erlang_doctor, tr_options, #{backend => trdb_sqlite})'.
-spec tr_spec() -> supervisor:child_spec().
tr_spec() ->
    TrOptions = application:get_env(erlang_doctor, tr_options, #{}),
    #{id => tr,
      start => {tr, start_link, [TrOptions]},
      shutdown => brutal_kill}.
