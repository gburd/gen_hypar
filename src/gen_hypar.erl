%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @private
%% @title The gen_hypar behaviour
%% @doc This behaviour implements a peer process in an overlay defined by the
%%      hyparview protocol.
%%
%%      The behaviour needs to implement:
%%      -spec start_link(Identifier, ModuleArgs) -> {ok, Pid}.
%%
%%      It then continusly receives messages on the form:
%%      
%%         {message, From :: id(), Msg :: binary()}
%%         {link_up, {Peer :: id(), SendPid :: pid()}}
%%         {link_down, Peer :: id()}
%%
%%     The callback process can then use gen_hypar:send/2 to send data over
%%     to it's neighbours in the overlay.
-module(gen_hypar).
-behaviour(gen_hypar).

-export([start_link/4, get_peers/1, send/2]).

-export([deliver/3, link_up/3, link_down/2]).

-include("gen_hypar.hrl").

-spec behaviour_info(callbacks) -> [{start_link, 3}];
                    (any())     -> undefined.
behaviour_info(callbacks) ->
    [{start_link, 2}];
behaviour_info(_) ->
    undefined.

-spec start_link(Identifier :: id(), Module :: module(), ModuleArgs :: any(),
                 Options :: options()) -> {ok, pid()}.
%% @doc Start a new unconnected gen_hypar node. 
%%      Identifier is the {Ip, Port} that the node is bound to.
%%      Module is the callback module implementing this behaviour
%%      ModuleArgs will be passed to the callback function on init
%%      Options are the gen_hypar options
%%      
%%      Supervisor-tree:
%%                gen_hypar_sup
%%               /      |     \
%%              /       |      \
%%      hypar_node peer_sup gen_hypar
%%                 /||...\
%%                peer1..n
start_link(Identifier, Module, ModuleArgs, Options) ->
    %% @doc Default unspecified options
    DefaultedOpts = gen_hypar_opts:default(Options),
    gen_hypar_sup:start_link(Identifier, Module, ModuleArgs, DefaultedOpts).

-spec get_peers(Identifier :: id()) -> {ok, list(peer())} | {error, not_started}.
%% @doc Retrives peer ids and pids, should only be called from the gen_hypar process
get_peers(Identifier) ->
    hypar_node:get_peers(Identifier).

-spec send(Pid :: pid(), Msg :: binary | iolist()) -> ok.
%% @doc Send a message
send(Pid, Msg) ->
    peer:send(Pid, Msg).

-spec join_cluster(Identifier :: id(), Contact :: id()) ->
                          ok | {error, could_not_connect}.
%% @doc Join a node to a cluster. Should only be used when the node is
%%      unconnected and should only be called from the gen_hypar process.
join_cluster(Identifier, Contact) ->
     hypar_node:join_cluster(Identifier, Contact).

-spec deliver(GenHypar :: pid(), Peer :: id(), Msg :: binary()) -> ok.
%% @doc Used by the peer processes to deliver a message
deliver(GenHypar, Peer, Msg) ->
    GenHypar ! {message, Peer, Msg}.

-spec link_up(GenHypar :: pid(), Peer :: id(), Pid :: pid()) -> ok.
%% @doc Used by the send process to signal a new link
link_up(GenHypar, Peer, Pid) ->
    GenHypar ! {link_up, {Peer, Pid}}.

-spec link_down(GenHypar :: pid(), Peer :: id()) -> ok.
%% @doc When a peer either disconnects or fails
link_down(GenHypar, Peer) ->
    GenHypar ! {link_down, Peer}.
