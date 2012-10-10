%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @private
%% @title Outgoing connections (that is not active)
%% @doc Handle outgoing inactive peer connections. This is either new
%%      pending peers or temporary shuffle peers
%% -------------------------------------------------------------------
-module(peer_outgoing).

-export([join/3, join_reply/3, neighbour/4, shuffle_reply/4]).

%% @doc Start a new connection and fire away a join
join(Myself, Peer, Options) ->
    {ok, Socket} = proto_wire:start_connection(Myself, Peer, Options),
    ok = proto_wire:send_join(Socket, Myself),
    {ok, Socket}.

%% @doc Start a new outgoing connection and fire away a join-reply
join_reply(Myself, Peer, Options) ->
    {ok, Socket} = proto_wire:start_connection(Myself, Peer, Options),
    ok = proto_wire:send_join_reply(Socket, Myself),
    {ok, Socket}.

%% @doc Start a new outgoing connection and try to become neighbours
neighbour(Myself, Peer, Priority, Options) ->
    Timeout = gen_hypar_opts:timeout(Options),
    {ok, Socket} = proto_wire:start_connection(Myself, Peer, Options),
    ok = proto_wire:send_neighbour_request(Socket, Myself, Priority),
    case proto_wire:wait_for_neighbour_reply(Socket, Timeout) of
        accept  -> {ok, Socket};
        decline -> decline
    end.

%% @doc Since shuffle replys are just temporary connections we spawn a temp-
%%      process.
shuffle_reply(Myself, Peer, XList, Options) ->
    spawn(fun() -> do_shuffle_reply(Myself, Peer, XList, Options) end),
    ok.

%% @doc Start a socket and just fire away the shuffle reply
do_shuffle_reply(Myself, Peer, XList, Options) ->    
    {ok, Socket} = proto_wire:start_connection(Myself, Peer, Options),
    ok = proto_wire:send_shuffle_reply(Socket, XList).
