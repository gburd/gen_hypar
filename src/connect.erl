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

-behaviour(gen_server).

%% API
-export([start_link/2, start_link/3, send_control/2, send_message/2, kill/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("hyparerl.hrl").

%% Local state
-record(conn_st, {socket,
                  recipient}).

-define(ERR(Error, Text), io:format("Error: ~p~nMessage: ~s~n", [Error, Text])).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Start a tcp-handler that accepts connections from a listen-socket
start_link(ListenSocket, Recipient) ->
    Args = [listen, ListenSocket, Recipient],
    gen_server:start_link(?MODULE, Args, []).

%% @doc Start a tcp-handler with a started tcp-connection
start_link(_ListenSocket, Recipient, Socket) ->
    Args = [connect, Socket, Recipient],
    gen_server:start_link(?MODULE, Args, []).

%% @doc Send a message to a peer, this will be routed to the configured
%%      recipient process. (For example the plumtree service)
send_message(Pid, Msg) ->
    gen_server:cast(Pid, {message, Msg}).

%% @doc Send a control message (i.e node -> node)
send_control(Pid, Msg) ->
    gen_server:cast(Pid, {control, Msg}).

%% @doc Kill a tcp-handler
kill(Pid) ->
    gen_server:cast(Pid, kill).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% Either initiate a connection via a listen socket or existing socket
init([listen, ListenSocket, Recipient]) ->

    %% This is a listen-handler.
    %% Send a message to self to start listen on socket
    ConnSt = #conn_st{socket=ListenSocket,
                      recipient=Recipient},
    {ok, ConnSt, 0};
init([connect, Socket, Recipient]) ->

    %% This is a open connection handler, set to active once and
    %% start receiving data
    inet:setopts(Socket, [{active, once}]),
    ConnSt = #conn_st{socket=Socket,
                      recipient=Recipient},
    {ok, ConnSt}.

%% Handle the sending of messages
handle_cast(Msg={message, _Payload}, ConnSt=#conn_st{socket=Socket}) ->
    send(Socket, Msg),
    {noreply, ConnSt};

%% Handle the sending of control-messages
handle_cast(Msg={control, _Payload}, ConnSt=#conn_st{socket=Socket}) ->
    send(Socket, Msg),
    {noreply, ConnSt};

%% Kill the connection
handle_cast(kill, ConnSt=#conn_st{socket=Socket}) ->
    gen_tcp:close(Socket),
    {stop, normal, ConnSt}.

%% Take care of incoming tcp-data
handle_info({tcp, Socket, Data}, ConnSt=#conn_st{recipient=Recipient}) ->
    %% Decode the packet (Should probably use own decoding routines)
    case binary_to_term(Data) of
        {message, Msg} -> 
            gen_server:cast(Recipient, {Msg, self()});
        {control, Msg} ->
            hypar_node:control_msg(Msg)
    end,

    %% Set the socket to active once
    inet:setopts(Socket, [{active, once}]),
    {noreply, ConnSt};

%% If the connection is closed, stop the handler
handle_info({tcp_closed, _Socket}, ConnSt) ->
    {stop, normal, ConnSt};

%% If the connection experience an error, stop the handler
handle_info({tcp_error, _Socket, Reason}, ConnSt) ->
    ?ERR({tcp_error, Reason}, "Error with a tcp-connection."),
    {stop, normal, ConnSt};

%% Accept an incoming connection
handle_info(timeout, ConnSt=#conn_st{socket=ListenSocket}) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    
    %% Start a new listener
    connect_sup:start_listener(),
    {noreply, ConnSt#conn_st{socket=Socket}}.

%% No handle_call used
handle_call(_Msg, _From, ConnSt) ->
    {stop, not_used, ConnSt}.

terminate(_Reason, _Conn_St) ->
    ok.

code_change(_OldVsn, Conn_St, _Extra) ->
    {ok, Conn_St}.

%%%===================================================================
%%% Internal functions
%%%===================================================================    

%% Wrapper for gen_tcp:send and term_to_binary.
send(Socket, Msg) ->
    gen_tcp:send(Socket, term_to_binary(Msg)).
