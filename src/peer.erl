%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @private
%% @title A peer
%% @doc A peer is a supervisor with three children;
%%      A control process that talks with the hypar_node
%%      A send process that takes care of all sending
%%      A receive process that takes care of all receiveing
%%
%%      If either dies then the whole peer dies.
%%     
%%      This module also acts as an interface to:
%%      peer_outgoing, peer_ctl, peer_send, peer_recv
%% -------------------------------------------------------------------
-module(peer).
-behaviour(supervisor).

-export([start_link/6]).
-export([init/1]).

-export([new/5, forward_join/3, shuffle/4, send/2, disconnect/1, close/1]).

%% @doc Start a peer supervisor
start_link(Identifier, Peer, Socket, GenHypar, HyparNode, Options) ->
    supervisor:start_link(?MODULE, [Identifier, Peer, Socket, GenHypar, HyparNode, Options]).

%% @doc Create a new peer, wait for the sub-process to spin up. The given
%%      socket is ready to become an active peer.
%%
%%      We need the property that link_up messages are received before any
%%      incoming messages. We let the receiver wait until it is safe.
%%
new(PeerSup, Peer, Socket, GenHypar, Options) ->
    Args = [Peer, Socket, GenHypar, self(), Options],
    {ok, _Pid} = supervisor:start_child(PeerSup, Args),
    {ok, CtlPid} = peer_ctl:wait_for(Peer),
    {ok, RecvPid} = peer_recv:wait_for(Peer),
    gen_tcp:controlling_process(Socket, RecvPid),
    gen_hypar:link_up(GenHypar, Peer, CtlPid),
    peer_recv:go_ahead(RecvPid, Socket),
    {ok, CtlPid}.

%% @doc Send a forward join to a peer
forward_join(Pid, Peer, TTL) ->
    peer_ctl:forward_join(Pid, Peer, TTL).

%% @doc Send a shuffle to a peer
shuffle(Pid, Peer, TTL, XList) ->
    peer_ctl:shuffle(Pid, Peer, TTL, XList).

%% @doc Send a message to a peer
send(Pid, Msg) ->
    peer_ctl:send_message(Pid, Msg).

%% @doc Disconnect a peer, demonitor it
disconnect(CtlPid) ->
    peer_ctl:disconnect(CtlPid),
    erlang:demonitor(CtlPid, [flush]).

-spec close(Socket :: inet:socket()) -> ok.
%% @doc Wrapper for gen_tcp:close/1.
close(Socket) ->
    gen_tcp:close(Socket).

%% A peer consist of three processes, a control, a send and
%% a receive process.
init([Identifier, Peer, Socket, GenHypar, HyparNode, Options]) ->
    Timeout = gen_hypar_opts:timeout(Options),
    KeepAlive = gen_hypar_opts:keep_alive(Options),
    PeerCtl = {peer_ctl,
               {peer_ctl, start_link, [Identifier, Peer, Socket, GenHypar, HyparNode]},
               permanent, 5000, worker, [peer_ctl]},
    PeerSend = {peer_send,
                {peer_send, start_link, [Identifier, Peer, Socket, KeepAlive]},
                permanent, 5000, worker, [peer_send]},
    PeerRecv = {peer_recv,
                {peer_recv, start_link, [Identifier, Peer, Socket, Timeout]},
                permanent, 5000, worker, [peer_recv]},
    {ok, {one_for_all, 0, 1}, [PeerCtl, PeerSend, PeerRecv]}.
