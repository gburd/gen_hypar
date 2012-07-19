%% @doc This module implements the node logic for the HyParView
%%      peer-sampling protocol.
-module(hypar_man).

-behaviour(gen_server).

%% Include files
-include("hyparerl.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-type priority() :: high | low.

%% Peer entry record
-record(peer, {id   :: #node{},
               pid  :: pid(),
               mref :: reference()
              }).

%% State record for the manager
-record(state, {this              :: #node{},
                active_view  = [] :: list(#peer{}),
                passive_view = [] :: list(#node{}),
                last_exchange = [] :: list(#node{}),
                options           :: list(option())
               }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the hyparview manager in a supervision tree
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
        
init([Options]) ->
    %% Seed the random number generator
    random:seed(now()),

    %% Check initial configuration
    ContactNode = get_option(cluster, Options),
    if ContactNode =/= undefined ->
       gen_server:cast(self(), {join_cluster, ContactNode})
    end,
    
    %% Start the timer to initiate the first period of the shuffling,
    %% randomize it abit to not overflow the network at synchrounos startup
    Period = get_option(shuffle_period, Options),
    erlang:send_after(Period, self(), shuffle_time),

    %% Initialize the state
    {ok, #state{this=this_node(Options), options=Options}}.

%% Handle an incoming join-message, first time we see NewPid.
%% Monitor and add to active view.
handle_cast({{join, NewNode}, NewPid}, State0) ->
    %% Construct new active entry
    MRef = monitor(process, NewPid),
    NewPeer = new_peer(NewNode, NewPid, MRef),
    State = add_node_active(NewPeer, State0),

    %% Forward the join to everyone in the active view
    ARWL = get_option(arwl, State#state.options),
    ForwardFun = fun(Peer) when Peer#peer.id =/= NewNode ->
                         forward_join(Peer, NewNode, ARWL);
                    (_) -> ok
                 end,
    lists:foreach(ForwardFun, State#state.active_view),
    {noreply, State};

%% Handle an incoming forward-join, first case where either TTL is zero or
%% the active view only has one member
handle_cast({{forward_join, NewNode, TTL}, _Pid},
            State0=#state{this=Myself, active_view=Active})
  when TTL =:= 0 orelse length(Active) =:= 1 ->
    State = case add_me(NewNode, Myself) of
                #peer{}=Peer ->
                    add_node_active(Peer, State0);
                Err ->
                    ?DEBUG(Err),
                    State0
            end,
    {noreply, State};

%% Catch the rest of the forward joins, maybe adds to passive view and
%% forwards the message to a random neighbour
handle_cast({{forward_join, NewNode, TTL}, Pid},
            State0=#state{active_view=Active, options=Options}) ->
    PRWL = get_option(prwl, Options),
    State =
        if TTL =:= PRWL ->
                add_node_passive(NewNode, State0);
           true ->
                State0
        end,

    %% Remove the sender as a possible recipient
    Peers = lists:keydelete(Pid, #peer.pid, Active),
    Peer = misc:random_elem(Peers),
    forward_join(Peer, NewNode, TTL-1),
    {noreply, State};

%% Respond to a shuffle message, either accept the shuffle and reply to it
%% or propagate the message using a random walk.
handle_cast({{shuffle, Node, TTL, ExchangeList}, Pid},
            State=#state{active_view=Active})
  when TTL-1 > 0 andalso length(Active) > 1 ->
    %% Random walk, propagate the message to someone except for the sender
    Peers = lists:keydelete(Pid, #peer.pid, Active),
    RandomPeer = misc:random_elem(Peers),
    shuffle(RandomPeer, Node, TTL-1, ExchangeList),
    {noreply, State};
handle_cast({{shuffle, Node, _TTL, ExchangeList}, _Pid},
            State=#state{this=Myself,
                         active_view=Active,
                         passive_view=Passive}) ->
    ReplyList = misc:take_n_random(length(ExchangeList), Passive),
    case lists:keyfind(Node, #peer.id, Active) of
        Peer=#peer{} ->
            shuffle_reply(Peer, ReplyList);
        false ->
            case connect_sup:start_connection(Node, Myself) of
                {ok, Pid, MRef} ->
                    Peer = new_peer(Node, Pid, MRef),
                    shuffle_reply(Peer, ReplyList),
                    kill(Peer);
                {error, _Reason} ->
                    io:format("Error connect, skipping shufflereply")
            end
    end,
    {noreply, integrate_exchange_list(State, ExchangeList, ReplyList)};
%% Take care of a shuffle reply message
handle_cast({{shuffle_reply, ReplyList}, _Pid},
            State0=#state{last_exchange=ExchangeList}) ->
    State = State0#state{last_exchange=[]},
    {noreply, integrate_exchange_list(State, ExchangeList, ReplyList)};

%% Initate a shuffle procedure
handle_cast(shuffle, State=#state{this=Myself, active_view=Active,
                                  options=Options}) ->
    ExchangeList = create_exchange(State),
    RandomPeer = misc:random_elem(Active),
    ARWL = get_option(arwl, Options),
    shuffle(RandomPeer, Myself, ARWL, ExchangeList),
    {noreply, State#state{last_exchange=ExchangeList}};
%% Handle a disconnect-message. Close the connection and move the node
%% to the passive view
handle_cast({disconnect, Pid}, State0=#state{active_view=Active,
                                             passive_view=Passive}) ->
    State = case lists:keyfind(Pid, #peer.pid, Active) of
                false -> State0;
                #peer{}=Peer ->
                    kill(Peer),
                    State0#state{active_view=remove_active(Peer, Active),
                                 passive_view=[Peer#peer.id|Passive]}
            end,
    {noreply, State};

%% Handle an add_me message. This is in response to a propageted join/forward-join.
%% When a forward-join reaches a node that goes into the active view of the joining node
%% they open up an active connection. The source node receives messages on this form from
%% the forward-join-nodes. (Not in protocol but needed for the logic to work.
handle_cast({{add_me, Node}, Pid}, State) ->
    MRef = monitor(process, Pid),
    NewPeer = new_peer(Node, Pid, MRef),
    {noreply, add_node_active(NewPeer, State)};
handle_cast({init, ContactNode}, State=#state{this=Myself}) ->
    Peer = join(ContactNode, Myself),
    {noreply, State#state{active_view=[Peer]}}.

%% Handle a neighbour-request. If the priority is set low the request is only
%% accepted if there is space in the active view. Otherwise it's rejected.
%% If the priority is high then the request is always accepted, even if one
%% active connection has to be dropped.
handle_call({neighbour, Node, low}, {Pid,_Ref},
            State=#state{active_view=Active, options=Options}) ->
    ActiveSize = get_option(active_size, Options),
    case length(Active) < ActiveSize of
        true ->
            MRef = monitor(process, Pid),
            NewPeer = new_peer(Node, Pid, MRef),
            {reply, ok, add_node_active(NewPeer, State)};
        false ->
            {reply, full, State}
    end;
handle_call({neighbour, Node, high}, {Pid, _Ref}, State) ->
    MRef = monitor(process, Pid),
    NewPeer = new_peer(Node, Pid, MRef),
    {reply, ok, add_node_active(NewPeer, State)}.

%% A monitor has gone down. This is equal to the connection has gone down.
%% Thus we remove the process/node from the active view and try to find a new.
handle_info({'DOWN', MRef, process, _Pid, _Reason},
            State=#state{active_view=Active0}) ->
    case lists:keymember(MRef, #peer.mref, Active0) of
        true ->
            Active = remove_active(MRef, Active0),
            {noreply, find_new_active(State#state{active_view=Active})};
        false ->
            {noreply, State}
    end.

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
    State#state{passive_view=ExchangeList ++ NewPassive}.
            
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

-spec new_peer(Node :: #node{}, Pid :: pid(), MRef :: reference()) ->
                      #peer{}.
%% @pure
%% @doc Create a new peer entry for given Node, Pid and MRef
new_peer(Node, Pid, MRef) ->
    #peer{id=Node, pid=Pid, mref=MRef}.

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
    lists:key_dete(MRef, #peer.mref, Active).

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
%%      view until it finds a good one.
find_new_active(State=#state{this=Myself,
                             active_view=Active, passive_view=Passive}) ->
    Priority = get_priority(Active),
    {NewPeer, NewPassive} = find_neighbour(Priority, Passive, Myself),
    State#state{active_view=[NewPeer|Active], passive_view=NewPassive}.

find_neighbour(Priority, Passive, Myself) ->
    find_neighbour(Priority, Passive, Myself, []).

find_neighbour(Priority, Passive, Myself, Tried) ->
    {Node, PassiveRest} = misc:drop_random(Passive),
    case connect_sup:start_connection(Node, Myself) of
        #peer{}=Peer ->
            case neighbour(Peer, Myself, Priority) of
                ok -> 
                    {Peer, PassiveRest ++ Tried};
                failed ->
                    kill(Peer),
                    find_neighbour(Priority, PassiveRest, Myself, [Node|Tried])
            end;
        Err ->
            ?DEBUG(Err),
            find_neighbour(Priority, PassiveRest, Myself, Tried)
    end.

-spec shuffle(Peer :: #peer{}, Myself :: #node{}, TTL :: non_neg_integer(), ExchangeList :: list(#node{})) -> ok.
%% @doc Send a shuffle message to a peer
shuffle(Peer, Myself, TTL, ExchangeList) ->
    connect:send_message(Peer#peer.pid, {shuffle, Myself, TTL, ExchangeList}).

-spec shuffle_reply(Peer :: #peer{}, ReplyList :: list(#node{})) -> ok.
%% @doc Send a shuffle-reply message to a peer
shuffle_reply(Peer, ReplyList) ->
    connect:send_message(Peer#peer.pid, {shuffle_reply, ReplyList}).

-spec neighbour(Peer :: #peer{}, Myself :: #node{}, Priority :: priority()) ->
                       ok | failed.
%% @doc Send a neighbour-request to a node, with a given priority.
neighbour(#peer{pid=Pid}, Myself, Priority) ->
    connect:send_sync_message(Pid, {neighbour, Myself, Priority}).

-spec get_priority(list(#peer{})) -> priority().
%% @pure
%% @doc Find the priority of a new neighbour. If no active entries exist
%%      the priority is high, otherwise low.
get_priority([]) -> high;
get_priority(_)  -> low.

-spec join(ContactNode :: #node{}, Myself :: #node{}) -> #peer{}.
%% @doc Send a join message to a connection-handler, returning the new
%%      corresponding active entry. Should maybe add some wierd error-handling here.
%%      It isn't specified what is suppose to happen if the join fails. Retry maybe?
%%      Maybe an option to specify multiple contactnode and try them in order?
join(ContactNode, Myself) ->
    {ok, Pid, MRef} = connect_sup:start_connection(ContactNode, Myself),
    connect:send_message(Pid, {join, Myself}),
    new_peer(ContactNode, Pid, MRef).

-spec kill(Entry :: #peer{}) -> ok.
%% @doc Send a kill message to a connection-handler
kill(#peer{pid=Pid, mref=MRef}) ->
    demonitor(MRef, [flush]),
    connect:kill(Pid).

-spec forward_join(Entry :: #peer{}, NewNode :: #node{},
                   TTL :: non_neg_integer()) -> ok.                           
%% @doc Send a forward-join message to a connection-handler
forward_join(#peer{pid=Pid}, NewNode, TTL) ->
    connect:send_message(Pid, {forward_join, NewNode, TTL}).

-spec disconnect(Peer :: #peer{}) -> true.
%% @doc Send a disconnect message to a connection-handler
disconnect(#peer{pid=Pid, mref=MRef}) ->
    connect:send_message(Pid, disconnect),
    demonitor(MRef, [flush]).

-spec add_me(Node :: #node{}, Myself :: #node{}) -> #peer{} | {error, term()}.
%% @doc Response to a forward_join propagation. Tells the node who
%%      initiated the join to setup a connection
add_me(Node, Myself) ->
    case connect_sup:start_connection(Node, Myself) of
        {ok, Pid, MRef} ->
            connect:send_message(Pid, {add_me, Myself}),
            #peer{id=Node, pid=Pid, mref=MRef};
        Err ->
            Err
    end.

-spec drop_random_active(#state{}) -> #state{}.
%% @doc Drop a random node from the active view down to the passive view.
%%      Send a DISCONNECT message to the dropped node.
drop_random_active(State=#state{active_view=Active0, passive_view=Passive}) ->
    {Active, Dropped} = misc:drop_random(Active0),
    disconnect(Dropped),
    State#state{active_view=Active,
                passive_view=[Dropped#peer.id|Passive]}.

%% -------------------------
%% Options related functions
%% -------------------------

-spec get_option(Option :: atom(), Options :: list(option())) -> option().
%% @pure
%% @doc Get options, if undefined fallback to default.
get_option(Option, Options) ->
    case proplists:get_value(Option, Options) of
        undefined ->
            proplists:get_value(Option, default_options);
        Val ->
            Val
    end.

-spec this_node(Options :: list(option())) -> #node{}.
%% @pure
%% @doc Construct "this" node from the options
this_node(Options) ->
    {IP, Port} = get_option(this, Options),
    #node{ip=IP, port=Port}.

-spec default_options() -> list(option()).
%% @doc Default options for the hyparview-manager
default_options() ->
    [{this, {{127,0,0,1}, 6666}},
     {active_size, 5},
     {passive_size, 30},
     {arwl, 6},
     {prwl, 3},
     {k_active, 3},
     {k_passive, 4},
     {shuffle_period, 30000}].
