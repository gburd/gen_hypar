%% -------------------------------------------------------------------
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
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @private
%% @title HyParView node logic
%% @doc This module implements the node logic in the HyParView-protocol
%% -------------------------------------------------------------------
-module(hypar_node).

-behaviour(gen_server).

-include("hyparerl.hrl").

%%%===================================================================
%%% Exports
%%%===================================================================

%% Operations
-export([start_link/1, stop/0, join_cluster/1, get_id/0,
         get_peers/0, get_passive_peers/0]).

%% Incoming events
-export([join/1, join_reply/1, forward_join/3, neighbour/2, disconnect/1,
         error/2, shuffle/4, shuffle_reply/1]).

%% gen_server callbacks
-export([init/1, terminate/2, code_change/3,
         handle_call/3, handle_cast/2, handle_info/2]).

%%%===================================================================
%%% hypar_node state
%%%===================================================================

-record(st, {id            :: id(),              %% This nodes identifier
             activev = []  :: active_view(),     %% The active view
             passivev = [] :: passive_view(),    %% The passive view
             last_xlist    :: xlist(),           %% The last shuffle xlist sent
             opts          :: options(),         %% Options
             connect_opts  :: options(),         %% Options related to connections
             mod           :: module()           %% Callback module
            }).

%%%===================================================================
%%% Operation
%%%===================================================================

-spec start_link(Options :: options()) ->
                        {ok, pid()} | ignore | {error, any()}.
%% @doc Start the managing cluster node with <em>Options</em>.
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

-spec stop() -> ok.
%% @doc Stop the manager node for the cluster.
stop() ->
    gen_server:call(?MODULE, stop).

-spec join_cluster(ContactNodes :: list(id())) -> ok | could_not_connect;
                  (ContactNode :: id())        -> ok | could_not_connect.
%% @doc Try to join a cluster via <em>ContactNodes</em>. Try them in the order
%%      of the list.
join_cluster(ContactNodes) when is_list(ContactNodes) ->
    gen_server:call(?MODULE, {join_cluster, ContactNodes}, infinity);

%% @doc Try to join via the node <em>ContactNode</em>.
join_cluster(ContactNode) ->
    gen_server:call(?MODULE, {join_cluster, [ContactNode]}, infinity).

%% @doc Retrive the identifer of the node
get_id() ->
    gen_server:call(?MODULE, get_id, infinity).

-spec get_peers() -> list(#peer{}).
%% @doc Get all the current active peers.
get_peers() ->
    gen_server:call(?MODULE, get_peers, infinity).

-spec get_passive_peers() -> passive_view().
%% @doc Get all the current passive peers.
get_passive_peers() ->
    gen_server:call(?MODULE, get_passive_peers, infinity).

%%%===================================================================
%%% Incoming events
%%%===================================================================

-spec join(Peer :: #peer{}) -> ok.
%% @doc Join <em>Peer</em> to the node.
join(Peer) ->
    gen_server:call(?MODULE, {join, Peer}, infinity).

-spec forward_join(Peer :: #peer{}, NewNode :: id(),
                   TTL :: non_neg_integer()) -> ok.
%% @doc A forward join event with the newly joined node <em>NewNode</em> from
%%      <em>Peer</em> with time to live <em>TTL</em>.
forward_join(Peer, NewNode, TTL) ->
    gen_server:cast(?MODULE, {forward_join, Peer, NewNode, TTL}).

-spec join_reply(Peer :: #peer{}) -> ok.
%% @doc A join reply from <em>Peer</em>.
join_reply(Peer) ->
    gen_server:call(?MODULE, {join_reply, Peer}, infinity).

-spec neighbour(Peer :: #peer{}, Priority :: priority()) ->
                       accept | decline.
%% @doc Neighbour request from <em>Peer</em> with <em>Priority</em>.
neighbour(Peer, Priority) ->
    gen_server:call(?MODULE, {neighbour, Peer, Priority}, infinity).

-spec disconnect(Peer :: #peer{}) -> ok.
%% @doc Disconnect from <em>Peer</em>.
disconnect(Peer) ->
    gen_server:cast(?MODULE, {disconnect, Peer}).

-spec error(Peer :: #peer{}, Reason :: any()) -> ok.
%% @doc <em>Peer</em> has failed with <em>Reason</em>.
error(Peer, Reason) ->
    gen_server:cast(?MODULE, {error, Peer, Reason}).

-spec shuffle(Peer :: #peer{}, Requester :: id(), TTL :: non_neg_integer(),
              XList :: xlist()) -> ok.
%% @doc Shuffle request from <em>Peer</em>. The shuffle request originated
%%      in node <em>Requester</em> and <em>XList</em> contains sample node
%%      identifiers. The message has a time to live of <em>TTL</em>.
shuffle(Peer, Requester, TTL, XList) ->
    gen_server:cast(?MODULE, {shuffle, Peer, Requester, TTL, XList}).

-spec shuffle_reply(ReplyXList :: xlist()) -> ok.
%% @doc Shuffle reply that carries sample list <em>ReplyXList</em>.
shuffle_reply(ReplyXList) ->
    gen_server:cast(?MODULE, {shuffle_reply, ReplyXList}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

-spec init(Options :: options()) -> {ok, #st{}}.
%% Initialize the hypar_node
init(Options) ->
    %% Seed the random generator!
    random:seed(now()),

    %% Initialize the ranch_listener and return the connect arguments
    %% used to start new connections.
    ConnectOpts = connect:initialize(Options),

    %% Find this nodes id
    Myself = myself(ConnectOpts),
    lager:info("Initializing: ~p...~n", [Myself]),

    %% Start shuffle
    ShufflePeriod = proplists:get_value(shuffle_period, Options),
    shuffle_timer(ShufflePeriod),

    %% If there are defined contact nodes then we timeout after init and
    %% try to join them.
    State = #st{id=Myself,
                opts=Options,
                connect_opts=ConnectOpts,
                mod=callback(Options)},
    
    case proplists:is_defined(contact_nodes, Options) of
        true  -> {ok, State, 0};
        false -> {ok, State}
    end.

%% Join a cluster via given contact nodes
handle_call({join_cluster, ContactNodes}, _, S0) ->
    try_to_join(S0, ContactNodes);

%% Add newly joined node to active view, propagate forward joins
handle_call({join, NewPeer}, _, S0) ->
    S = add_active_peer(NewPeer, S0),

    #st{activev=ActiveV, opts=Opts} = S,
    ARWL = arwl(Opts),

    %% Forward join to all but the joining node
    NewId = NewPeer#peer.id,
    ForwardFun = fun(P) -> connect:forward_join(P, NewId, ARWL) end,
    lists:foreach(ForwardFun, lists:delete(NewPeer, ActiveV)),
    
    {reply, ok, S};

%% Accept a connection from the join procedure
handle_call({join_reply, Peer}, _, S0) ->
    {reply, ok, add_active_peer(Peer, S0)};

%% Neighbour request, either accept or decline based on priority and current
%% active view
handle_call({neighbour, Sender, Priority}, _, S) ->
    case Priority of
        %% High priority neighbour request thus the node needs to accept
        %% the request what ever the current active view is
        high ->
            lager:info("Neighbour accepted: ~p.~n", [Sender]),
            {reply, accept, add_active_peer(Sender, S)};
        %% Low priority request, only accept if we have space in the
        %% nodes active view
        low ->
            #st{activev=ActiveV, opts=Opts} = S,            
            case length(ActiveV) < active_size(Opts) of
                true  ->
                    {reply, accept, add_active_peer(Sender, S)};
                false ->
                    lager:info("Neighbour declined ~p.~n", [Sender]),
                    {reply, decline, S}
            end
    end;

%% Return current active peers
handle_call(get_peers, _, S) ->
    {reply, S#st.activev, S};

%% Return current passive peers
handle_call(get_passive_peers, _, S) ->
    {reply, S#st.passivev, S};

%% Return the identifier
handle_call(get_id, _, S) ->
    {reply, S#st.id, S};

%% Stop the hypar_node
handle_call(stop, _, S) ->
    connect:stop(),
    {stop, normal, ok, S}.

%% Disconnect an open active connection, add disconnecting node to passive view
handle_cast({disconnect, Sender}, S) ->
    %% Disconnect the peer, close the connection and add node to passive view
    ActiveV = lists:delete(Sender, S#st.activev),
    {noreply, add_passive_peer(Sender#peer.id, S#st{activev=ActiveV})};

%% Handle failing connections. Try to find a new one if possible
handle_cast({error, Sender, Reason}, S0) ->
    lager:error("Active link to ~p failed with error ~p.~n",
                [Sender, Reason]),
    S = S0#st{activev=lists:delete(Sender, S0#st.activev)},
    {noreply, find_new_active(S)};

%% Respond to a forward_join, add to active or propagate and maybe add to
%% passive view.
handle_cast({forward_join, Sender, NewNode, TTL}, S0) ->
    #st{id=Myself, activev=ActiveV, connect_opts=ConnectOpts, opts=Opts} = S0,

    case TTL =:= 0 orelse length(ActiveV) =:= 1 of
        true ->
            %% Add to active view, send a reply to the join_reply to let the
            %% other node know, check to see that you don't send you yourself
            case Myself =/= NewNode andalso
                not lists:keymember(NewNode, #peer.id, ActiveV) of
                true ->
                    case connect:join_reply(NewNode, ConnectOpts) of
                        {ok, NewPeer} ->
                            {noreply, add_active_peer(NewPeer, S0)};
                        Err ->
                            lager:error("Join reply error ~p to ~p.~n", [Err, NewNode]),
                            {noreply, S0}
                    end;
                false ->
                    {noreply, S0}
            end;
        false ->
            %% Add to passive view if TTL is equal to PRWL
            S1 = case TTL =:= prwl(Opts) of
                     true  -> add_passive_peer(NewNode, S0);
                     false -> S0
                 end,

            %% Propagate the forward join using a random walk
            RandomPeer = misc:random_elem(lists:delete(Sender, ActiveV)),
            connect:forward_join(RandomPeer, NewNode, TTL-1),

            {noreply, S1}
    end;

%% Respond to a shuffle request, either propagate it or accept it via a
%% temporary connection to the source of the request. If the node accept then
%% it adds the shuffle list into it's passive view and responds with with
%% a shuffle reply
handle_cast({shuffle, Sender, Requester, TTL, XList}, S) ->
    #st{activev=ActiveV, passivev=PassiveV, connect_opts=ConnectOpts} = S,

    case TTL > 0 andalso length(ActiveV) > 1 of
        %% Propagate the random walk
        true ->
            RandomPeer = misc:random_elem(lists:delete(Sender, ActiveV)),
            connect:shuffle(RandomPeer, Requester, TTL-1, XList),
            {noreply, S};
        %% Accept the shuffle request, add to passive view and reply
        false ->
            ReplyXList = misc:take_n_random(length(XList), PassiveV),
            connect:shuffle_reply(Requester, ReplyXList, ConnectOpts),
            {noreply, add_xlist(S, XList, ReplyXList)}
    end;

%% Accept a shuffle reply, add the reply list into the passive view and
%% close the temporary connection.
handle_cast({shuffle_reply, ReplyXList}, S0) ->
    S = add_xlist(S0#st{last_xlist=[]}, ReplyXList, S0#st.last_xlist),
    {noreply, S}.

%% The node was supplied with contact nodes, try to connect to the cluster
handle_info(timeout, S) ->
    ContactNodes = proplists:get_value(contact_nodes, S#st.opts),
    spawn(fun() ->
                  %% Wait for connect_sup to start then join
                  timer:sleep(100),
                  ?MODULE:join_cluster(ContactNodes)
          end),
    {noreply, S};

%% Timer message for periodic shuffle. Send of a shuffle request to a random
%% peer in the active view. Ignore if we don't have any active connections.
handle_info(shuffle, S) ->
    #st{activev=ActiveV, opts=Opts} = S,
    NewXList = 
        case ActiveV =:= [] of
            %% No active peers to send shuffle to
            true ->                
                [];

            %% Send the shuffle to a random peer
            false ->
                XList = create_xlist(S),
                P = misc:random_elem(ActiveV),                
                
                connect:shuffle(P, S#st.id, arwl(Opts)-1, XList),
                XList
        end,
    
    shuffle_timer(shuffle_period(Opts)),

    {noreply, S#st{last_xlist=NewXList}}.

code_change(_, S, _) ->
    {ok, S}.

terminate(_, _) -> ok.

%%%===================================================================
%%% Active view related
%%%===================================================================

-spec add_active_peer(Peer :: #peer{}, S0 :: #st{}) -> #st{}.
%% @doc Add <em>Peer</em> to the active view in state <em>S0</em>, removing a
%%      node if necessary. The new state is returned. If a node has to be
%%      dropped, then it is informed via a DISCONNECT message and placed in the
%%      passive view.
add_active_peer(Peer, S0) ->
    NodeId = Peer#peer.id,
    #st{id=Myself, activev=ActiveV0, opts=Opts} = S0,
        
    case NodeId =/= Myself andalso
        not lists:keymember(NodeId, #peer.id, ActiveV0) of
        true ->
            S = case length(ActiveV0) >= active_size(Opts) of
                    true  -> drop_random_active(S0);
                    false -> S0
                end,
            S#st{activev=[Peer|S#st.activev],
                 %% Make sure peer are not in both view.
                 passivev=lists:delete(Peer#peer.id, S#st.passivev)};
        false ->
            S0
    end.

-spec drop_random_active(S :: #st{}) -> #st{}.
%% @doc Drop a random node from the active view in state down to the passive
%%      view in <em>S</em>. Send a disconnect message to the dropped node.
drop_random_active(S) ->
    #st{activev=ActiveV0, passivev=PassiveV0, opts=Opts} = S,

    Slots = length(PassiveV0)-passive_size(Opts)+1,
    {Peer, ActiveV} = misc:drop_random(ActiveV0),
    PassiveV = [Peer#peer.id|misc:drop_n_random(Slots, PassiveV0)],

    connect:disconnect(Peer),
    
    S#st{activev=ActiveV, passivev=PassiveV}.

-spec find_new_active(S :: #st{}) -> #st{}.
%% @doc Find a new active peer in state <em>S</em>. The function will send
%%      neighbour requests to nodes in passive view until it finds a good one.
find_new_active(S) ->
    Priority = get_priority(S#st.activev),

    case find_neighbour(Priority, S#st.passivev, S#st.connect_opts) of
        {no_valid, PassiveV} ->
            lager:info("No accepting peers in passive view.~n"),
            S#st{passivev=PassiveV};
        {Peer, PassiveV} ->
            add_active_peer(Peer, S#st{passivev=PassiveV})
    end.

-spec find_neighbour(Priority :: priority(), PassiveV :: passive_view(),
                    ConnectArgs :: options()) -> {#peer{} | no_valid, passive_view()}.
%% @doc Try to find a new active neighbour to <em>ThisNode</em> with priority
%%      <em>Priority</em>. Try random nodes out of <em>PassiveV</em>, removing
%%      failing once and logging declined requests. Returns either a new active
%%      peer along with the new passive view or <b>no_valid</b> if no peers
%%      were connectable.
find_neighbour(Priority, PassiveV, ConnectOpts) ->
    find_neighbour(Priority, PassiveV, ConnectOpts, []).

-spec find_neighbour(Priority :: priority(), PassiveV :: passive_view(),
                     ConnectOpts :: options(), Tried :: view()) ->
                            {#peer{} | no_valid, passive_view()}.
%% @doc Helper function for find_neighbour/3.
find_neighbour(_, [], _, Tried) ->
    {no_valid, Tried};
find_neighbour(Priority, PassiveV0, ConnectOpts, Tried) ->
    {Node, Passive} = misc:drop_random(PassiveV0),
    case connect:neighbour(Node, Priority, ConnectOpts) of
        {ok, P} -> {P,Passive ++ Tried};
        decline -> find_neighbour(Priority, Passive, ConnectOpts, [Node|Tried]);
        Err ->
            lager:error("Neighbour error ~p to ~p.~n", [Err, Node]),
            find_neighbour(Priority, Passive, ConnectOpts, Tried) 
    end.

-spec try_to_join(S :: #st{}, list(id())) ->
                         ok | {error, could_not_connect}.
%% @doc Recursivly try to send a join to the contact nodes in order.
try_to_join(S, []) ->
    {reply, {error, could_not_connect}, S};
try_to_join(S, [ContactNode|Nodes]) ->
    case connect:join(ContactNode, S#st.connect_opts) of
        {ok, P} ->
            {reply, ok, add_active_peer(P, S)};
        {error, Err} ->
            lager:error("Join cluster via ~p failed with error ~p.~n",
                        [ContactNode, Err]),
            try_to_join(S, Nodes)
    end.

%%%===================================================================
%%% Passive view functions
%%%===================================================================

-spec add_passive_peer(Node :: id(), S :: #st{}) -> #st{}.
%% @doc Add <em>Node</em> to the passive view in state <em>S</em>, removing
%%      random entries if needed.
add_passive_peer(Node, S) ->
    ActiveV = S#st.activev,
    PassiveV0 = S#st.passivev,
    Id = S#st.id,
    case node_ok(Node, Id, ActiveV, PassiveV0) of
        true ->
            PSize = proplists:get_value(passive_size, S#st.opts),
            Slots = length(PassiveV0)-PSize+1,
            %% drop_n_random returns the same list if called with 0 or negative
            PassiveV =  [Node|misc:drop_n_random(Slots, PassiveV0)],
            S#st{passivev=PassiveV};
        false ->
            S
    end.

-spec node_ok(Node :: id(), Myself :: id(), ActiveV :: active_view(),
              PassiveV :: passive_view()) -> boolean().
%% @doc Check so that a node is not equal to myself and are not in any of
%%      the views.
node_ok(NodeId, Myself, ActiveV, PassiveV) ->
    NodeId =/= Myself andalso not lists:keymember(NodeId, #peer.id, ActiveV)
        andalso not lists:member(NodeId, PassiveV).

%%%===================================================================
%%% Shuffle related functions
%%%===================================================================

-spec shuffle_timer(ShufflePeriod :: non_neg_integer()) -> ok;
                   (undefined) -> ok.
%% @doc Set the shuffle timer to <em>ShufflePeriod</em>. Or if undefined
%%      this is a no-op that returns ok.
shuffle_timer(ShufflePeriod) ->
    case ShufflePeriod of
        undefined ->
            ok;
        ShufflePeriod ->
            erlang:send_after(ShufflePeriod, self(), shuffle),
            ok
    end.

-spec add_xlist(S :: #st{}, XList0 :: xlist(), ReplyList :: xlist()) -> #st{}.
%% @doc Add <em>XList0</em> into the passive view in state <em>S</em>. Does not
%%      add nodes that are already in any view from the list. If the
%%      passive view are full, start by dropping elements from ReplyList then random
%%      elements.
add_xlist(S, XList0, ReplyList) ->
    #st{id=Myself, activev=ActiveV, passivev=PassiveV0, opts=Opts} = S,

    %% Filter out ourselves and nodes in active and passive view
    Filter = fun(NodeId) -> node_ok(NodeId, Myself, ActiveV, PassiveV0) end,
    XList = lists:filter(Filter, XList0),
    
    %% If we need slots then first drop nodes from ReplyList then at random
    Slots = length(PassiveV0)-passive_size(Opts)+length(XList),
    PassiveV = free_slots(Slots, PassiveV0, ReplyList),
    S#st{passivev=PassiveV++XList}.

-spec create_xlist(S :: #st{}) -> xlist().
%% @doc Create the exchange list in state <em>S</em> for the next shuffle
%%      request.
create_xlist(S) ->
    #st{id=Myself, activev=ActiveV0, passivev=PassiveV, opts=Opts} = S,

    %% We are only intrested in the id when we construct the shuffle
    ActiveV = [P#peer.id || P <- ActiveV0],

    RandomActive  = misc:take_n_random(k_active(Opts), ActiveV),
    RandomPassive = misc:take_n_random(k_passive(Opts), PassiveV),
    [Myself | (RandomActive ++ RandomPassive)].

%%%===================================================================
%%% Auxillary functions 
%%%===================================================================
-spec get_priority(list(#peer{})) -> priority().
%% @pure
%% @doc Find the priority of a neighbour. If no active entries exist
%%      the priority is <b>high</b>, otherwise <b>low</b>.
get_priority([]) -> high;
get_priority(_)  -> low.

-spec free_slots(I :: integer(), List :: list(T), Rs :: list(T)) -> list(T).
%% @pure
%% @doc Free up <em>I</em> slots in <em>List</em>, start by removing elements
%%      from <em>Rs</em>, then remove at random.
free_slots(I, List, _) when I =< 0 -> List;
free_slots(I, List, []) -> misc:drop_n_random(I, List);
free_slots(I, List, [R|Rs]) ->
    case lists:member(R, List) of
        true  -> free_slots(I-1, lists:delete(R, List), Rs);
        false -> free_slots(I, List, Rs)
    end.

%%%===================================================================
%%% Options related
%%%===================================================================
%% @todo Move into own file

%% Functions to nicen up the code abit
myself(Opts)        -> proplists:get_value(id, Opts).
arwl(Opts)          -> proplists:get_value(arwl, Opts).
prwl(Opts)          -> proplists:get_value(prwl, Opts).
active_size(Opts)   -> proplists:get_value(active_size, Opts).
passive_size(Opts)  -> proplists:get_value(passive_size, Opts).                     
k_active(Opts)      -> proplists:get_value(k_active, Opts).
k_passive(Opts)     -> proplists:get_value(k_passive, Opts).
callback(Opts)       -> proplists:get_value(mod, Opts, noop).
shuffle_period(Opts) -> proplists:get_value(shuffle_period, Opts).
