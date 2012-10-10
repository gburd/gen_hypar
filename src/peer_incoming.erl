%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @private
%% @title Incoming peers and listener functions
%% @doc Start and stop the listener and handle initial handshake on
%%      incoming sockets
%% -------------------------------------------------------------------
-module(peer_incoming).
-behavior(ranch_protocol).

-export([start_link/4, start_listener/2, stop_listener/1, incoming/3]).

-include("gen_hypar.hrl").

-spec start_link(ListenerPid :: pid(), Socket :: inet:socket(),
                 Transport :: module(), Args :: any()) -> {ok, pid()}.
start_link(ListenerPid, Socket, _Transport, Args) ->
    Pid = spawn_link(?MODULE, incoming, [ListenerPid, Socket, Args]),
    {ok, Pid}.

-spec start_listener(Identifier :: id(), Options :: options()) -> ok.
%% @private Start up the ranch listener, closing the old one if it exists.
start_listener({Ip, Port}=Identifier, Options) ->
    stop_listener(Identifier),
    Args = [self(), Options],
    {ok, _Pid} = ranch:start_listener({gen_hypar, Identifier}, 20, ranch_tcp,
                                      [{ip, Ip}, {port, Port}], ?MODULE, Args),
    ok.

-spec stop_listener(Identifier :: id()) -> ok.
%% @private Stop the ranch listener.
stop_listener(Identifier) ->    
    ranch:stop_listener({gen_hypar, Identifier}).

%% @private Start to receive an incoming connection and then transfer control
%%          to the hypar node.
incoming(ListenerPid, Socket, [HyparNode, Options]) ->
    ok = ranch:accept_ack(ListenerPid),
    case proto_wire:handle_incoming_connection(Socket, Options) of
        {join, Peer} ->
            gen_tcp:controlling_process(Socket, HyparNode),    
            hypar_node:join(HyparNode, Peer, Socket);
        {join_reply, Peer} ->
            gen_tcp:controlling_process(Socket, HyparNode),    
            hypar_node:join_reply(HyparNode, Peer, Socket);
        {neighbour, Peer, Priority} ->
            gen_tcp:controlling_process(Socket, HyparNode),
            hypar_node:neighbour(HyparNode, Peer, Priority, Socket);
        {shuffle_reply, XList} ->
            hypar_node:shuffle_reply(HyparNode, XList),
            peer:close(Socket)
    end.
