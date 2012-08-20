-module(hypar_node).

-behaviour(gen_server).

-export([start_link/1, join_cluster/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(MSG(Event, Pid), {Event=Msg, Pid}).
-define(LOG(Text), io:format("Event: ~p~nMessage: ~s~n", [Msg, Text])).

-define(ERR(Error, Text), io:format("Error: ~p~nMessage: ~s~n", [Error, Text])).

-record(state, {id,
                active_view = [],
                passive_view = [],
                shuffle_history = [],
                nreqs = [],
                opts,
                notify
               }).

%% API

start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

join_cluster(ContactNode) ->
    gen_server:cast(self(), {join_cluster, ContactNode}).

%% Messages

join(Pid, NewNode) ->
    send(Pid, {join, NewNode}).

forward_join(Pid, NewNode, TTL, Sender) ->
    send(Pid, {forward_join, NewNode, TTL, Sender}).

forward_join_reply(Pid, Sender) ->
    send(Pid, {forward_join_reply, Sender}).

disconnect(Pid, Peer) ->
    send(Pid, {disconnect, Peer}).

neighbour_request(Pid, Sender, Priority) ->
    send(Pid, {neighbour_request, Sender, Priority}).

neighbour_accept(Pid, Sender) ->
    send(Pid, {neighbour_accept, Sender}).

neighbour_decline(Pid, Sender) ->
    send(Pid, {neighbour_decline, Sender}).

shuffle_request(Pid, ExchangeList, TTL, Sender, Ref) ->
    send(Pid, {shuffle_request, ExchangeList, TTL, Sender, Ref}).

shuffle_reply(Pid, ExchangeList, Ref) ->
    send(Pid, {shuffle_reply, ExchangeList, Ref}).

%% Neighbour up/down
notify(none, _Msg) ->
    ok;
notify(Pid, Msg) ->
    gen_server:cast(Pid, Msg).

neighbour_up(Pid, From, To) ->
    notify(Pid, {neighbour_up, From, To}).

neighbour_down(Pid, From, To) ->
    notify(Pid, {neighbour_down, From, To}).

%% gen_server callbacks

init([Options]) ->
    Msg = {init, Options},
    ?LOG("Init: Initating..."),

    %% Seed the random generator!
    random:seed(now()),

    %% Initate the shuffle cycle, random start time in
    %% range from now to the period max.
    ShufflePeriod = proplists:get_value(shuffle_period, Options),
    TimeOut = random:uniform(ShufflePeriod),
    erlang:send_after(TimeOut, self(), shuffle_time),

    %% Construct state
    ThisNode = proplists:get_value(id, Options),
    Notify = proplists:get_value(notify, Options),
    State = #state{id = ThisNode, opts = Options, notify=Notify},
    {ok, State}.

%% Join a cluster via a given contact-node
handle_cast({join_cluster, ContactNode}=Msg, State0) ->
    ?LOG("Join-cluster: Trying to join cluster."),

    ThisNode = State0#state.id,

    case connect_sup:start_connection(ContactNode, ThisNode) of
        %% Connection ok, send a join message to the contact node
        {ok, Pid, MRef} ->
            join(Pid, ThisNode),
            State = add_node_active(ContactNode, Pid, MRef, State0),
            {noreply, State};
        Err ->
            ?ERR(Err, "Join-cluster: Failed"),
            {noreply, State0}
    end;

%% Add newly joined node to active view, propagate a forward join
handle_cast(?MSG({join, NewNode}, SenderPid), State0) ->
    ?LOG("Join: Adding node and propagating forward-join."),

    %% Monitor the new process and add it to active view
    MRef = erlang:monitor(process, SenderPid),
    State = add_node_active(NewNode, SenderPid, MRef, State0),

    #state{id=ThisNode, active_view=Active, opts=Options} = State,
    ARWL = proplists:get_value(arwl, Options),

    %% Propagate a forward join to all active peers
    ForwardNodes = [ Pid || {Node, Pid, _} <- Active, Node =/= NewNode],
    lists:foreach(fun(Pid) ->
                          forward_join(Pid, NewNode, ARWL, ThisNode)
                  end,
                  ForwardNodes),
    {noreply, State};

%% Respond to a forward_join, add to active or propagate and maybe add to
%% passive view.
handle_cast(?MSG({forward_join, NewNode, TTL, Sender}, _), State0) ->
    #state{id=ThisNode, active_view=Active, opts=Options} = State0,
    PRWL = proplists:get_value(prwl, Options),

    %% Add to passive view if TTL is equal to PRWL
    State1 =
        if TTL =:= PRWL ->
                ?LOG("Forward-join: Adding to passive view."),
                add_node_passive(NewNode, State0);
           true         -> State0
        end,

    if TTL =:= 0 orelse length(Active) =:= 1 ->
            ?LOG("Forward-join: Replying."),

            %% Add to active view, send a reply to the forward_join to let the
            %% other node know
            case connect_sup:start_connection(NewNode, ThisNode) of
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
                    ?ERR(Err, "Failed to reply to a forward join propagation."),
                    {noreply, State0}
            end;
       true ->
            ?LOG("Forward-join: Propagating."),

            %% Propagate the forward join using a random walk
            Peers = lists:keydelete(Sender, 1, Active),
            {_Node, Pid, _MRef} = misc:random_elem(Peers),
            forward_join(Pid, NewNode, TTL-1, ThisNode),
            {noreply, State1}
    end;

%% Accept a connection from the join procedure
handle_cast(?MSG({forward_join_reply, Sender}, SenderPid), State0) ->
    ?LOG("Forward-join: Accepting."),

    MRef = erlang:monitor(process, SenderPid),
    State = add_node_active(Sender, SenderPid, MRef, State0),
    {noreply, State};

%% Disconnect an open active connection, add disconnecting node to passive view
handle_cast(?MSG({disconnect, Sender}, SenderPid), State0) ->
    ?LOG("Disconnect: Disconnecting."),

    #state{id=ThisNode, notify=Notify, active_view=Active0} = State0,
    {Sender, SenderPid, MRef} = lists:keyfind(Sender, 1, Active0),

    %% Disconnect the peer, kill the connection and add node to passive view
    Active = lists:keydelete(Sender, 1, Active0),
    erlang:demonitor(MRef, [flush]),
    connect_sup:kill(SenderPid),
    neighbour_down(Notify, ThisNode, Sender),
    State = add_node_passive(Sender, State0),
    {noreply, State#state{active_view=Active}};

%% Respond to a neighbour request, either accept or decline based on priority
%% and current active view
handle_cast(?MSG({neighbour_request, Sender, Priority}, SenderPid), State0) ->
    #state{id=ThisNode, active_view=Active, opts=Options} = State0,
    ActiveSize = proplists:get_value(active_size, Options),

    case Priority of
        %% High priority neighbour request thus the node needs to accept the
        %% request what ever the current active view is
        high ->
            ?LOG("Neighbour-request: High priority, accepting."),

            MRef = erlang:monitor(process, SenderPid),
            State = add_node_active(Sender, SenderPid, MRef, State0),
            neighbour_accept(SenderPid, ThisNode),
            {noreply, State};
        %% Low priority request, only accept if we have space in the
        %% nodes active view
        low ->
            if length(Active) < ActiveSize ->
                    ?LOG("Neighbour-request: Low priority, accepting."),

                    MRef = erlang:monitor(process, SenderPid),
                    State = add_node_active(Sender, SenderPid, MRef, State0),
                    neighbour_accept(SenderPid, ThisNode),
                    {noreply, State};
               true ->
                    ?LOG("Neighbour-request: Low priority, declining."),

                    neighbour_decline(SenderPid, ThisNode),
                    {noreply, State0}
            end
    end;

%% A neighbour request has been accepted, add to active view
handle_cast(?MSG({neighbour_accept, Sender}, SenderPid), State0) ->
    ?LOG("Neighbour-accept: Accepting."),
    NRequests0 = State0#state.nreqs,

    %% Remove the request from the request history
    {Sender, SenderPid, MRef} = lists:keyfind(Sender, 1, NRequests0),
    NRequests = lists:keydelete(Sender, 1, NRequests0),
    State = add_node_active(Sender, SenderPid, MRef, State0),
    {noreply, State#state{nreqs=NRequests}};

%% A neighbour request has been declined, find a new one
handle_cast(?MSG({neighbour_decline, Sender}, SenderPid), State0) ->
    ?LOG("Neighbour-decline: Declining."),
    NRequests0 = State0#state.nreqs,

    {Sender, SenderPid, MRef} = lists:keyfind(Sender, 1, NRequests0),
    erlang:demonitor(MRef, [flush]),
    connect_sup:kill(SenderPid),

    NRequests = lists:keydelete(Sender, 1, NRequests0),
    State = find_new_active(State0#state{nreqs=NRequests}),
    {noreply, State};

%% Timer message for periodic shuffle. Send of a shuffle request to a random
%% peer in the active view.
handle_cast(shuffle_time, State0) ->
    #state{id=ThisNode, active_view=Active,
           opts=Options, shuffle_history=ShuffleHist0} = State0,
    XList = create_exchange_list(State0),
    {Node, Pid, _MRef} = misc:random_elem(Active),
    ARWL = proplists:get_value(arwl, Options),
    Ref = erlang:make_ref(),

    shuffle_request(Pid, XList, ARWL, ThisNode, Ref),

    ShufflePeriod = proplists:get_value(shuffle_period, Options),
    ShuffleBuffer = proplists:get_value(shuffle_buffer, Options),
    erlang:send_after(ShufflePeriod, self(), shuffle_time),

    %% Cleanup shuffle history and add new shuffle
    Now = erlang:now(),
    FilterFun = fun({_,_,Time}) ->
                        timer:now_diff(Now, Time) < ShufflePeriod*ShuffleBuffer
                end,
    ShuffleHist = [{Ref, XList, Now} | lists:filter(FilterFun, ShuffleHist0)],

    Msg = {shuffle_time, XList, ARWL, Node, Now, Ref},
    ?LOG("Shuffle: Initiating shuffle routine."),

    State = State0#state{shuffle_history=ShuffleHist},
    {noreply, State};
%% Respond to a shuffle request, either propagate it or accept it via a
%% temporary connection to the source of the request. If the node accept then
%% it add the shuffle list into it's passive view and responds with with
%% a shuffle reply(including parts of it's own passive view).
handle_cast(?MSG({shuffle_request, XList, TTL, Sender, Ref}, _), State0) ->
    NextTTL = TTL - 1,
    #state{id=ThisNode, active_view=Active, passive_view=Passive} = State0,

    case NextTTL > 0 andalso length(Active) > 1 of
        %% Propagate the random walk
        true ->
            ?LOG("Shuffle-request: Propagating random walk."),

            Peers = lists:keydelete(Sender, 1, Active),
            {_Node, Pid, _MRef} = misc:random_elem(Peers),
            shuffle_request(Pid, XList, NextTTL, Sender, Ref),
            {noreply, State0};
        %% Accept the shuffle request, add to passive view and reply
        false ->
            ?LOG("Shuffle-request: Accepting shuffle request."),

            case connect_sup:start_temp_connection(ThisNode, Sender) of
                {ok, Pid} ->
                    ReplyLength = length(XList),
                    ReplyList = misc:take_n_random(ReplyLength, Passive),
                    shuffle_reply(Pid, ReplyList, Ref),
                    State = add_exchange_list(State0, XList, ReplyList),
                    {noreply, State};
                Err ->
                    ?ERR(Err, "Shuffle-request: Error, temporary connection."),
                    {noreply, State0}
            end
    end;
%% Accept a shuffle reply, add the reply list into the passive view and
%% close the temporary connection.
handle_cast(?MSG({shuffle_reply, ReplyList, Ref}, SenderPid), State0) ->
    ?LOG("Shuffle-reply: Including shuffle data into passive view."),
    #state{shuffle_history=ShuffleHist0} = State0,

    %% Kill the temporary connection
    connect_sup:kill(SenderPid),

    case lists:keyfind(Ref, 1, ShuffleHist0) of
        %% Clean up the shuffle history, add the reply list to passive view
        {Ref, ShuffleList, _Time} ->
            ShuffleHist = lists:keydelete(1, Ref, ShuffleHist0),
            State1 = State0#state{shuffle_history=ShuffleHist},
            State = add_exchange_list(State1, ReplyList, ShuffleList),
            {noreply, State};
        %% Stale data or something buggy
        false ->
            ?ERR({oldmsg, Msg},"Old shuffle-message, not present in state"),
            {noreply, State0}
    end.

%% Handle failing connections. This may be either active connections or
%% open neighbour requests. If an active connection has failed, try
%% and find a new one. Do the same if a potential neighbour failed.
handle_info({'DOWN', MRef, process, Pid, Reason}, State0) ->
    #state{id=ThisNode, notify=Notify,
           active_view=Active0, nreqs=NRequests0} = State0,

    case lists:keyfind(Pid, 2, Active0) of
        {Node, Pid, MRef} ->
            Active = lists:keydelete(Pid, 2, Active0),
            neighbour_down(Notify, ThisNode, Node),

            Msg = {link_down, ThisNode, Node, Reason},
            ?LOG("Link down: Active link down."),

            State = find_new_active(State0#state{active_view=Active});
        false ->
            case lists:keyfind(Pid, 2, NRequests0) of
                {Node, Pid, Node} ->
                    NRequests = lists:keydelete(Pid, 2, NRequests0),
                    neighbour_down(Notify, ThisNode, Node),

                    Msg = {link_down, ThisNode, Node, Reason},
                    ?LOG("Link down: Potential neighbour link down."),

                    State = find_new_active(State0#state{nreqs=NRequests});
                false ->
                    Msg = {temporary_link_down, ThisNode, Pid, Reason},
                    ?LOG("Link down: Temporary shuffle link down."),
                    State = State0
            end
    end,
    {noreply, State}.

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
                          connect_sup:kill(Pid)
                  end, State#state.active_view),
    ok.

%% Internal
send(Pid, Msg) ->
    connect:send_control(Pid, Msg).

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
            neighbour_up(Notify, ThisNode, Node),
            Entry = {Node, Pid, MRef},
            State#state{active_view=[Entry|State#state.active_view]};
        false ->
            State0
    end.

%% @doc Add a node to the passive view, removing random entries if needed
add_node_passive(Node, State) ->
    #state{id=ThisNode, opts=Options,
           active_view=Active, passive_view=Passive0} = State,

    AddCondition = lists:all([Node =/= ThisNode,
                              not lists:keymember(Node, 1, Active),
                              not lists:member(Node, Passive0)]),
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
    KActive  = proplists:get_value(kactive, Options),
    KPassive = proplists:get_value(kpassive, Options),

    RandomActive  = misc:take_n_random(KActive, Active),
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
                        lists:all([Node =/= ThisNode,
                                   not lists:keymember(Node, 1, Active),
                                   not lists:member(Node, Passive0)])
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

    {PossiblePeer, Passive} = find_neighbour(Priority, Passive0, ThisNode),
    State#state{passive_view=Passive, nreqs=[PossiblePeer|NReqs]}.

find_neighbour(Priority, Passive, ThisNode) ->
    find_neighbour(Priority, Passive, ThisNode, []).

find_neighbour(Priority, Passive0, ThisNode, Tried) ->
    {Node, Passive} = misc:drop_random(Passive0),
    case connect_sup:start_connection(Node, ThisNode) of
        {ok, Pid, MRef} ->
            neighbour_request(Pid, ThisNode, Priority),
            {{Node, Pid, MRef}, Passive ++ Tried};
        _Err ->
            find_neighbour(Priority, Passive, ThisNode, Tried)
    end.

%% @pure
%% @doc Find the priority of a new neighbour. If no active entries exist
%%      the priority is high, otherwise low.
get_priority([], []) -> high;
get_priority(_, _)  -> low.
