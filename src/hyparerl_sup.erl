-module(hyparerl_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-include("hyparerl.hrl").

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Options) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Options]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Options]) ->
    IP = proplists:get_value(ip, Options),
    Port = proplists:get_value(port, Options),
    Recipient = proplists:get_value(recipient, Options),
    Myself = #node{ip=IP, port=Port},

    Manager = {hypar_man,
               {hypar_man, start_link, [Myself, Options]},
               permanent, 5000, worker, [hypar_man]},
    ConnectionSup = {connect_sup,
                     {connect_sup, start_link, [Recipient, Myself]},
                     permanent, 5000, supervisor, [connect_sup]},
    {ok, { {one_for_one, 5, 10}, [Manager, ConnectionSup]} }.
