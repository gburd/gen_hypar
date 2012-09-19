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
%%%-------------------------------------------------------------------
%%% @author Emil Falk <emil.falk.1988@gmail.com>
%%% @copyright (C) 2012, Emil Falk
%%% @title HyParView node logic
%%% @doc This module implements the node logic in the HyParView-protocol
%%%-------------------------------------------------------------------
-module(hypar_node).

-behaviour(gen_server).

%%%%%%%%%%%%%
%% Exports %%
%%%%%%%%%%%%%

%% Operations
-export([start_link/1, stop/0, join_cluster/1, shuffle/0]).

%% Peer related
-export([get_peers/0, get_passive_peers/0, get_pending_peers/0,
         get_all_peers/0]).

%% Incoming events
-export([join/1, forward_join/3, forward_join_reply/1,
         neighbour_request/2, neighbour_accept/1, neighbour_decline/1,
         shuffle_request/4. shuffle_reply/3]

%% Send related
-export([]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%%%%%%%%%%
%% State %%
%%%%%%%%%%%

-record(st, {id                :: id(),             %% This nodes identifier
             activev = []      :: list(#peer{}),    %% The active view
             passivev = []     :: list(id()),       %% The passive view
             pendingv = []     :: list(#peer{}),    %% The pending view (current neighbour requests)
             shufflehist = []  :: {reference(),     %% History of shuffle requests sent
                                   list(id()),
                                   timestamp()},  
             opts,             :: list(property()), %% Options
             notify,           :: pid() | atom(),   %% Notify process with link_up/link_down
             rec               :: pid() | atom()    %% Process that receives messages
            }).

%%%%%%%%%
%% API %%
%%%%%%%%%

%%%%%%%%%%%%%%%%
%% Operations %%
%%%%%%%%%%%%%%%%

-spec start_link(Options :: list(property())) -> 
                        {ok, pid()} | ignore | {error, any()}.
%% @doc Start the <b>hypar_node</b> with <em>Options</em>.
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

-spec stop() -> ok.
%% @doc Stop the <b>hypar_node</b>.
stop() ->
    gen_server:call(?MODULE, stop).

-spec join_cluster(ContactNode :: id()) -> view_change() |
                                           {error, any()}.
%% @doc Let the <b>hypar_node</b> join a cluster via <em>ContactNode</em>.
%%      The return value is the changes in the views
join_cluster(ContactNode) ->
    gen_server:call(?MODULE, {join_cluster, ContactNode}).

-spec shuffle() -> ok.
%% @doc Force the <b>hypar_node</b> to do a shuffle operation.
shuffle() ->
    ?MODULE ! initiate_shuffle,
    ok.

%%%%%%%%%%%%%%%%%%%%%
%% Peer operations %%
%%%%%%%%%%%%%%%%%%%%%

-spec get_peers() -> list(id()).
%% @doc Get all the current active peers.
get_peers() ->
    gen_server:call(?MODULE, get_peers).

-spec get_passive peers() -> list(id()).
%% @doc Get all the current passive peers.
get_passive_peers() ->
    gen_server:call(?MODULE, get_passive_peers).

-spec get_pending_peers() -> list(id()).
%% @doc Get all current pending peers
get_pending_peers() ->
    gen_server:call(?MODULE, get_pending_peers).

-spec get_all_peers() -> {list(id(), list(id()), list(id())}.
%% @doc Get all the current peers
get_all_peers() ->
    gen_server:call(?MODULE, get_all_peers).

%%%%%%%%%%%%%%%%%%%%%
%% Incoming events %%
%%%%%%%%%%%%%%%%%%%%%

-spec join(Sender :: id()) -> view_change().
%% @doc Join <em>Sender</em> to the <b>hypar_node</b>.
join(Sender) ->
    gen_server:call(?MODULE, join_msg(Sender)).

-spec forward_join(Sender :: id(), NewNode :: id(), TTL :: non_neg_integer()) ->
                          view_change() | {error, any()}.
%% @doc Forward join <em>NewNode</em> from <em>Sender</em>
%%      to the <b>hypar_node</b>.
forward_join(Sender, NewNode, TTL) ->
    gen_server:call(?MODULE, forward_join_msg(Sender, NewNode, TTL)).

-spec forward_join_reply(Sender :: id()) -> view_change().
%% @doc Forward join reply <em>Sender</em> to the <b>hypar_node</b>.
forward_join_reply(Sender) ->
    gen_server:call(?MODULE, forward_join_reply(Sender)).

-spec neighbour_request(Sender :: id(), Priority :: priority()) ->
                               view_change() | declined.
%% @doc Neighbour request from <em>Sender</em> to <b>hypar_node</b>
%%      with <em>Priority</em>.
neighbour_request(Sender, Priority) ->
    gen_server:call(?MODULE, neighbour_request_msg(Sender, Priority)).

-spec neighbour_accept(Sender :: id()) -> view_change().
%% @doc Accept a neighbour request from <em>Sender</em>
%%      to <b>hypar_node</b>.
neighbour_accept(Sender) ->
    gen_server:call(?MODULE, neighbour_accept_msg(Sender)).

-spec neighbour_decline(Sender :: id()) -> view_change() | {error, any()}.
%% @doc Decling a neighbour request from Sender to hypar_node
neighbour_decline(Sender) ->
    gen_server:call(?MODULE, neighbour_decline_msg(Sender)).

-spec shuffle_request(Sender :: id(), Requester :: id(), XList :: list(id()),
                      TTL :: non_neg_integer(), Ref :: reference()) ->
                             view_change() | {error, any()}.
%% @doc Shuffle request from <em>Sender</em> to <b>hypar_node</b>.
shuffle_request(Sender, Requester, XList, TTL, Ref) ->
    gen_server:call(?MODULE,
                    shuffle_request_msg(Sender, Requester, XList, TTL, Ref)).

-spec shuffle_reply(ReplyXList :: list(id()), Ref :: reference()) ->
                           view_change().
%% @doc Shuffle reply from <em>Sender</em> to <b>hypar_node</b>.
shuffle_reply(ReplyXList, Ref) ->
    gen_server:call(?MODULE, shuffle_reply_msg(ReplyXList, Ref)).

-spec disconnect(Sender :: id()) -> view_change().
%% @doc Disconnect <em>Sender</em> from the <b>hypar_node</b>.
disconnect(Sender) ->
    gen_server:call(?MODULE, {disconnect, Sender}).

-spec error(Sender :: id(), Reason :: any()) ->
                   view_change() | {error, any()}.
%% @doc Let the <b>hypar_node</b> know that <em>Sender</em> has failed
%%      error with <em>Reason</em>.
error(Sender, Reason) ->
    gen_server:call(?MODULE, {error, Sender, Reason}).

%%%%%%%%%%%%%%%%%%%%%
%% Outgoing events %%
%%%%%%%%%%%%%%%%%%%%%

%% @private
%% @doc Join procedure, connect to the new node and send a join messages
join(Sender, To) ->
    try_connect_send(Sender, To, normal,
                     join_msg(Sender)).

%% @private
%% @doc Send a forward-join message
forward_join(P, Sender, NewNode, TTL) ->
     send(P, forward_join_msg(Sender, NewNode, TTL).

%% @private
%% @doc Send a reply to a forward-join message
forward_join_reply(Sender, To) ->
    try_connect_send(Sender, To, normal,
                     forward_join_reply_msg(Sender)).

%% @private
%% @doc Send a neighbour-request message
neighbour_request(Sender, To, Priority) ->
    try_connect_send(Sender, To, normal,
                     neighbour_request_msg(Sender, Priority)).

%% @private
%% @doc Send a neighbour-accept message
neighbour_accept(P, Sender) ->
    send(P, neighbour_accept_msg(Sender)).

%% @private
%% @doc Send a neighbour-decline message
neighbour_decline(P, Sender) ->
    send(P, neighbour_decline_msg(Sender)).

%% @private
%% @doc Send a shuffle-request message
shuffle_request(P, Sender, Requester, XList, TTL, Ref) ->
    send(P, shuffle_request_msg(Sender, Requester, XList, TTL, Ref).

%% @private
%% @doc Send a shuffle-reply message
shuffle_reply(Sender, Requester, XList, Ref) ->
    try_connect_send(Sender, Requester, temporary,
                     shuffle_reply_msg(Sender, XList, Ref)).

%%%%%%%%%%%%%%
%% Messages %%
%%%%%%%%%%%%%%

%% @private
%% @doc A Join message from Sender
join_msg(Sender) ->
    {join, Sender}.

%% @private
%% @doc A forward_join
forward_join_msg(Sender, NewNode, TTL) ->
    {forward_join, Sender, NewNode, TTL}.

%% @private
%% @doc A forward_join_reply
forward_join_reply_msg(Sender) ->
    {forward_join_reply, Sender}.

%% @private
%% @doc A neighbour request
neighbour_request_msg(Sender, Priority) ->
    {neighbour_request, Sender, Priority}.

%% @private
%% @doc A neighbour accept
neighbour_accept_msg(Sender) ->
    {neighbour_accept, Sender}.

%% @private
%% @doc A neighbour decline
neighbour_decline_msg(Sender) ->
    {neighbour_decline, Sender}.

%% @private
%% @doc A shuffle request
shuffle_request_msg(Sender, Requester, XList, TTL, Ref) ->
    {shuffle_request, Sender, Requester, XList, TTL, Ref}.

%% @private
%% @doc A shuffle reply
shuffle_reply_msg(Sender, XList, Ref) ->
    {shuffle_reply, Sender, XList, Ref}.

%%%%%%%%%%%%
%% Notify %%
%%%%%%%%%%%%

%% @doc Notify <em>Pid</em> of a <b>link_up</b> event to node <em>To</em>.
%% @todo Support multiple types of noftifyee(gen_server, fsm etc)
neighbour_up(Pid, To) ->
    lager:info("Link up to ~p", [To]),
    gen_server:cast(Pid, {link_up, To}).

%% @doc Notify <em>Pid</em> of a <b>link_down</b> event to node <em>To</em>.
%% @todo Support multiple types of noftifyee(gen_server, fsm etc)
neighbour_down(Pid, To) ->
    lager:info("Link down to ~p", [To]),
    gen_server:cast(Pid, {neighbour_down, To}).

%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server callbacks %%
%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Initialize the hypar_node
init(Options) ->
    %% Seed the random generator!
    random:seed(now()),

    %% Find this nodes id
    ThisNode = proplists:get_value(id, Options),
    lager:info([{options, Options}], "INITIALIZING NODE: ~p", [ThisNode]),
    
    %% Initialize connection handlers
    connect:initialize(ThisNode),
    
    %% Start shuffle
    start_shuffle_timer(Options),

    %% Construct state
    Notify   = proplists:get_value(notify, Options),
    Receiver = proplists:get_value(receiver, Options),
    
    {ok, #st{id       = ThisNode,
             opts     = Options,
             notify   = Notify,
             receiver = Receiver}}.

%% Join a cluster via a given contact-node
handle_call({join_cluster, ContactNode}, _, S0#st{id=ThisNode}) ->
    case lists:keyfind(ContactNode, #peer.id, S0#st.activev) of
        undefined ->            
            case join(ThisNode, ContactNode) of
                {error, Err} ->
                    lager:error("Join cluster via ~p failed with error ~p",
                                [ContactNode, Err]),
                    {reply, {error, Err}, S0};
                P ->
                    {ViewChange, S} = add_node_active(P, S0),
                    {reply, ViewChange, S}
            end;
        P -> 
            lager:info("Attempting to join via existing peer ~p", [P]),
            {reply, {error, already_in_active_view}, S0}
    end;

%% Add newly joined node to active view, propagate a forward join
handle_call({join, Sender}, {Pid, _}, S0) ->
    P = #peer{id=Sender, pid=Pid},
    {ViewChange, S} = add_node_active(P, S0),

    %% Send forward joins
    ARWL = proplists:get_value(arwl, S#st.opts),

    ForwardFun = fun(X) -> ok = forward_join(X, S#st.id, P#peer.id, ARWL) end,
    FilterFun  = fun(X) -> X#peer.id =/= P#peer.id end,
    ForwardNodes = lists:filter(FilterFun, S#st.activev),
    
    lists:foreach(ForwardFun, ForwardNodes),

    {reply, ViewChange, S}};

%% Respond to a forward_join, add to active or propagate and maybe add to
%% passive view.
handle_call({forward_join, Sender, NewNode, TTL}, _, S0) ->
    case TTL =:= 0 orelse length(S1#st.activev) =:= 1 of 
        true ->
            %% Add to active view, send a reply to the forward_join to let the
            %% other node know
            case forward_join_reply(NewNode, ThisNode) of
                {error, Err} ->
                    lager:error("Reply to forward join from ~p failed with error ~p",
                                [NewNode, Err]),
                    {reply, {error, Err}, S0};
                P ->
                    {ViewChange, S} = add_node_active(P, S0),
                    {reply, ViewChange, S}
            end;
        false ->            
            %% Add to passive view if TTL is equal to PRWL
            PRWL = proplists:get_value(prwl, S0#st.opts),
            {ViewChange, S1} = case TTL =:= PRWL of
                                   true  -> add_node_passive(NewNode, S0);
                                   false -> {no_change, S0}
                               end,
            
            %% Propagate the forward join using a random walk
            AllButSender = lists:keydelete(Sender, #peer.id, S1#st.activev),
            P = misc:random_elem(AllButSender),
            
            ok = forward_join(P, S1#st.id, NewNode, TTL-1),
            {reply, ViewChange, S1}
    end;

%% Accept a connection from the join procedure
handle_call({forward_join_reply, Sender}, {Pid,_}, S0) ->
    P = #peer{id=Sender, pid=Pid},
    {ViewChange, S} = add_node_active(P, S0),
    
    {reply, ViewChange, S};

%% Disconnect an open active connection, add disconnecting node to passive view
handle_call({disconnect, Sender}, _, S0) ->
    P = lists:keyfind(Sender, #peer.id, S0#st.activev),
    %% Disconnect the peer, close the connection and add node to passive view
    ActiveV = lists:keydelete(P#peer.id, #peer.id, S0#st.activev),
    neighbour_down(S0#st.notify, P#peer.id),
    {ViewChange, S} = add_node_passive(P#peer.id, S0#st{activev=ActiveV}),
    {reply, ViewChange, S};

%% Respond to a neighbour request, either accept or decline based on priority
%% and current active view
handle_call({neighbour_request, Sender, Priority}, {Pid,_}, S0) ->
    P = #peer{id=Sender, pid=Pid},
    case Priority of
        %% High priority neighbour request thus the node needs to accept the
        %% request what ever the current active view is
        high ->
            lager:info("Accepted high priority neighbour request from ~p",
                       [Sender]),
            ok = neighbour_accept(P, S0#st.id),
            {ViewChange, S} = add_node_active(P, S0),
            {reply, ViewChange, S};
        %% Low priority request, only accept if we have space in the
        %% nodes active view
        low ->
            case length(S0#st.activev) < S0#st.active_size of
                true ->
                    ok = neighbour_accept(P, ThisNode),
                    {ViewChange, S} = add_node_active(P, S0),
                    {reply, ViewChange, S};
                false ->
                    lager:info("Declined neighbour request from ~p due to space",
                               [Sender]),
                    ok = neighbour_decline(P, ThisNode),
                    {reply, declined, S0}
            end
    end;

%% A neighbour request has been accepted, add to active view
handle_call({neighbour_accept, Sender},_ , S0) ->
    %% Remove the request from the request history
    P = lists:keyfind(Sender, #peer.id, S0#st.pendingv),
    PendingV = lists:keydelete(Sender, #peer.id, S0#st.pendingv),
    {ViewChange, S} = add_node_active(P, S0#st{pendingv=PendingV}),

    {reply, ViewChange, S};

%% A neighbour request has been declined, find a new one
handle_call({neighbour_decline, Sender}, _, S0) ->
    %% Remove the request
    P = lists:keyfind(Sender, #peer.id, S0#st.pendingv),
    PendingV = lists:keydelete(Sender, #peer.id, S0#st.pendingv),
    case find_new_active(S0#st{pendingv=PendingV}) of
        {no_peers, S} ->
            lager:error("No valid peers to connect to."),
            {reply, {error, no_peers}, S};
        {ViewChange, S} ->
            {reply, ViewChange, S}
    end;

%% Respond to a shuffle request, either propagate it or accept it via a
%% temporary connection to the source of the request. If the node accept then
%% it add the shuffle list into it's passive view and responds with with
%% a shuffle reply(including parts of it's own passive view).
handle_call({shuffle_request, Sender, Requester, XList, TTL, Ref}, _, S0) ->
    case TTL > 0 andalso length(S0#st.activev) > 1 of
        %% Propagate the random walk
        true ->            
            AllButSender = lists:keydelete(Sender, #peer.id, S0#st.activev),
            P = misc:random_elem(AllButSender),
            
            shuffle_request(P, S0#st.id, Requester, XList, TTL-1, Ref),
            {reply, no_change(), S0};
        %% Accept the shuffle request, add to passive view and reply
        false ->
            N = length(XList),
            ReplyXList = misc:take_n_random(N, S0#st.passivev),
            case shuffle_reply(ThisNode, Requester, ReplyXList, Ref) of
                ok ->
                    {ViewChange, S} = add_exchange_list(XList, ReplyXList, S0),
                    {reply, ViewChange, S};
                Err ->
                    lager:error("Shuffle reply to ~p failed with error ~p",
                                [Requester, Err]),
                    {reply, Err, S0}
            end
    end;

%% Accept a shuffle reply, add the reply list into the passive view and
%% close the temporary connection.
handle_call({shuffle_reply, ReplyXList, Ref}, _, S0) ->
    case lists:keyfind(Ref, 1, S0#st.shufflehist) of
        %% Clean up the shuffle history, add the reply list to passive view
        {Ref, XList, _} ->
            ShuffleHist = lists:keydelete(Ref, 1, S0#st.shufflehist),
            {ViewChange, S} = add_exchange_list(ReplyXList, XList, S0),
            {reply, ViewChange, S#st{shufflehist=ShuffleHist}};
        %% Stale data or something buggy
        false ->
            lager:info("Stale shuffle reply received, ignoring."),
            {reply, no_change(), S0}
    end;
%% Handle failing connections. This may be either active connections or
%% open neighbour requests. If a connection has failed, try
%% and find a new one.
handle_call({error, Sender, Reason}, _, S0) ->
    S1 = 
        case lists:keyfind(Sender, #peer.id, S0#st.activev) of
            false ->
                lager:error("Pending neighbour ~p failed with error ~p.",
                            [Sender, Reason]),

                %% Pending neighbour
                P = lists:keyfind(Sender, #peer.id, S0#st.pendingv),
                PendingV = lists:keydelete(P#peer.id, #peer.id, S0#st.pendingv),
                S0#st{pendingv=PendingV};
            P ->
                lager:error("Active connection to ~p failed with error ~p.",
                            [Sender, Reason]),
                neighbour_down(S0#st.notify, P#peer.id),
                ActiveV = lists:keydelete(P#peer.id, #peer.id, S0#st.activev),
                S0#st{activev=ActiveV}
        end,
    
    case find_new_active(S1) of
        {no_peers, S} ->
            lager:error("No valid peers to connect to."),
            {reply, {error, no_peers}, S};
        {ViewChange, S} ->
            {reply, ViewChange, S}
    end;

%% Return current active peers
handle_call(get_peers, _, S) ->
    ActiveV = [P#peer.id || P <- S#st.activev],
    {reply, ActiveV, State};

%% Return current passive peers
handle_call(get_passive_peers, _, S) ->
    {reply, S#st.passivev, S};

%% Return current pending peers
handle_call(get_pending_peers, _, S) ->
    Pending = [P#peer.id || P <- S#st.pending],
    {reply, Pending, S};

%% Return all peers
handle_call(get_all_peers, _, S) ->
    #state{active_view=ActiveV0, passive_view=PassiveV,
           pending=PendingV0} = State,
    ActiveV  = [P#peer.id || P <- ActiveV0],
    PendingV = [P#peer.id || P <- PendingV0],
    {reply, {ActiveV, PassiveV, PendingV}, State};

%% Stop the hypar_node
handle_call(stop, _, S) ->
    lists:foreach(fun(P) ->
                          erlang:unlink(P#peer.pid),
                  end, S#st.activev ++ S#st.pendingv),
    connect:stop(),
    {stop, normal, ok, S}.

%% Timer message for periodic shuffle. Send of a shuffle request to a random
%% peer in the active view. Ignore if we don't have any active connections.     
handle_info(shuffle_time, S0) ->
    ShuffleHist = 
        case S0#st.activev =:= [] of
            true ->
                S0#st.shufflehist;
            false ->
                XList = create_xlist(S0#st.id, S0#st.activev, S0#st.passivev),
                P = misc:random_elem(S0#st.activev),
                
                ARWL = proplists:get_value(arwl, Options),
                Ref = erlang:make_ref(),
                Now = erlang:now(),
                New = {Ref, XList, Now},
                shuffle_request(P, S0#st.id, XList, ARWL-1, Ref),
                [New|S0#st.shufflehist]
        end,
    
    start_shuffle_timer(Options),

    %% Cleanup shuffle history and add new shuffle
    S = clean_shuffle_history(S0#st{shufflehist=Shufflehist}),
    {noreply, S}.

code_change(_, S, _) ->
    {ok, S}.

terminate(_, S) ->
    lists:foreach(fun(P) ->
                          erlang:unlink(P#peer.pid),
                  end, S#st.activev ++ S#st.pendingv),
    connect:stop().

%% Internal

try_connect_send(From, To, Msg, State) ->
    case connect:new_connection(From, To, State) of
        {error, Err} ->
            {error, Err};
        P ->
            send(P, Msg)
    end.


send(P, Msg) ->
    case connect:send_message(P, Msg) of
        ok -> P;
        Err -> Err
    end.


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
    if ShufflePeriod =/= undefined ->
            erlang:send_after(ShufflePeriod, self(), shuffle_time);
       true ->
            ok
    end.

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
            erlang:demonitor(MRef, [flush]),
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
    #state{id=ThisNode, pending=Pending,
           active_view=Active, passive_view=Passive0} = State,
    Priority = get_priority(Active, Pending),

    case find_neighbour(Priority, Passive0, ThisNode) of
        {PossiblePeer, Passive} ->
            State#state{passive_view=Passive, pending=[PossiblePeer|Pending]};
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

no_change() ->
    {no_change, no_change, no_change}.
