-module(hyparerl_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Options) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Options]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Options]) ->
    IPAddr = lists:keyfind(ipaddr, 1, Options),
    Port   = lists:keyfind(port, 1, Options),
    Myself = {IPAddr, Port},

    Manager = {hypar_man,
               {hypar_man, start_link, [Options]},
               permanent, 5000, worker, [hypar_man]},
    ConnectionSup = {connect_sup,
                     {connect_sup, start_link, [Myself]},
                     permanent, 5000, supervisor, [connect_sup]},
    {ok, { {one_for_one, 5, 10}, [Manager, ConnectionSup]} }.

%% ===================================================================
%% Internal functions
%% ===================================================================
