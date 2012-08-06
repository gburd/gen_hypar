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
-export([start_link/2, new_peer/2, new_temp_peer/2, start_listener/0]).

%% Supervisor callbacks
-export([init/1]).

-include("hyparerl.hrl").

-define(TIMEOUT, 10000).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(Recipient, Myself) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Recipient, Myself]).

-spec new_peer(Node :: node(), Myself :: node()) ->
                      #peer{} | {error, any()};
              (Node :: #node{}, Pid :: pid()) ->
                      #peer{}.
%% @doc Start a new peer, returning it if successful otherwise
%%      it returns an error.
new_peer(Node=#node{ip=RemoteIP, port=RemotePort},
         #node{ip=LocalIP, port=LocalPort}) ->
    ?INFO([{?MODULE, "Trying to setup a new peer..."},
           {ip, RemoteIP},
           {port, RemotePort},
           {local_ip, LocalIP},
           {local_port, LocalPort}]),
    
    ConnectArgs = [{ip, LocalIP},
                   {port, LocalPort},
                   binary,
                   {active, false},
                   {packet, 2},
                   {keepalive, true}],
    Status = gen_tcp:connect(RemoteIP, RemotePort,
                             ConnectArgs,
                             ?TIMEOUT),
    case Status of
        {ok, Socket} -> 
            {ok, Pid} = supervisor:start_child(?MODULE, [Socket]),
            gen_tcp:controlling_process(Socket, Pid),
            MRef = monitor(process, Pid),
            
            ?INFO([{?MODULE, "Setup of peer successful..."},
                   {node, Node}]),
            peer(Node, Pid, MRef);
        Err ->
            ?ERROR([{?MODULE, "Setup of peer failed..."},
                    {node, Node},
                    Err]),
            Err
    end;
new_peer(Node, Pid) when is_record(Node, node) andalso is_pid(Pid)->
    MRef = monitor(process, Pid),
    peer(Node, Pid, MRef).

%% @doc Used to create a temporary connection, used to reply to a shuffle request
%%      NOTE: Could probably define a new function that combines both new_peer/new_temp_peer.
new_temp_peer(Node=#node{ip=RemoteIP, port=RemotePort}, LocalIP) ->
    ?INFO([{?MODULE, "Trying to setup a new temporary peer..."},
           {ip, RemoteIP},
           {port, RemotePort},
           {local_ip, LocalIP}]),
    
    ConnectArgs = [{ip, LocalIP},
                   binary,
                   {active, false},
                   {packet, 2},
                   {keepalive, true}],
    Status = gen_tcp:connect(RemoteIP, RemotePort,
                             ConnectArgs,
                             ?TIMEOUT),
    case Status of
        {ok, Socket} -> 
            {ok, Pid} = supervisor:start_child(?MODULE, [Socket]),
            gen_tcp:controlling_process(Socket, Pid),
            
            ?INFO([{?MODULE, "Setup of temporary peer successful..."},
                   {node, Node}]),
            peer(Node, Pid, temporary);
        Err ->
            ?ERROR([{?MODULE, "Setup of temporary peer failed..."},
                    {node, Node},
                    Err]),
            Err
    end.

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init([Recipient, #node{ip=IPAddr, port=Port}]) ->
    error_logger:info_report([{?MODULE, "Initializing..."},
                              {recipient, Recipient},
                              {ip, IPAddr},
                              {port, Port}]),
    {ok, ListenSocket} = gen_tcp:listen(Port, [{ip, IPAddr},
                                               {reuseaddr, true},
                                               binary,
                                               {active, once},
                                               {packet, 2},
                                               {keepalive, true}]),
    WorkerArgs = [ListenSocket, Recipient],
    ConnectionWorkers = {connect,
                         {connect, start_link, WorkerArgs},
                         transient, 5000, worker, [connect]},

    ?INFO([{?MODULE, "Staring listeners..." },
           {ip, IPAddr},
           {port, Port}]),
    spawn_link(fun empty_listeners/0),

    {ok, {{simple_one_for_one, 5, 10}, [ConnectionWorkers]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

start_listener() ->
    supervisor:start_child(?MODULE, []).

-spec peer(Node :: #node{}, Pid :: pid(), MRef :: reference()) ->
                  #peer{}.
%% @pure
%% @doc Create a new peer entry for given Node, Pid and MRef
peer(Node, Pid, MRef) ->
    #peer{id=Node, pid=Pid, mref=MRef}.

-spec empty_listeners() -> ok.
%% @doc Start 20 idle listeners
empty_listeners() ->
    [start_listener() || _ <- lists:seq(1,20)],
    ok.
