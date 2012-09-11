-module(hypar_node).

-behaviour(gen_server).

%% Node api
-export([start_link/1, control_msg/1, join_cluster/1, debug_state/0,
         get_peers/0, get_passive_peers/0, get_all_peers/0]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {id,
                active_view = [],
                passive_view = [],
                shuffle_history = [],
                nreqs = [],
                opts,
                notify
               }).

%% API

%% @doc Start the node
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

%% @doc Join a cluster via ContactNode
join_cluster(ContactNode) ->
    gen_server:cast(?MODULE, {join_cluster, ContactNode}).

%% @doc Get all the current active peers
get_peers() ->
    gen_server:call(?MODULE, get_peers).

%% @doc Get all the current passive peers
get_passive_peers() ->
    gen_server:call(?MODULE, get_passive_peers).

%% @doc Get all the current peers
get_all_peers() ->
    gen_server:call(?MODULE, get_all_peers).

%% @doc Send a control message (i.e node -> node)
control_msg(Msg) ->
    gen_server:cast(?MODULE, {Msg, self()}).

%% @doc Return the state
debug_state() ->
    gen_server:call(?MODULE, debug_state).

%% Messages sent between nodes

%% @doc Send a join message
join(Pid, NewNode) ->
    connect:send_control(Pid, {join, NewNode}).

%% @doc Send a forward-join message
forward_join(Pid, NewNode, TTL, Sender) ->
    connect:send_control(Pid, {forward_join, NewNode, TTL, Sender}).

%% @doc Send a reply to a forward-join message
forward_join_reply(Pid, Sender) ->
    connect:send_control(Pid, {forward_join_reply, Sender}).

%% @doc Send a disconnect message
disconnect(Pid, Peer) ->
    connect:send_control(Pid, {disconnect, Peer}).

%% @doc Send a neighbour-request message
neighbour_request(Pid, Sender, Priority) ->
    connect:send_control(Pid, {neighbour_request, Sender, Priority}).

%% @doc Send a neighbour-accept message
neighbour_accept(Pid, Sender) ->
    connect:send_control(Pid, {neighbour_accept, Sender}).

%% @doc Send a neighbour-decline message
neighbour_decline(Pid, Sender) ->
    connect:send_control(Pid, {neighbour_decline, Sender}).

%% @doc Send a shuffle-request message
shuffle_request(Pid, XList, TTL, Sender, Ref) ->
    connect:send_control(Pid, {shuffle_request, XList, TTL, Sender, Ref}).

%% @doc Send a shuffle-reply message
shuffle_reply(Pid, ExchangeList, Ref) ->
    connect:send_control(Pid, {shuffle_reply, ExchangeList, Ref}).

%% Neighbour up/down
notify(Pid, Msg) ->
    gen_server:cast(Pid, Msg).

neighbour_up(Pid, From, To, Conn) ->
    lager:info("ACTIVE-VIEW: NEW LINK ~p", [To]),
    notify(Pid, {neighbour_up, From, To, Conn}).

neighbour_down(Pid, From, To) ->
    lager:info("ACTIVE-VIEW: LINK DOWN ~p", [To]),
    notify(Pid, {neighbour_down, From, To}).

%% gen_server callbacks

init(Options) ->
    %% Seed the random generator!
    random:seed(now()),

    %% Find this nodes id
    ThisNode = proplists:get_value(id, Options),
    lager:info([{options, Options}], "INITIALIZING NODE: ~p", [ThisNode]),

    %% Start the tcp-listeners
    {IP, Port} = ThisNode,
    Recipient = proplists:get_value(recipient, Options),
    ListenOpts = [{port,Port},{ip,IP},{keepalive, true}],
    {ok, _} = ranch:start_listener(tcp_conn, 100,
                                   ranch_tcp, ListenOpts,
                                   connect, [Recipient]),
    
    %% Initate the shuffle cycle if shuffle_period is defined
    %% Otherwise skip it, might be good in a test setting
    ShufflePeriod = proplists:get_value(shuffle_period, Options),
    if ShufflePeriod =/= undefined ->
            erlang:send_after(ShufflePeriod, self(), shuffle_time)
    end,

    %% Construct state
    Notify = proplists:get_value(notify, Options),
    State = #state{id = ThisNode, opts = Options, notify=Notify},
    {ok, State}.

%% Join a cluster via a given contact-node
handle_cast({join_cluster, ContactNode}, State0) ->
    lager:debug("JOIN_CLUSTER via ~p", [ContactNode]),

    ThisNode = State0#state.id,

    case connect:new_connection(ContactNode, ThisNode) of

        %% Connection ok, send a join message to the contact node
        {ok, Pid, MRef} ->
            join(Pid, ThisNode),
            State = add_node_active(ContactNode, Pid, MRef, State0),
            {noreply, State};
        
        %% Error when connecting
        Err ->
            lager:error("FAIL: JOIN CLUSTER via ~p WITH ~p",
                        [ContactNode, Err]),
            {noreply, State0}
    end;

%% Add newly joined node to active view, propagate a forward join
handle_cast({{join, NewNode}, SenderPid}, State0) ->
    lager:debug("RECEIVED: JOIN ~p", [NewNode]),
    
    %% Monitor the new process and add it to active view
    MRef = erlang:monitor(process, SenderPid),
    State = add_node_active(NewNode, SenderPid, MRef, State0),
    
    #state{id=ThisNode, active_view=Active, opts=Options} = State,
    ARWL = proplists:get_value(arwl, Options),
    
    %% Propagate a forward join to all active peers
    ForwardFun = fun(Pid) -> forward_join(Pid, NewNode, ARWL, ThisNode) end,
    ForwardNodes = [ Pid || {Node, Pid, _} <- Active, Node =/= NewNode],
    lists:foreach(ForwardFun, ForwardNodes),

    lager:debug("PROPAGATING FORWARD-JOIN to ~p", [ForwardNodes]),

    {noreply, State};

%% Respond to a forward_join, add to active or propagate and maybe add to
%% passive view.
handle_cast({{forward_join, NewNode, TTL, Sender}, _}, State0) ->
    lager:debug("RECEIVED: FORWARD-JOIN ~p ~p ~p", [Sender, NewNode, TTL]),

    #state{id=ThisNode, active_view=Active, opts=Options} = State0,
    PRWL = proplists:get_value(prwl, Options),

    %% Add to passive view if TTL is equal to PRWL
    State1 =
        if TTL =:= PRWL -> add_node_passive(NewNode, State0);
           true         -> State0
        end,

    if TTL =:= 0 orelse length(Active) =:= 1 ->
            lager:debug("FORWARD-JOIN ACCEPTED"),

            %% Add to active view, send a reply to the forward_join to let the
            %% other node know
            case connect:new_connection(NewNode, ThisNode) of
                %% Connection OK!
                {ok, Pid, MRef} ->
                    State = add_node_active(NewNode, Pid, MRef, State1),
                    forward_join_reply(Pid, ThisNode),
                    {noreply, State};
                %% Error in connection setup, log it and ignore the new node
                %% NOTE: Maybe use this as an opportunity to fill out the active
                %%       view abit if it's not active size and there are no
                %%       pending neighbour requests out there.
                Err ->
                    lager:error("FAIL: CONNECTION TO ~p WITH ~p",
                                [NewNode, Err]),
                    {noreply, State0}
            end;
       true ->            
            %% Propagate the forward join using a random walk
            Peers = lists:keydelete(Sender, 1, Active),
            {Node, Pid, _MRef} = misc:random_elem(Peers),
            
            lager:debug("FORWARD-JOIN: PROPAGATING TO ~p", [Node]),

            forward_join(Pid, NewNode, TTL-1, ThisNode),
            {noreply, State1}
    end;

%% Accept a connection from the join procedure
handle_cast({{forward_join_reply, Sender}, SenderPid}, State0) ->
    lager:debug("RECEIVED: FORWARD-JOIN-REPLY ~p", [Sender]),

    MRef = erlang:monitor(process, SenderPid),
    State = add_node_active(Sender, SenderPid, MRef, State0),
    {noreply, State};

%% Disconnect an open active connection, add disconnecting node to passive view
handle_cast({{disconnect, Sender}, SenderPid}, State0) ->
    lager:debug("RECEIVED: DISCONNECT ~p", [Sender]),

    #state{id=ThisNode, notify=Notify, active_view=Active0} = State0,
    {Sender, SenderPid, MRef} = lists:keyfind(Sender, 1, Active0),
    
    %% Disconnect the peer, kill the connection and add node to passive view
    Active = lists:keydelete(Sender, 1, Active0),
    erlang:demonitor(MRef, [flush]),
    connect:kill(SenderPid),
    neighbour_down(Notify, ThisNode, Sender),
    State = add_node_passive(Sender, State0),
    {noreply, State#state{active_view=Active}};

%% Respond to a neighbour request, either accept or decline based on priority
%% and current active view
handle_cast({{neighbour_request, Sender, Priority}, SenderPid}, State0) ->
    lager:debug("RECEIVED: NEIGHBOUR-REQUEST ~p ~p", [Sender, Priority]),
    
    #state{id=ThisNode, active_view=Active, opts=Options} = State0,
    ActiveSize = proplists:get_value(active_size, Options),

    case Priority of
        %% High priority neighbour request thus the node needs to accept the
        %% request what ever the current active view is
        high ->
            lager:info("NEIGHBOUR-REQUEST: ACCEPTED HIGH PRIORITY REQUEST from ~p",
                       [Sender]),

            MRef = erlang:monitor(process, SenderPid),
            State = add_node_active(Sender, SenderPid, MRef, State0),
            neighbour_accept(SenderPid, ThisNode),
            {noreply, State};
        %% Low priority request, only accept if we have space in the
        %% nodes active view
        low ->
            if
                %% There is space in the active view
                length(Active) < ActiveSize ->
                    lager:debug("NEIGHBOUR-REQUEST: ACCEPTED LOW PRIORITY REQUEST from ~p",
                                [Sender]),
                    MRef = erlang:monitor(process, SenderPid),
                    State = add_node_active(Sender, SenderPid, MRef, State0),
                    neighbour_accept(SenderPid, ThisNode),
                    {noreply, State};
               %% Active view is full
               true ->
                    lager:debug("NEIGHBOUR-REQUEST: DECLINED LOW PRIORITY REQUEST from ~p",
                                [Sender]),

                    neighbour_decline(SenderPid, ThisNode),
                    {noreply, State0}
            end
    end;

%% A neighbour request has been accepted, add to active view
handle_cast({{neighbour_accept, Sender}, SenderPid}, State0) ->
    lager:debug("RECEIVED: NEIGHBOUR-ACCEPT ~p", [Sender]),
    NRequests0 = State0#state.nreqs,

    %% Remove the request from the request history
    {Sender, SenderPid, MRef} = lists:keyfind(Sender, 1, NRequests0),
    NRequests = lists:keydelete(Sender, 1, NRequests0),
    State = add_node_active(Sender, SenderPid, MRef, State0),
    {noreply, State#state{nreqs=NRequests}};

%% A neighbour request has been declined, find a new one
handle_cast({{neighbour_decline, Sender}, SenderPid}, State0) ->
    lager:debug("RECEIVED: NEIGHBOUR-DECLINE ~p", [Sender]),

    NRequests0 = State0#state.nreqs,

    {Sender, SenderPid, MRef} = lists:keyfind(Sender, 1, NRequests0),
    erlang:demonitor(MRef, [flush]),
    connect:kill(SenderPid),

    NRequests = lists:keydelete(Sender, 1, NRequests0),
    State = find_new_active(State0#state{nreqs=NRequests}),
    {noreply, State};

%% Respond to a shuffle request, either propagate it or accept it via a
%% temporary connection to the source of the request. If the node accept then
%% it add the shuffle list into it's passive view and responds with with
%% a shuffle reply(including parts of it's own passive view).
handle_cast({{shuffle_request, XList, TTL, Sender, Ref}, _}, State0) ->
    NextTTL = TTL - 1,
    lager:debug("RECEIVED: SHUFFLE-REQUEST ~p ~p ~p ~p",
                [XList, NextTTL, Sender, Ref]),

    #state{id=ThisNode, active_view=Active, passive_view=Passive} = State0,

    case NextTTL > 0 andalso length(Active) > 1 of
        %% Propagate the random walk
        true ->            
            Peers = lists:keydelete(Sender, 1, Active),
            {Node, Pid, _MRef} = misc:random_elem(Peers),

            lager:debug("SHUFFLE-REQUEST: PROPAGATING ~p to ~p", [Ref, Node]),
            shuffle_request(Pid, XList, NextTTL, Sender, Ref),
            {noreply, State0};
        %% Accept the shuffle request, add to passive view and reply
        false ->
            lager:debug("SHUFFLE-REQUEST: ACCEPTING ~p", [Ref]),

            %% TempPort = proplists:get_value(temp_port, Options),
            %% TempNode = {IP, TempPort},
            case connect:new_temp_connection(Sender, ThisNode) of
                {ok, Pid} ->
                    ReplyLength = length(XList),
                    ReplyList = misc:take_n_random(ReplyLength, Passive),
                    shuffle_reply(Pid, ReplyList, Ref),
                    State = add_exchange_list(State0, XList, ReplyList),
                    {noreply, State};
                Err ->
                    lager:error("FAIL: TEMPORARY CONNECTION from ~p to ~p WITH ~p",
                                [ThisNode, Sender, Err]),
                    {noreply, State0}
            end
    end;
%% Accept a shuffle reply, add the reply list into the passive view and
%% close the temporary connection.
handle_cast({{shuffle_reply, ReplyList, Ref}, SenderPid}, State0) ->
    lager:debug("RECEIVED: SHUFFLE-REPLY ~p ~p", [ReplyList, Ref]),

    ShuffleHist0 = State0#state.shuffle_history,

    %% Kill the temporary connection
    connect:kill(SenderPid),

    case lists:keyfind(Ref, 1, ShuffleHist0) of
        %% Clean up the shuffle history, add the reply list to passive view
        {Ref, ShuffleList, _Time} ->
            ShuffleHist = lists:keydelete(Ref, 1, ShuffleHist0),
            State1 = State0#state{shuffle_history=ShuffleHist},
            State = add_exchange_list(State1, ReplyList, ShuffleList),
            {noreply, State};
        %% Stale data or something buggy
        false ->
            lager:warning("SHUFFLE-REPLY: STALE SHUFFLE ~p ~p",
                          [ReplyList, Ref]),
            {noreply, State0}
    end.

%% Handle failing connections. This may be either active connections or
%% open neighbour requests. If an active connection has failed, try
%% and find a new one. Do the same if a potential neighbour failed.
handle_info({'DOWN', MRef, process, Pid, Reason}, State0) ->
    lager:error("LINK-DOWN: A LINK HAS GONE DOWN WITH ~p", [{error, Reason}]),

    #state{id=ThisNode, notify=Notify,
           active_view=Active0, nreqs=NRequests0} = State0,
    State = 
        case lists:keyfind(Pid, 2, Active0) of
            {Node, Pid, MRef} ->
                
                Active = lists:keydelete(Pid, 2, Active0),
                neighbour_down(Notify, ThisNode, Node),
                
                find_new_active(State0#state{active_view=Active});
            false ->
                case lists:keyfind(Pid, 2, NRequests0) of
                    {Node, Pid, Node} ->
                        NRequests = lists:keydelete(Pid, 2, NRequests0),
                        
                        lager:error("LINK-DOWN: LINK TO POTENTIAL NEIGHBOUR ~p DOWN",
                                    [Node]),
                        
                        find_new_active(State0#state{nreqs=NRequests});
                    false ->
                        lager:error("LINK-DOWN: TEMPORARY LINK DOWN"),
                        State0
                end
        end,
    {noreply, State};

%% Timer message for periodic shuffle. Send of a shuffle request to a random
%% peer in the active view. Ignore if we don't have any active connections. 
handle_info(shuffle_time, State0=#state{active_view=[]}) ->
    lager:debug("SHUFFLE-TIME: NO ACTIVE CONNECTIONS"),

    Options = State0#state.opts,

    %% Reset shuffle timer
    start_shuffle_timer(Options),
    
    %% Cleanup shuffle history
    State = clean_shuffle_history(State0),
    
    {noreply, State};
    
handle_info(shuffle_time, State0) ->
    #state{id=ThisNode, active_view=Active, opts=Options} = State0,

    XList = create_exchange_list(State0),
    {Node, Pid, _MRef} = misc:random_elem(Active),
    ARWL = proplists:get_value(arwl, Options),
    Ref = erlang:make_ref(),
    Now = erlang:now(),

    New = {Ref, XList, Now},

    lager:debug("SHUFFLE-TIME: SENDING SHUFFLE-REQUEST TO ~p", [Node]),
    shuffle_request(Pid, XList, ARWL, ThisNode, Ref),

    start_shuffle_timer(Options),

    %% Cleanup shuffle history and add new shuffle
    State1 = clean_shuffle_history(State0),
    State = State1#state{shuffle_history=[New|State1#state.shuffle_history]},
    {noreply, State}.

%% Debug
handle_call(debug_state, _, State) ->
    {reply, State, State};
%% Return all active peers
handle_call(get_peers, _From, State) ->
    Peers = [ {Node, Pid} || {Node, Pid, _MRef} <- State#state.active_view],
    {reply, Peers, State};

%% Return all passive peers
handle_call(get_passive_peers, _From, State) ->
    {reply, State#state.passive_view, State};

%% Return all peers
handle_call(get_all_peers, _From, State) ->
    #state{active_view=Active, passive_view=Passive} = State,
    {reply, {Active, Passive}, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, State) ->
    lists:foreach(fun({_Node, Pid, MRef}) ->
                          erlang:demonitor(MRef),
                          connect:kill(Pid)
                  end, State#state.active_view),
    ok.

%% Internal

%% @doc Clean-up old shuffle entries
clean_shuffle_history(State) ->
    #state{opts=Options, shuffle_history=ShuffleHist} = State,
    Now = erlang:now(),
    ShufflePeriod = proplists:get_value(shuffle_period, Options),
    ShuffleBuffer = proplists:get_value(shuffle_buffer, Options),
    Threshold = ShufflePeriod*ShuffleBuffer,

    FilterFun = fun({_,_,Time}) -> timer:now_diff(Now, Time) < Threshold end,
    State#state{shuffle_history=lists:filter(FilterFun, ShuffleHist)}.
           
%% @doc Start the shuffle timer
start_shuffle_timer(Options) ->
    ShufflePeriod = proplists:get_value(shuffle_period, Options),
    erlang:send_after(ShufflePeriod, self(), shuffle_time).

%% @doc Add a node to an active view, removing a node if necessary.
%%      The new state is returned. If a node has to be dropped, then
%%      it is informed via a DISCONNECT message.
add_node_active(Node, Pid, MRef, State0) ->
    #state{id=ThisNode, notify=Notify,
           active_view=Active0, opts=Options} = State0,

    case Node =/= ThisNode andalso not lists:keymember(Node, 1, Active0) of
        true ->
            ActiveSize = proplists:get_value(active_size, Options),
            State =
                case length(Active0) >= ActiveSize of
                    true  -> drop_random_active(State0);
                    false -> State0
                end,
            %% Notify link change
            neighbour_up(Notify, ThisNode, Node, Pid),
            Entry = {Node, Pid, MRef},
            State#state{active_view=[Entry|State#state.active_view]};
        false ->
            State0
    end.

%% @doc Add a node to the passive view, removing random entries if needed
add_node_passive(Node, State) ->
    #state{id=ThisNode, opts=Options,
           active_view=Active, passive_view=Passive0} = State,

    AddCondition =
        Node =/= ThisNode andalso
        not lists:keymember(Node, 1, Active) andalso
        not lists:member(Node, Passive0),
    if AddCondition ->
            PassiveSize = proplists:get_value(passive_size, Options),
            N = length(Passive0),
            if N >= PassiveSize ->
                    Passive = misc:drop_n_random(Passive0, N-PassiveSize+1);
               true ->
                    Passive = Passive0
            end,
            State#state{passive_view=Passive};
       true ->
            State
    end.

%% @doc Drop a random node from the active view down to the passive view.
%%      Send a DISCONNECT message to the dropped node.
drop_random_active(State) ->
    #state{id=ThisNode, notify=Notify,
           active_view=Active0, passive_view=Passive} = State,
    {Dropped, Active} = misc:drop_random(Active0),
    {Node, Pid, MRef} = Dropped,

    %% Demonitor the process and send a disconnect
    erlang:demonitor(MRef),
    disconnect(Pid, ThisNode),
    neighbour_down(Notify, ThisNode, Node),
    State#state{active_view=Active, passive_view=[Node|Passive]}.

%% @doc Create the exchange list used in a shuffle.
create_exchange_list(State) ->
    #state{active_view=Active, passive_view=Passive,
           id=ThisNode, opts=Options} = State,
    KActive  = proplists:get_value(k_active, Options),
    KPassive = proplists:get_value(k_passive, Options),

    ActiveIDs = lists:map(fun({X,_,_}) -> X end, Active),

    RandomActive  = misc:take_n_random(KActive, ActiveIDs),
    RandomPassive = misc:take_n_random(KPassive, Passive),
    [ThisNode | (RandomActive ++ RandomPassive)].

%% @doc Takes the exchange-list and adds it into the state. Removes nodes
%%      that are already in active/passive view from the list. If the passive
%%      view are full, start by dropping elements from ReplyList then random
%%      elements.
add_exchange_list(State, ExchangeList0, ReplyList) ->
    #state{active_view=Active, passive_view=Passive0,
           id=ThisNode, opts=Options} = State,
    PassiveSize = proplists:get_value(passive_size, Options),

    FilterFun = fun(Node) ->
                        Node =/= ThisNode andalso
                            not lists:keymember(Node, 1, Active) andalso
                            not lists:member(Node, Passive0)
                end,
    ExchangeList = lists:filter(FilterFun, ExchangeList0),

    SlotsNeeded = length(ExchangeList) - PassiveSize + length(Passive0),
    Passive = free_slots(SlotsNeeded, Passive0, ReplyList),

    State#state{passive_view=ExchangeList ++ Passive}.

%% @doc Free up slots in the List, start by removing elements
%%      from the RemoveFirst, then remove at random.
free_slots(I, List, _RemoveFirst) when I =< 0 ->
    List;
free_slots(I, List, []) ->
    misc:drop_n_random(I, List);
free_slots(I, List, [Remove|RemoveFirst]) ->
    case lists:member(Remove, List) of
        true  -> free_slots(I-1, lists:delete(Remove, List), RemoveFirst);
        false -> free_slots(I, List, RemoveFirst)
    end.

%% @doc When a node is thought to have died this function is called.
%%      It will recursively try to find a new neighbour from the passive
%%      view until it finds a good one, send that node an asynchronous
%%      neighbour request and logs the request in the state.
find_new_active(State) ->
    #state{id=ThisNode, nreqs=NReqs,
           active_view=Active, passive_view=Passive0} = State,
    Priority = get_priority(Active, NReqs),

    case find_neighbour(Priority, Passive0, ThisNode) of
        {PossiblePeer, Passive} ->
            State#state{passive_view=Passive, nreqs=[PossiblePeer|NReqs]};
        false ->
            lager:error("NEIGHBOUR: NO PASSIVE ENTRIES VALID"),
            State#state{passive_view=[]}
    end.        

find_neighbour(Priority, Passive, ThisNode) ->
    find_neighbour(Priority, Passive, ThisNode, []).

find_neighbour(_, [], _, _) ->
    false;
find_neighbour(Priority, Passive0, ThisNode, Tried) ->
    {Node, Passive} = misc:drop_random(Passive0),
    lager:info("NEIGHBOUR: TRYING NEW NEIGHBOUR ~p", [Node]),
    case connect_sup:new_connection(Node, ThisNode) of
        {ok, Pid, MRef} ->
            neighbour_request(Pid, ThisNode, Priority),
            {{Node, Pid, MRef}, Passive ++ Tried};
        Err ->
            lager:error("FAIL: TRYING NEIGHBOUR ~p WITH ~p", [Node, Err]),
            find_neighbour(Priority, Passive, ThisNode, Tried)
    end.

%% @pure
%% @doc Find the priority of a new neighbour. If no active entries exist
%%      the priority is high, otherwise low.
get_priority([], []) -> high;
get_priority(_, _)  -> low.
