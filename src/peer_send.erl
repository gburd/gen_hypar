%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @private
%% @title Send peer process
%% @doc This is the send peer process. The control process feeds this
%%      process with outgoing messages(either data or control) to be
%%      sent over the socket. This also send periodic keep-alive messages,
%%      if the link is idle for too long.
%% @todo This is a good spot to implement rate throttling. Might be a good
%%       idea if there are lots of traffic.
%% -------------------------------------------------------------------
-module(peer_send).

-behaviour(gen_server).

-export([start_link/4]).
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2,
         code_change/3]).
-export([send_message/2, forward_join/3, shuffle/4, disconnect/1]).

-record(state, {local,
                remote,
                socket,
                keep_alive}).

%% @doc Start a send process
start_link(Identifier, Peer, Socket, KeepAlive) ->
    gen_server:start_link(?MODULE, [Identifier, Peer, Socket, KeepAlive], []).

%% @doc Send a data message
send_message(SendPid, Msg) ->
    gen_server:cast(SendPid, {message, Msg}).

%% @doc Send a forward join
forward_join(SendPid, Peer, TTL) ->
    gen_server:cast(SendPid, {forward_join, Peer, TTL}).

%% @doc Send a shuffle
shuffle(SendPid, Peer, TTL, XList) ->
    gen_server:cast(SendPid, {shuffle, Peer, TTL, XList}).

%% @doc Send a disconnect
disconnect(SendPid) ->
    gen_server:cast(SendPid, disconnect).

%% @doc Send a binary over the socket, if it fails the connection is dead
%%      and we just stop this peer
send(S, Packet) ->
    case proto_wire:send(S#state.socket, Packet) of
        ok  -> {noreply, S, S#state.keep_alive};
        Err -> {stop, normal, S}
    end.

init([Identifier, Peer, Socket, KeepAlive]) ->
    yes = register_peer_send(Identifier, Peer),
    {ok, #state{local=Identifier,
                remote=Peer,
                socket=Socket,
                keep_alive=KeepAlive}, KeepAlive}.

handle_cast({message, Bin}, S) ->
    send(proto_wire:message(Bin), S);
handle_cast({forward_join, Peer, TTL}, S) ->
    send(proto_wire:forward_join(Peer, TTL), S);
handle_cast({shuffle, Peer, TTL, XList}, S) ->
    send(proto_wire:shuffle(Peer, TTL, XList), S);
handle_cast(disconnect, S) ->
    send(proto_wire:disconnect(), S).

%% @doc Send a keep-alive message
handle_info(timeout, S) ->
    send(S, proto_wire:keep_alive()).

handle_call(_,_,S) ->
    {stop, not_used, S}.

terminate(_, S) ->
    gen_tcp:close(S#state.socket),
    ok.

code_change(_, S, _) ->
    {ok, S}.

%% @doc Register a send process
register_peer_send(Identifier, Peer) ->
    gen_hypar_util:register_self(name(Identifier, Peer)).

%% @doc Wait for a send process to register
wait_for(Identifier, Peer) ->
    gen_hypar_util:wait_for(name(Identifier, Peer)).

%% @doc The gproc name of a peer_send process
name(Identifier, Peer) ->
    {peer_send, Identifier, Peer}.
