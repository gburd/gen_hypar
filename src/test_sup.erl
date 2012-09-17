-module(test_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================
init([]) ->
    RestartStrategy = one_for_all,
    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 3600,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    Dummy = {dummy_sup, {dummy_sup, start_link, []},
             permanent, brutal_kill, supervisor, [dummy_sup]},
    Test = {test, {test, start_link, []},
            permanent, brutal_kill, worker, [test]},
    
    {ok, {SupFlags, [Dummy, Test]}}.
