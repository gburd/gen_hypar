%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @private
%% @title Control peer process
%% @doc This is the main peer process. The hypar_node and gen_hypar process
%%      communicate with this process with in turn sends and receives messages
%%      via peer_send and peer_recv.
%% -------------------------------------------------------------------
-module(peer_ctl).

-behaviour(gen_server).

-export([start_link/5]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([send_message/2, incoming_message/2, forward_join/3, shuffle/4,
         disconnect/1]).

-export([wait_for/2]).

-record(state, {local,
                remote,
                socket,
                gen_hypar,
                hypar_node,
                peer_send}).

start_link(Identifier, Peer, Socket, GenHypar, HyparNode) ->
    Args = [Identifier, Peer, Socket, GenHypar, HyparNode],
    gen_server:start_link(?MODULE, Args, []).

%% @doc Send a message to a peer
send_message(CtlPid, Msg) ->
    gen_server:cast(CtlPid, {message, Msg}).

%% @doc Receive an incoming message from a peer
incoming_message(CtlPid, Msg) ->
    gen_server:cast(CtlPid, {incoming, Msg}).

%% @doc Send a forward join to a peer
forward_join(CtlPid, Peer, TTL) ->
    gen_server:cast(CtlPid, {forward_join, Peer, TTL}).

%% @doc Send a shuffle to a peer
shuffle(CtlPid, Peer, TTL, XList) ->
    gen_server:cast(CtlPid, {shuffle, Peer, TTL, XList}).

%% @doc Send a disconnect message to a peer
disconnect(CtlPid) ->
    gen_server:cast(CtlPid, disconnect).

init([Identifier, Peer, Socket, GenHypar, HyparNode]) ->    
    {ok, #state{local=Identifier,
                remote=Peer,
                socket=Socket,
                gen_hypar=GenHypar,
                hypar_node=HyparNode}, 0}.

handle_cast({incoming, Msg}, S) ->
    handle_incoming(Msg, S);
handle_cast({message, Msg}, S) ->
    peer_send:send_message(S#state.peer_send, Msg),
    {noreply, S};
handle_cast({forward_join, Peer, TTL}, S) ->
    peer_send:forward_join(S#state.peer_send, Peer, TTL),
    {noreply, S};
handle_cast({shuffle, Peer, TTL, XList}, S) ->
    peer_send:shuffle(S#state.peer_send, Peer, TTL, XList),
    {noreply, S};
handle_cast(disconnect, S) ->
    peer_send:disconnect(S#state.peer_send),
    {noreply, S}.

handle_call(_, _, State) ->
    {stop, not_used, State}.

%% Wait in the send process, then register the control peer
handle_info(timeout, S) ->
    {ok, SendPid} = peer_send:wait_for(S#state.local, S#state.remote),
    yes = register_peer_ctl(S#state.local, S#state.remote),
    {noreply, S#state{peer_send=SendPid}}.

terminate(_, S) ->
    gen_tcp:close(S#state.socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Handle an incoming message, send it to the gen_hypar process
handle_incoming({message, Bin}, S) ->
    gen_hypar:deliver(S#state.gen_hypar, S#state.remote, Bin),
    {noreply, S};
%% Send an incoming forward join to the hypar_node
handle_incoming({forward_join, Peer, TTL}, S) ->
    hypar_node:forward_join(S#state.hypar_node, S#state.remote, Peer, TTL),
    {noreply, S};
%% Send an incoming shuffle to the hypar_node
handle_incoming({shuffle, Peer, TTL, XList}, S) ->
    hypar_node:shuffle(S#state.hypar_node, S#state.remote, Peer, TTL, XList),
    {noreply, S};
%% Send an incoming disconnect to the hypar_node and shut down the peer
handle_incoming(disconnect, S) ->
    hypar_node:disconnect(S#state.hypar_node, S#state.remote),
    {stop, normal, S}.

%% @doc Register a control peer
register_peer_ctl(Identifier, Peer) ->
    gen_hypar_util:register_self(name(Identifier, Peer)).

%% @doc Wait for a control peer to start
wait_for(Identifier, Peer) ->
    gen_hypar_util:wait_for(name(Identifier, Peer)).

%% @doc Gproc name of a control peer
name(Identifier, Peer) ->
    {peer_ctl, Identifier, Peer}.
