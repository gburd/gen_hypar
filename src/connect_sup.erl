%% -------------------------------------------------------------------
%%
%% Supervisor for the connection handlers in hyparerl
%%
%% Copyright (c) 2012 Emil Falk  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Supervisor for the connection handlers, support to start new connections
%%      and accept incoming tcp-connections

-module(connect_sup).

-author('Emil Falk <emil.falk.1988@gmail.com>').

-behaviour(supervisor).

%% API
-export([start_link/2, start_listener/0,
         start_connection/2, start_temp_connection/2]).

%% Supervisor callbacks
-export([init/1]).

-include("hyparerl.hrl").

%%===================================================================
%% API functions
%%===================================================================

start_link(Recipient, Myself) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Recipient, Myself]).

%% @doc Start a new connection, returning a pid and a monitor if
%% successful otherwise it returns an error.
start_connection({RemoteIP, RemotePort}, {LocalIP, LocalPort}) ->
    ConnectArgs = [{ip, LocalIP},
                   {port, LocalPort},
                   binary,
                   {active, false},
                   {packet, 4},
                   {keepalive, true}],
    case gen_tcp:connect(RemoteIP, RemotePort, ConnectArgs, ?TIMEOUT) of
        {ok, Socket} -> 
            {ok, Pid} = supervisor:start_child(?MODULE, [Socket]),
            gen_tcp:controlling_process(Socket, Pid),
            MRef = erlang:monitor(process, Pid),            
            {ok, Pid, MRef};
        Err ->
            Err
    end.

%% @doc Used to create a temporary connection, used to reply to a shuffle-
%%      request. Does not monitor the temporary connection.
start_temp_connection({RemoteIP, RemotePort}, {LocalIP, _LocalPort}) ->

    ConnectArgs = [{ip, LocalIP},
                   {port, ?TEMP_PORT},
                   binary,
                   {active, false},
                   {packet, 4},
                   {keepalive, true}],
    case gen_tcp:connect(RemoteIP, RemotePort, ConnectArgs, ?TIMEOUT) of
        {ok, Socket} -> 
            {ok, Pid} = supervisor:start_child(?MODULE, [Socket]),
            gen_tcp:controlling_process(Socket, Pid),
            
            {ok, Pid};
        Err ->
            Err
    end.

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init([Recipient, {IPAddr, Port}]) ->

    {ok, ListenSocket} = gen_tcp:listen(Port, [{ip, IPAddr},
                                               {reuseaddr, true},
                                               binary,
                                               {active, once},
                                               {packet, 4},
                                               {keepalive, true}]),
    WorkerArgs = [ListenSocket, Recipient],
    ConnectionWorkers = {connect,
                         {connect, start_link, WorkerArgs},
                         transient, 5000, worker, [connect]},

    %% Spawn 20 initial listeners
    spawn_link(fun empty_listeners/0),

    {ok, {{simple_one_for_one, 5, 10}, [ConnectionWorkers]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @doc Start a new listener
start_listener() ->
    supervisor:start_child(?MODULE, []).

%% @doc Start 20 idle listeners
empty_listeners() ->
    [start_listener() || _ <- lists:seq(1,20)],
    ok.
