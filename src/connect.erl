%% -------------------------------------------------------------------
%%
%% Connection handler for hyparerl 
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

%% @doc Module that implements the tcp-connection handling between two
%%      nodes in hyparerl. Either listens to a socket for connections
%%      or provided with an existing open socket to handle.

-module(connect).

-author('Emil Falk <emil.falk.1988@gmail.com>').

%% API
-export([start_link/1, start_link/4, new_connection/2, new_temp_connection/2,
         send_control/2, send_message/2, kill/1]).

-export([init/1, init/3]).

-include("hyparerl.hrl").

%% Local state
-record(conn_st, {socket,
                  recipient}).

-define(ERR(Error, Text), io:format("Error: ~p~nMessage: ~s~n", [Error, Text])).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Start a tcp-handler that accepts connections from a listen-socket
start_link(ListenerPid, Socket, _Transport, [Recipient]) ->
    Args = [ListenerPid, Socket, Recipient],
    Pid = spawn_link(?MODULE, init, Args),
    {ok, Pid}.

%% @doc Start a tcp-connection
start_link(Recipient) ->
    Pid = spawn_link(?MODULE, init, [Recipient]),
    {ok, Pid}.

%% @doc Start a new connection, returning a pid and a monitor if
%% successful otherwise it returns an error.
new_connection(NodeA, NodeB) ->
    new_connection(NodeA, NodeB, true).

%% @doc Same as above but won't monitor the connection since it's only temporary.
new_temp_connection(NodeA, NodeB) ->
    new_connection(NodeA, NodeB, false).

%% @doc Send a message to a peer, this will be routed to the configured
%%      recipient process. (For example the plumtree service)
send_message(Pid, Msg) ->
    Pid ! {message, Msg}.

%% @doc Send a control message (i.e node -> node)
send_control(Pid, Msg) ->
    Pid ! {control, Msg}.

%% @doc Kill a tcp-handler
kill(Pid) ->
    Pid ! kill.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% Either initiate a connection via a listen socket(ranch) or existing socket
init(ListenerPid, Socket, Recipient) ->
    ok = ranch:accept_ack(ListenerPid),
    
    ranch_tcp:setopts(Socket, [{active, once}]),

    ConnSt = #conn_st{socket=Socket,
                      recipient=Recipient},
    loop(ConnSt).

init(Recipient) ->
    ConnSt = #conn_st{recipient=Recipient},
    pre_loop(ConnSt).

pre_loop(ConnSt) ->
    receive
        {socket, Socket, {Pid, Ref}} ->
            Pid ! {ok, Ref},
            loop(ConnSt#conn_st{socket=Socket})
    end.

loop(ConnSt) ->
    #conn_st{socket=Socket, recipient=Recipient} = ConnSt,
    receive
        {message, Msg} ->
            Bin = term_to_binary({message, Msg}),
            ranch_tcp:send(Socket, Bin),
            loop(ConnSt);
        {control, Msg} ->
            Bin = term_to_binary({control, Msg}),
            ranch_tcp:send(Socket, Bin),
            loop(ConnSt);
        kill -> 
            ranch_tcp:close(Socket),
            exit(normal);
        Info ->
            {OK, Closed, Error} = ranch_tcp:messages(),
            case Info of
                {OK, Socket, Data} ->
                    case binary_to_term(Data) of
                        {message, Msg} -> 
                            gen_server:cast(Recipient, {Msg, self()});
                        {control, Msg} ->
                            hypar_node:control_msg(Msg)
                    end,
                    
                    %% Set the socket to active once
                    ranch_tcp:setopts(Socket, [{active, once}]),
                    loop(ConnSt);
                {Closed, _Socket} ->
                    %% Log this?
                    exit(normal);
                {Error, Socket, Reason} ->
                    ?ERR({tcp_error, Socket, Reason},
                         "Error with a tcp-connection."),
                    exit(Reason)
            end
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================    

%% @doc Open up a new connection
%% @todo Looks like ranch is also gonna export connect later on,
%%       change from gen_tcp to ranch_tcp
new_connection({RemoteIP, RemotePort}, _, Monitor) ->
    ConnectArgs = [{active, false}],
    case gen_tcp:connect(RemoteIP, RemotePort, ConnectArgs, ?TIMEOUT) of
        {ok, Socket} -> 
            io:format("Connected..."),
            {ok, Pid} = supervisor:start_child(connect_sup, []),
            ok = socket_ok(Pid, Socket),
            case Monitor of
                true ->
                    MRef = erlang:monitor(process, Pid),            
                    {ok, Pid, MRef};
                false ->
                    {ok, Pid}
            end;
        Err ->
            Err
    end.

%% @doc Let pid start using socket
socket_ok(Pid, Socket) ->
    gen_tcp:controlling_process(Socket, Pid),
    Ref = make_ref(),
    MRef = erlang:monitor(process, Pid),
    Pid ! {socket, Socket, {self(), Ref}},
    receive
        {ok, Ref} ->
            erlang:demonitor(MRef, [flush]),
            ok;
        {'DOWN', MRef, process, _, _} ->
            erlang:demonitor(MRef, [flush]),
            ok
    end.
