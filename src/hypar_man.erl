%% -------------------------------------------------------------------
%%
%% The node logic, main module
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

%% @doc This module implements the node logic for the HyParView
%%      peer-sampling protocol.

-module(hypar_man).

-author('Emil Falk <emil.falk.1988@gmail.com>').

-behaviour(gen_server).

%% Include files
-include("hyparerl.hrl").

%% API
-export([start_link/2, join_cluster/2, get_peers/0, debug_state/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% The type of a priority
-type priority() :: high | low.

%% State record for the manager
-record(state, {this              :: #node{},
                active_view  = [] :: list(#peer{}),
                passive_view = [] :: list(#node{}),
                last_exchange = [] :: list(#node{}),
                neighbour_reqs = [] :: list(#peer{}),
                options           :: list(option()),
                notify :: atom()
               }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the hyparview manager in a supervision tree
start_link(Notify, Options) ->
    Args = [Notify, Options],
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

%% @doc Join a cluster via a contact-node
join_cluster(ContactIP, ContactPort) ->
    ContactNode = #node{ip=ContactIP, port=ContactPort},
    gen_server:cast(?MODULE, {join_cluster, ContactNode}).

%% @doc Retrive the current connected peers
get_peers() ->
    gen_server:call(?MODULE, get_peers).

%% @doc Debug-function, retrive the current state
debug_state() ->
    gen_server:call(?MODULE, debug_state).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
        
init([Myself, Options]) ->
    Notify = get_option(notify, Options),

    ?INFO([{?MODULE, "Initializing..."},
           {this, Myself},
           {notify, Notify}]),

    %% Seed the random number generator
    random:seed(now()),

    %% Check initial configuration
    ContactNode = get_option(contact_node, Options),
    if ContactNode =/= undefined ->
            {ContactIP, ContactPort} = ContactNode,
            join_cluster(#node{ip=ContactIP, port=ContactPort}, self())
    end,
    
    %% Start the timer to initiate the first period of the shuffling,
    %% randomize it abit to not overflow the network at synchrounos startup
    Period = get_option(shuffle_period, Options),
    erlang:send_after(Period, self(), shuffle_time),

    %% Initialize the state
    State = #state{this=Myself, options=Options, notify=Notify},
    {ok, State}.

%% - NEIGHBOUR -
%% Handle a neighbour-request. If the priority is set low the request is only
%% accepted if there is space in the active view. Otherwise it's rejected.
%% If the priority is high then the request is always accepted, even if one
%% active connection has to be dropped.
handle_cast({{neighbour, Node, low}, SenderPid},
            State=#state{active_view=Active,
                         options=Options}) ->
    ActiveSize = get_option(active_size, Options),
    NewPeer = connect_sup:new_peer(Node, SenderPid),
    case length(Active) < ActiveSize of
        true ->
            neighbour_accept(NewPeer),
            ?INFO([{?MODULE, "Received low priority neighbour-request, accepting it..."},
                   {peer, NewPeer}]),
            {noreply, add_node_active(NewPeer, State)};
        false ->            
            neighbour_decline(NewPeer),
            ?INFO([{?MODULE, "Received low priority neighbour-request, rejecting it..."},
                   {peer, NewPeer}]),
            {noreply, State}
    end;

%% Handle a high priority neighbour request
handle_cast({{neighbour, Node, high}, SenderPid},
            State) ->
    NewPeer = connect_sup:new_peer(Node, SenderPid),
    neighbour_accept(NewPeer),
    ?INFO([{?MODULE, "Received high priority neighbour-request, must accept..."},
           {peer, NewPeer}]),
    {noreply, add_node_active(NewPeer, State)};

%% Handle a neighbour_accept message sent as an answer to a neighbour_request
handle_cast({neighbour_accept, Pid},
            State0=#state{active_view=Active,
                          neighbour_reqs=NReqs0}) ->
    Peer = lists:keyfind(Pid, #peer.pid, NReqs0),
    NReqs = lists:keydelete(Pid, #peer.pid, NReqs0),
    State = State0#state{active_view=[Peer|Active], neighbour_reqs=NReqs},

    ?INFO([{?MODULE, "Neighbour accepted, adding to active view..."},
           {peer, Peer}]),
    {noreply, State};

handle_cast({neighbour_decline, Pid},
            State=#state{neighbour_reqs=NReqs0}) ->
    Peer = lists:keyfind(Pid, #peer.pid, NReqs0),
    NReqs = lists:keydelete(Pid, #peer.pid, NReqs0),
    ?INFO([{?MODULE, "Neighbour decline, trying a new one..."},
           {peer, Peer}]),
    {noreply, find_new_active(State#state{neighbour_reqs=NReqs})};

%% - JOIN -
%% Handle an incoming join-message, first time we see NewPid.
%% Monitor and add to active view.
handle_cast({{join, NewNode}, SenderPid},
            State0) ->
    %% Construct new active peer
    NewPeer = connect_sup:new_peer(NewNode, SenderPid),
    State = add_node_active(NewPeer, State0),

    ?INFO([{?MODULE, "Received a join message adding to active view..."},
           {peer, NewPeer}]),

    %% Forward the join to everyone in the active view
    ARWL = get_option(arwl, State#state.options),
    ForwardJoinFun =
        fun(Peer) when Peer#peer.id =/= NewNode ->
                forward_join(Peer, NewNode, ARWL);
           (_) -> ok
        end,
    
    %% NOTE: Seems stupid to call a function named remove_active here,
    %%       should rename or change it to be more clear. 
    ForwardPeers = remove_active(NewPeer, State#state.active_view),
    ?INFO([{?MODULE, "Sending forward-join message to active peers..."},
           {peers, ForwardPeers}]),
    lists:foreach(ForwardJoinFun, ForwardPeers),
    {noreply, State};

%% - FORWARD JOIN -
%% Handle an incoming forward-join, first case where either TTL is zero or
%% the active view only has one member
handle_cast({{forward_join, NewNode, TTL}, _SenderPid},
            State0=#state{this=Myself,
                          active_view=Active})
  when TTL =:= 0 orelse length(Active) =:= 1 ->
    ?INFO([{?MODULE, "Received forward_join, trying to add to active view..."},
           {node, NewNode},
           {ttl, TTL},
           {active_length, length(Active)}]),
    case forward_join_reply(NewNode, Myself) of
        Peer=#peer{} ->
            ?INFO([{?MODULE, "Forward join successful, adding to active view..."},
                   {peer, Peer}]),
            {noreply, add_node_active(Peer, State0)};
        Err ->
            ?ERROR([{?MODULE, "Error when trying to establish contact for forward-join reply..."},
                    Err]),
            {noreply, State0}
    end;

%% Catch the rest of the forward joins, maybe adds to passive view and
%% forwards the message to a random neighbour
handle_cast({{forward_join, NewNode, TTL}, SenderPid},
            State0=#state{active_view=Active,
                          options=Options}) ->
    ?INFO([{?MODULE, "Received forward-join..."},
           {node, NewNode}]),
    PRWL = get_option(prwl, Options),
    State =
        if TTL =:= PRWL ->
                ?INFO([{?MODULE, "Forward-join resulted in node added to passive view..."},
                       {ttl, TTL}]),
                add_node_passive(NewNode, State0);
           true ->
                State0
        end,

    %% Remove the sender as a possible recipient
    Peers = lists:keydelete(SenderPid, #peer.pid, Active),
    Peer = misc:random_elem(Peers),
    forward_join(Peer, NewNode, TTL-1),
    ?INFO([{?MODULE, "Sending forward-join to random neighbour..."},
           {neighbour, Peer}]),
    {noreply, State};

%% Handle an forward_join_reply message. This is in response to a propageted
%% join/forward-join. When a forward-join reaches a node that goes into the
%% active view of the joining node they open up an active connection. The
%% source node receives messages on this form from the forward-join-nodes.
%% (Not in protocol but needed for the logic to work.
handle_cast({{forward_join_reply, Node}, SenderPid},
            State) ->
    NewPeer = connect_sup:new_peer(Node, SenderPid),
    ?INFO([{?MODULE, "Receieved a forward_join-reply, adding node to active view..."},
           {peer, NewPeer}]),
    {noreply, add_node_active(NewPeer, State)};

%% - SHUFFLE -
%% Respond to a shuffle message, either accept the shuffle and reply to it
%% or propagate the message using a random walk.
handle_cast({{shuffle, Node, TTL, ExchangeList}, SenderPid},
            State=#state{active_view=Active})
  when TTL-1 > 0 andalso length(Active) > 1 ->
    %% Random walk, propagate the message to someone except for the sender
    Peers = lists:keydelete(SenderPid, #peer.pid, Active),
    RandomPeer = misc:random_elem(Peers),
    shuffle(RandomPeer, Node, TTL-1, ExchangeList),
    {noreply, State};

handle_cast({{shuffle, Node, _TTL, ExchangeList}, _SenderPid},
            State=#state{this=Myself,
                         passive_view=Passive}) ->
    ReplyList = misc:take_n_random(length(ExchangeList), Passive),
    case connect_sup:new_temp_peer(Node, Myself#node.ip) of
        Peer=#peer{} ->
            shuffle_reply(Peer, ReplyList),
            kill(Peer),
            {noreply, integrate_exchange_list(State, ExchangeList, ReplyList)};
        Err ->
            ?ERROR([{?MODULE, "Error when trying to establish temporary connection for shuffle-reply..."},
                    Err]),
            {noreply, State}
    end;

%% Take care of a shuffle reply message, integrate the reply into our view
handle_cast({{shuffle_reply, ReplyList}, _SenderPid},
            State0) ->
    State = integrate_exchange_list(State0, State0#state.last_exchange, ReplyList),
    {noreply, State};

%% Initate a shuffle procedure
handle_cast(shuffle_time,
            State=#state{this=Myself,
                         active_view=Active,
                         options=Options}) ->
    ExchangeList = create_exchange(State),
    RandomPeer = misc:random_elem(Active),
    ARWL = get_option(arwl, Options),
    shuffle(RandomPeer, Myself, ARWL, ExchangeList),

    %% Restart the timer
    Period = get_option(shuffle_period, Options),
    erlang:send_after(Period, self(), shuffle_time),
    {noreply, State#state{last_exchange=ExchangeList}};

%% - DISCONNECT -
%% Handle a disconnect-message. Close the connection and move the node
%% to the passive view
handle_cast({disconnect, Pid},
            State0=#state{active_view=Active,
                          passive_view=Passive}) ->
    case lists:keyfind(Pid, #peer.pid, Active) of
        false -> 
            ?INFO([{?MODULE, "Received a disconnect message from process not in active..."}]),
            {noreply, State0};
        #peer{}=Peer ->
            ?INFO([{?MODULE, "Received a disconnect message, will move peer from active to passive..."},
                   {peer, Peer}]),
            kill(Peer),
            State = State0#state{active_view=remove_active(Peer, Active),
                                 passive_view=[Peer#peer.id|Passive]},
            {noreply, find_new_active(State)}
    end;

%% - JOIN CLUSTER -
%% Handle an initial join_cluster message. Initiates a connection to a cluster via
%% the contact-node. 
handle_cast({join_cluster, ContactNode},
            State=#state{this=Myself}) ->
    ?INFO([{?MODULE, "Trying to join cluster via given contact-node..."},
           {contactnode, ContactNode}]),
    case join(ContactNode, Myself) of
        Peer=#peer{} ->
            ?INFO([{?MODULE, "Cluster join successful, adding contact-node to active view..."},
                   {peer, Peer}]),
            {noreply, State#state{active_view=[Peer]}};
        Err ->
            ?ERROR([{?MODULE, "Cluster join unsuccessful, error during join procedure..."},
                   Err]),
            {noreply, State}
    end.

%% - MONITOR/CONNECTION DOWN -
%% A monitor has gone down. This is equal to the connection has gone down.
%% This may be either an active connection or potential neighbour, in that
%% case we try to find a new active. The connection might be unimportant,
%% like a shuffle gone bad by which we just ignore it and continue.
%% NOTE: Unsure if I need to keep track of the Nodes that has been tried from
%%       the passive view before hand. Since they might be tried again here.
%%       if we are unlucky. I think this isn't nessecary, might be an optimization
%%       though.
handle_info({'DOWN', MRef, process, _Pid, _Reason},
            State=#state{active_view=Active0,
                         neighbour_reqs=NReqs0}) ->
    case lists:keyfind(MRef, #peer.mref, Active0) of
        Peer=#peer{} ->
            ?INFO([{?MODULE, "An active neighbour has become unreachable, find a new one..."},
                   {peer, Peer}]),
            Active = remove_active(MRef, Active0),
            {noreply, find_new_active(State#state{active_view=Active})};
        false ->
            case lists:keyfind(MRef, #peer.mref, NReqs0) of
                Peer=#peer{} ->
                    ?INFO([{?MODULE, "Peer that is currently being queried to become a neighbour went down, trying a new one..."},
                           {peer, Peer}]),
                    NReqs = lists:keydelete(MRef, #peer.mref, NReqs0),
                    {noreply, find_new_active(State#state{neighbour_reqs=NReqs})};
                false ->
                    ?INFO([{?MODULE, "An unimportant peer has died (not in active nor potential neighbour)..."}]),
                    {noreply, State}
            end
    end.

%% Get the current active peers from the node
handle_call(get_peers, _From, State) ->
    {reply, State#state.active_view, State};

%% Debug call
handle_call(debug_state, _From, State) ->
    {reply, State, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec create_exchange(State :: #state{}) -> list(#node{}).
%% @doc Create the exchange list used in a shuffle. 
create_exchange(#state{active_view=Active, passive_view=Passive,
                       this=Myself, options=Options}) ->
    KActive  = get_option(kactive, Options),
    KPassive = get_option(kpassive, Options),
    
    RandomActive  = misc:take_n_random(KActive, Active),
    RandomPassive = misc:take_n_random(KPassive, Passive),
    [Myself] ++ RandomActive ++ RandomPassive.

-spec integrate_exchange_list(State :: #state{}, 
                              ExchangeList :: list(#node{}),
                              ReplyList :: list(#node{})) ->
                                     #state{}.
%% @doc Takes the exchange-list and integrates it into the state. Removes nodes
%%      that are already in active/passive view from the list. If the passive view
%%      are full, start by dropping elements from ReplyList then random elements.
integrate_exchange_list(State=#state{this=Myself, active_view=Active,
                                     passive_view=Passive, options=Options},
                        ExchangeList0, ReplyList) ->
    Fun = fun(X) ->
                  X =/= Myself andalso
                      not lists:keymember(X, #peer.id, Active) andalso
                      not lists:member(X, Passive) end,
    ExchangeList = lists:filter(Fun, ExchangeList0),
    PassiveSize = get_option(passive_size, Options),
    SlotsNeeded = length(ExchangeList) - PassiveSize + length(Passive),
    NewPassive = free_slots(SlotsNeeded, Passive, ReplyList),
    State#state{passive_view=ExchangeList ++ NewPassive, last_exchange=[]}.
            
-spec free_slots(SlotsNeeded :: integer(), Passive :: list(#node{}),
                 ReplyList :: list(#node{})) -> list(#node{}).
%% @doc Free up slots in the passive list, start by removing elements
%%      from the ReplyList, then remove at random.
free_slots(I, Passive, _ReplyList) when I =< 0 ->
    Passive;
free_slots(I, Passive, []) ->
    misc:drop_n_random(I, Passive);
free_slots(I, Passive, [H|T]) ->
    case lists:member(H, Passive) of
        true  -> free_slots(I-1, lists:delete(H, Passive), T);
        false -> free_slots(I, Passive, T)
    end.

-spec remove_active(Entry :: #peer{}, Active :: list(#peer{})) ->
                           list(#peer{});
                   (Node :: #node{}, Active :: list(#peer{})) ->
                           list(#peer{});
                   (Pid :: pid(), Active :: list(#peer{})) ->
                           list(#peer{});
                   (MRef :: reference(), Active :: list(#peer{})) ->
                           list(#peer{}).
%% @pure
%% @doc Remove an entry from the active view
remove_active(#peer{id=Node}, Active) ->
    lists:keydelete(Node, #peer.id, Active);
remove_active(Node=#node{}, Active) ->
    lists:keydelete(Node, #peer.id, Active);
remove_active(Pid, Active) when is_pid(Pid) ->
    lists:keydelete(Pid, #peer.pid, Active);
remove_active(MRef, Active) when is_reference(MRef) ->
    lists:keydelete(MRef, #peer.mref, Active).

-spec add_node_active(Entry :: #peer{}, State :: #state{}) -> #state{}.
%% @doc Add a node to an active view, removing a node if necessary.
%%      The new state is returned. If a node has to be dropped, then
%%      it is informed via a DISCONNECT message.
add_node_active(Entry=#peer{id=Node},
                State0=#state{this=Myself, active_view=Active0,
                              options=Options}) ->
    case Node =/= Myself andalso
        not lists:keymember(Node, #peer.id, Active0) of
        true ->
            ActiveSize = get_option(active_size, Options),
            State = 
                case length(Active0) >= ActiveSize of
                    true  -> drop_random_active(State0);
                    false -> State0
                end,
            State#state{active_view=[Entry|State#state.active_view]};
        false ->
            State0
    end.

-spec add_node_passive(Node :: #node{}, State :: #state{}) -> #state{}.
%% @doc Add a node to the passive view, removing random entries if needed
add_node_passive(Node, State=#state{this=Myself, options=Options,
                                    active_view=Active,
                                    passive_view=Passive0}) ->
    case Node =/= Myself andalso 
        not lists:keymember(Node, #peer.id, Active) andalso
        not lists:member(Node, Passive0) of
        true ->
            PassiveSize = get_option(passive_size, Options),
            N = length(Passive0),
            Passive =
                case N >= PassiveSize of
                    true -> misc:drop_n_random(Passive0, N-PassiveSize+1);
                    false -> Passive0
                end,
            State#state{passive_view=Passive};
        false ->
            State
    end.

-spec find_new_active(State :: #state{}) -> #state{}.
%% @doc When a node is thought to have died this function is called.
%%      It will recursively try to find a new neighbour from the passive
%%      view until it finds a good one, send that node an asynchronous
%%      neighbour request.
find_new_active(State=#state{this=Myself,
                             active_view=Active,
                             passive_view=Passive,
                             neighbour_reqs=NReqs}) ->
    Priority = get_priority(Active),
    {NewPeer, NewPassive} = find_neighbour(Priority, Passive, Myself),
    State#state{passive_view=NewPassive, neighbour_reqs=[NewPeer|NReqs]}.

find_neighbour(Priority, Passive, Myself) ->
    find_neighbour(Priority, Passive, Myself, []).

find_neighbour(Priority, Passive, Myself, Tried) ->
    {Node, PassiveRest} = misc:drop_random(Passive),
    case connect_sup:new_peer(Node, Myself) of
        #peer{}=Peer ->
            ?INFO([{?MODULE, "Found a potential neighbour, querying it..."},
                   {peer, Peer}]),
            neighbour(Peer, Myself, Priority),
            {Peer, PassiveRest ++ Tried};
        Err ->
            ?ERROR([{?MODULE, "Error when trying to establish connection to potential neighbour, trying a new one..."},
                    {node, Node},
                    Err]),
            find_neighbour(Priority, PassiveRest, Myself, Tried)
    end.

-spec get_priority(list(#peer{})) -> priority().
%% @pure
%% @doc Find the priority of a new neighbour. If no active entries exist
%%      the priority is high, otherwise low.
get_priority([]) -> high;
get_priority(_)  -> low.

-spec drop_random_active(#state{}) -> #state{}.
%% @doc Drop a random node from the active view down to the passive view.
%%      Send a DISCONNECT message to the dropped node.
drop_random_active(State=#state{active_view=Active0, passive_view=Passive}) ->
    {Dropped, Active} = misc:drop_random(Active0),
    disconnect(Dropped),
    ?INFO([{?MODULE, "Dropping a random peer from the active view to make room..."},
           {peer, Dropped}]),
    State#state{active_view=Active,
                passive_view=[Dropped#peer.id|Passive]}.

%% -------------------------------
%% Message/Event related functions
%% -------------------------------

-spec join(ContactNode :: #node{}, Myself :: #node{}) ->
                  #peer{} | {error, any()}.
%% @doc Send a join message to a connection-handler, returning the new
%%      corresponding active entry. Should maybe add some wierd error-handling here.
%%      It isn't specified what is suppose to happen if the join fails. Retry maybe?
%%      Maybe an option to specify multiple contactnode and try them in order?
%%      Or maybe just ignore it, move on and let the user of the service just retry
%%      it with join_cluster.
join(ContactNode, Myself) ->
    case connect_sup:new_peer(ContactNode, Myself) of
        NewPeer=#peer{} ->
            connect:send_control(NewPeer, {join, Myself}),
            NewPeer;
        Err ->
            Err
    end.

-spec forward_join(Peer :: #peer{}, NewNode :: #node{},
                   TTL :: non_neg_integer()) -> ok.                           
%% @doc Send a forward-join message to a connection-handler
forward_join(Peer, NewNode, TTL) ->
    connect:send_control(Peer, {forward_join, NewNode, TTL}).

-spec forward_join_reply(Node :: #node{}, Myself :: #node{}) ->
                                #peer{} | {error, term()}.
%% @doc Response to a forward_join propagation. Tells the node who
%%      initiated the join to setup a connection
forward_join_reply(Node, Myself) ->
    case connect_sup:new_peer(Node, Myself) of
        Peer=#peer{} ->
            connect:send_control(Peer, {forward_join_reply, Myself}),
            Peer;
        Err ->
            Err      
    end.

-spec shuffle(Peer :: #peer{}, Myself :: #node{}, TTL :: non_neg_integer(),
              ExchangeList :: list(#node{})) -> ok.
%% @doc Send a shuffle message to a peer
shuffle(Peer, Myself, TTL, ExchangeList) ->
    connect:send_control(Peer, {shuffle, Myself, TTL, ExchangeList}).

-spec shuffle_reply(Peer :: #peer{}, ReplyList :: list(#node{})) -> ok.
%% @doc Send a shuffle-reply message to a peer
shuffle_reply(Peer, ReplyList) ->
    connect:send_control(Peer#peer.pid, {shuffle_reply, ReplyList}).

-spec neighbour(Peer :: #peer{}, Myself :: #node{}, Priority :: priority()) ->
                       ok | failed.
%% @doc Send a neighbour-request to a node, with a given priority.
neighbour(Peer, Myself, Priority) ->
    connect:send_control(Peer, {neighbour, Myself, Priority}).

%% @doc Accept a peer as a neighbour
neighbour_accept(Peer) ->
    connect:send_control(Peer, neighbour_accept).

%% @doc Decline a peer as a neighbour, demonitor the controling process
neighbour_decline(Peer) ->
    connect:send_control(Peer, neighbour_decline),
    demonitor(Peer#peer.mref).

-spec kill(Peer :: #peer{}) -> ok.
%% @doc Send a kill message to a connection-handler
kill(Peer) ->
    demonitor(Peer#peer.mref, [flush]),
    connect:kill(Peer).

-spec disconnect(Peer :: #peer{}) -> true.
%% @doc Send a disconnect message to a connection-handler
disconnect(Peer) ->
    demonitor(Peer#peer.mref, [flush]),
    connect:send_control(Peer, disconnect).

%% -------------------------
%% Options related functions
%% -------------------------

-spec get_option(Option :: atom(), Options :: list(option())) -> option().
%% @pure
%% @doc Get options, if undefined fallback to default.
get_option(Option, Options) ->
    case proplists:get_value(Option, Options) of
        undefined ->
            proplists:get_value(Option, default_options());
        Val ->
            Val
    end.

-spec default_options() -> list(option()).
%% @doc Default options for the hyparview-manager
default_options() ->
    [{ip, {127,0,0,1}},
     {port, 6000},
     {active_size, 5},
     {passive_size, 30},
     {arwl, 6},
     {prwl, 3},
     {k_active, 3},
     {k_passive, 4},
     {shuffle_period, 30000}].
