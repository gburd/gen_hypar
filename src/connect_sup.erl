-module(connect_sup).

-behaviour(supervisor).

%% API
-export([start_link/2]).

%% Supervisor callbacks
-export([init/1]).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(Name, Options) ->
    supervisor:start_link({local, Name}, ?MODULE, Options).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init(Options) ->
    Connect = {connect, {connect, start_link, [connect:filter_opts(Options)]},
               temporary, brutal_kill, worker, [connect]},
    
    {ok, {{simple_one_for_one, 1000, 3600}, [Connect]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
