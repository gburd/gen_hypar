%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @title The gen_hypar behaviour
%% @doc This behaviour implements a peer process in an overlay defined by the
%%      hyparview protocol.
%%
%%      The behaviour needs to implement:
%%      -spec start_link(Identifier, ModuleArgs) -> {ok, Pid}.
%%
%%      This function should spawn of a process and immediatly call:
%%      gen_hypar:register_and_wait(Identifier)
%%
%%      This is needed to make sure that all processes are synchronized and
%%      that the process should be reachable from outside.
%% 
%%      The process can then use join_cluster to join a cluster, after that
%%      it will start to receive messages on the form:
%%      
%%         {message, From :: id(), Msg :: binary()}
%%         {link_up, {Peer :: id(), SendPid :: pid()}}
%%         {link_down, Peer :: id()}
%%
%%     The callback process can then use gen_hypar:send_message/2 to send data
%%     over an active link to it's neighbours in the overlay.
-module(gen_hypar).

-callback start_link(Identifier :: id(), ModArgs :: any()) -> {ok, pid()}.

%% Operation
-export([start_link/4, join_cluster/2, get_peers/1, send_message/2]).

%% Registration & Coordination
-export([register_and_wait/1, wait_for/1, where/1]).

%% Incoming events
-export([deliver/3, link_up/3, link_down/2]).

-include("gen_hypar.hrl").

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
    DefaultedOpts = gen_hypar_opts:default(Options),
    gen_hypar_sup:start_link(Identifier, Module, ModuleArgs, DefaultedOpts).

-spec get_peers(Identifier :: id()) -> {ok, list(peer())} | {error, not_started}.
%% @doc Retrives peer ids and pids, should only be called from the gen_hypar process
get_peers(Identifier) ->
    hypar_node:get_peers(Identifier).

-spec send_message(Pid :: pid(), Msg :: iolist()) -> ok.
%% @doc Send a message to a peer
send_message(Pid, Msg) ->
    peer:send_message(Pid, Msg).

-spec join_cluster(Identifier :: id(), Contact :: id()) ->
                          ok | {error, could_not_connect}.
%% @doc Join a node to a cluster.
join_cluster(Identifier, Contact) ->
     hypar_node:join_cluster(Identifier, Contact).

-spec register_and_wait(Identifier :: id()) -> true | false.
%% @doc Register the gen_hypar process and wait until it's safe to continue
register_and_wait(Identifier) ->
    gen_hypar_util:register(name(Identifier)),
    hypar_node:wait_for(Identifier),
    ok.

%% @doc Find the gen_hypar process with the given identifier
-spec where(Identifier :: id()) -> pid() | undefined.
where(Identifier) ->
    gproc:where({n, l, name(Identifier)}).

%% @private Wait for the gen_hypar process to start
-spec wait_for(Identifier :: id()) -> ok.
wait_for(Identifier) ->
    gen_hypar_util:wait_for(name(Identifier)).

%% @private Gproc of the gen_hypar process
-spec name(Identifier :: id()) -> {gen_hypar, id()}.
name(Identifier) ->
    {gen_hypar, Identifier}.

%% Incoming events

-spec deliver(GenHypar :: pid(), Peer :: id(), Msg :: binary()) -> ok.
%% @private Used by the peer processes to deliver a message
deliver(GenHypar, Peer, Msg) ->
    GenHypar ! {message, Peer, Msg}.

-spec link_up(GenHypar :: pid(), Peer :: id(), Pid :: pid()) -> ok.
%% @private Used by the send process to signal a new link
link_up(GenHypar, Peer, Pid) ->
    GenHypar ! {link_up, {Peer, Pid}}.

-spec link_down(GenHypar :: pid(), Peer :: id()) -> ok.
%% @private When a peer either disconnects or fails
link_down(GenHypar, Peer) ->
    GenHypar ! {link_down, Peer}.
