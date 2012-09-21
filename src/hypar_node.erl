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
%% Imports %%
%%%%%%%%%%%%%
-include("hyparerl.hrl").

%%%%%%%%%%%%%
%% Exports %%
%%%%%%%%%%%%%

%% Operations
-export([start_link/1, stop/0, join_cluster/1, shuffle/0]).

%% View related
-export([get_peers/0, get_passive_peers/0]).

%% Send related
-export([send/2, multi_send/2]).

%% Synchronus events
-export([join/2, forward_join_reply/2, neighbour/3, error/2]).

%% ASynchronus events
-export([forward_join/4, shuffle/6, shuffle_reply/3]).

%% gen_server callbacks
-export([init/1, terminate/2, code_change/3,
         handle_call/3, handle_cast/2, handle_info/2]).

%%%%%%%%%%%
%% State %%
%%%%%%%%%%%

-record(st, {id = {{127,0,0,1},6000} :: id(),      %% This nodes identifier
             activev = []  :: list(#peer{}),       %% The active view
             passivev = [] :: list(id()),          %% The passive view
             shist = []    :: list(shuffle_ent()), %% History of shuffle requests sent
             opts          :: options(),           %% Options
             notify        :: pid() | atom()       %% Notify process with link_up/link_down
            }).

%%%%%%%%%
%% API %%
%%%%%%%%%

%%%%%%%%%%%%%%%%
%% Operations %%
%%%%%%%%%%%%%%%%

-spec start_link(Options :: options()) -> 
                        {ok, pid()} | ignore | {error, any()}.
%% @doc Start the <b>hypar_node</b> with <em>Options</em>.
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

-spec stop() -> ok.
%% @doc Stop the <b>hypar_node</b>.
stop() ->
    gen_server:call(?MODULE, stop).

-spec join_cluster(ContactNode :: id()) -> ok | {error, any()}.
%% @doc Let the <b>hypar_node</b> join a cluster via <em>ContactNode</em>.
join_cluster(ContactNode) ->
    gen_server:call(?MODULE, {join_cluster, ContactNode}).

-spec shuffle() -> shuffle.
%% @doc Force the <b>hypar_node</b> to do a shuffle operation.
shuffle() ->
    ?MODULE ! shuffle.

%%%%%%%%%%%%%%%%%%%%%
%% Peer operations %%
%%%%%%%%%%%%%%%%%%%%%

-spec get_peers() -> view().
%% @doc Get all the current active peers.
get_peers() ->
    gen_server:call(?MODULE, get_peers).

-spec get_passive_peers() -> view().
%% @doc Get all the current passive peers.
get_passive_peers() ->
    gen_server:call(?MODULE, get_passive_peers).

%%%%%%%%%%
%% Send %%
%%%%%%%%%%
-spec send(Peer :: #peer{}, Bin :: binary()) -> ok.
%% @doc Send active <em>Peer</em> a binary message <em>Bin</em>.
send(Peer, Bin) ->
    gen_fsm:send_event(Peer#peer.pid, {message, Bin}).

-spec multi_send(Peers :: list(#peer{}), Bin :: binary()) -> ok.
multi_send(Peers, Bin) ->
    lists:foreach(fun(P) -> send(P, Bin) end, Peers).                          

%%%%%%%%%%%%%%%%%%%%%%%%
%% Synchronous Events %%
%%%%%%%%%%%%%%%%%%%%%%%%

-spec join(Peer :: #peer{}, Sender :: id()) -> ok | {error, any()}.
%% @doc Join <em>Sender</em> to the peer <em>Pid</em>.
join(Peer, Sender) ->
    sync_event(Peer, join_msg(Sender)).

-spec forward_join_reply(Peer :: #peer{}, Sender :: id()) ->
                                ok | {error, any()}.
%% @doc Forward join reply <em>Sender</em> to the <em>Peer</em>.
forward_join_reply(Peer, Sender) ->
    sync_event(Peer, forward_join_reply_msg(Sender)).

-spec neighbour(Peer :: #peer{}, Sender :: id(), Priority :: priority()) ->
                       accept | decline | {error, any()}.
%% @doc Neighbour request from <em>Sender</em> to <em>Peer</em> with
%%      <em>Priority</em>.
neighbour(Peer, Sender, Priority) ->
    sync_event(Peer, neighbour_msg(Sender, Priority)).

-spec disconnect(Peer :: #peer{}, Sender :: id()) -> ok.
%% @doc Disconnect <em>Peer</em> from <em>Sender</em>. 
disconnect(Peer, Sender) ->
    sync_event(Peer, {disconnect, Sender}).

-spec error(Sender :: id(), Reason :: any()) -> ok | {error, any()}.
%% @doc Let the <b>hypar_node</b> know that <em>Sender</em> has failed
%%      with <em>Reason</em>. 
error(Sender, Reason) ->
    gen_server:call(?MODULE, {error, Sender, Reason}).

%%%%%%%%%%%%%%%%%%%%%%%%%
%% Asynchronous Events %%
%%%%%%%%%%%%%%%%%%%%%%%%%

-spec forward_join(Peer :: #peer{}, Sender :: id(), NewNode :: id(),
                   TTL :: non_neg_integer()) -> ok.
%% @doc Forward join <em>NewNode</em> from <em>Sender</em> to the <em>Peer</em>
%%      with time to live <em>TTL</em>. 
forward_join(Peer, Sender, NewNode, TTL) ->
    async_event(Peer, forward_join_msg(Sender, NewNode, TTL)).

-spec shuffle(Peer :: #peer{}, Sender :: id(), Requester :: id(),
              XList :: list(id()), TTL :: non_neg_integer(),
              Ref :: reference()) -> ok.
%% @doc Shuffle request from <em>Sender</em> to <em>Peer</em>. The shuffle
%%      request originated in node <em>Requester</em> and <em>XList</em>
%%      contains sample node identifiers. The message has a time to live of
%%      <em>TTL</em> and is tagged by the reference <em>Ref</em>. 
shuffle(Peer, Sender, Requester, XList, TTL, Ref) ->
    async_event(Peer, shuffle_msg(Sender, Requester, XList, TTL, Ref)).

-spec shuffle_reply(Peer :: #peer{}, ReplyXList :: list(id()),
                    Ref :: reference()) -> ok.
%% @doc Shuffle reply to shuffle request with reference <em>Ref</em> sent to
%%      <em>Peer</em> that carries the sample list <em>ReplyXList</em>.
shuffle_reply(Peer, ReplyXList, Ref) ->
    async_event(Peer, shuffle_reply_msg(ReplyXList, Ref)).

%%%%%%%%%%%%
%% Events %%
%%%%%%%%%%%%

-spec sync_event(Peer :: #peer{}, Event :: any()) -> any().
%% @doc Send a synchronous event <em>Event</em> to <em>Peer</em>. If
%%      <em>Peer</em> is <b>hypar_node</b> then gen_server:call/2 is used else
%%      <em>Peer</em> is remote and gen_fsm:sync_send_event/2 is used instead.
%% @todo Need to add timeout errors
sync_event(Peer, Event) when Peer#peer.pid =:= hyparerl ->
    gen_server:call(Peer#peer.pid, Event);
sync_event(Peer, Event) ->
    gen_fsm:sync_send_event(Peer#peer.pid, Event).

-spec async_event(Peer :: #peer{}, Event :: any()) -> ok.
%% @doc Send an asynchronous event <em>Event</em>to <em>Peer</em>. If
%%      <em>Peer</em> is <b>hypar_node</b> then gen_server:cast/2 is used else
%%      <em>Peer</em> is remote and gen_fsm:send_event/2 is used instead.
async_event(Peer, Event) when Peer#peer.pid =:= hyparerl ->
    gen_server:cast(Peer#peer.pid, Event);
async_event(Peer, Event) ->
    gen_fsm:send_event(Peer#peer.pid, Event).

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
neighbour_msg(Sender, Priority) ->
    {neighbour_request, Sender, Priority}.

%% @private
%% @doc A shuffle request
shuffle_msg(Sender, Requester, XList, TTL, Ref) ->
    {shuffle, Sender, Requester, XList, TTL, Ref}.

%% @private
%% @doc A shuffle reply
shuffle_reply_msg(XList, Ref) ->
    {shuffle_reply, XList, Ref}.

%%%%%%%%%%%%
%% Notify %%
%%%%%%%%%%%%

%% @doc Notify <em>Pid</em> of a <b>link_up</b> event to node <em>To</em>.
%% @todo Support multiple types of noftifyee(gen_server, fsm etc)
neighbour_up(Pid, To) ->
    lager:info("Link up: ~p~n", [To]),
    gen_server:cast(Pid, {link_up, To}).

%% @doc Notify <em>Pid</em> of a <b>link_down</b> event to node <em>To</em>.
%% @todo Support multiple types of noftifyee(gen_server, fsm etc)
neighbour_down(Pid, To) ->
    lager:info("Link down: ~p~n", [To]),
    gen_server:cast(Pid, {neighbour_down, To}).

%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server callbacks %%
%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec init(Options :: options()) -> {ok, #st{}}.
%% Initialize the hypar_node
init(Options) ->
    %% Seed the random generator!
    random:seed(now()),

    %% Find this nodes id
    ThisNode = proplists:get_value(id, Options, {{127,0,0,1},6000}),
    lager:info([{options, Options}], "Initializing..."),
    
    %% Initialize connection handlers
    connect:initialize(Options),
    
    %% Start shuffle
    shuffle_timer(Options),

    %% Construct state
    Notify   = proplists:get_value(notify, Options),
    
    {ok, #st{id       = ThisNode,
             opts     = Options,
             notify   = Notify}}.

%% Join a cluster via a given contact-node
%% According to the paper this should only be done once. I don't really see
%% why one would not be able to do multiple cluster joins to rejoin or to
%% populate the active view faster
handle_call({join_cluster, ContactNode}, _, S0) ->
    case lists:keyfind(ContactNode, #peer.id, S0#st.activev) of
        undefined ->
            ThisNode = S0#st.id,
            case connect:new_active(ThisNode, ContactNode) of
                {error, Err} ->
                    lager:error("Join cluster via ~p failed with error ~p.~n",
                                [ContactNode, Err]),
                    {reply, {error, Err}, S0};
                P ->
                    case join(P, ThisNode) of
                        {error, Err}  ->
                            lager:error("Join error ~p to ~p.~n", [Err, P]),
                            {reply, {error, Err}, S0};
                        ok ->
                            {reply, ok, add_node_active(P, S0)}
                    end
            end;
        P -> 
            lager:error("Attempting to join via existing peer ~p.~n", [P]),
            {reply, {error, already_in_active_view}, S0}
    end;

%% Add newly joined node to active view, propagate a forward join
handle_call({join, Sender}, {Pid,_}, S0) ->
    S = add_node_active(#peer{id=Sender, pid=Pid}, S0),

    %% Send forward joins
    ARWL = proplists:get_value(arwl, S#st.opts),

    ForwardFun = fun(X) -> ok = forward_join(X, S#st.id, Sender, ARWL) end,
    FilterFun  = fun(X) -> X#peer.id =/= Sender end,
    ForwardNodes = lists:filter(FilterFun, S#st.activev),
    
    lists:foreach(ForwardFun, ForwardNodes),

    {reply, ok, S};

%% Accept a connection from the join procedure
handle_call({forward_join_reply, Sender}, {Pid,_} , S0) ->
    {reply, ok, add_node_active(#peer{id=Sender, pid=Pid}, S0)};

%% Disconnect an open active connection, add disconnecting node to passive view
handle_call({disconnect, Sender}, _, S0) ->
    #peer{id=Sender} = lists:keyfind(Sender, #peer.id, S0#st.activev),
    %% Disconnect the peer, close the connection and add node to passive view
    ActiveV = lists:keydelete(Sender, #peer.id, S0#st.activev),
    neighbour_down(S0#st.notify, Sender),
    {reply, ok, add_node_passive(Sender, S0#st{activev=ActiveV})};

%% Respond to a request, either accept or decline based on priority and current
%% active view
handle_call({neighbour, Sender, Priority},{Pid,_} , S) ->
    P = #peer{id=Sender, pid=Pid},
    case Priority of
        %% High priority neighbour request thus the node needs to accept the
        %% request what ever the current active view is
        high ->
            lager:info("Neighbour accepted: ~p.~n", [P]),
            {reply, accept, add_node_active(P, S)};
        %% Low priority request, only accept if we have space in the
        %% nodes active view
        low ->
            ASize = proplists:get_value(active_size, S#st.opts),
            case length(S#st.activev) < ASize of
                true ->
                    {reply, accept, add_node_active(P, S)};
                false ->
                    lager:info("Neighbour declined ~p.~n", [P]),
                    {reply, decline, S}
            end
    end;

%% Handle failing connections. This may be either active connections or
%% open neighbour requests. If a connection has failed, try
%% and find a new one.
handle_call({error, Sender, Reason}, _, S0) ->
    lager:error("Active link to ~p failed with error ~p.~n", [Sender, Reason]),
    neighbour_down(S0#st.notify, Sender),
    S = S0#st{activev=lists:keydelete(Sender, #peer.id, S0#st.activev)},
    {reply, ok, find_new_active(S)};

%% Return current active peers
handle_call(get_peers, _, S) ->
    {reply, S#st.activev, S};

%% Return current passive peers
handle_call(get_passive_peers, _, S) ->
    {reply, S#st.passivev, S};

%% Stop the hypar_node
handle_call(stop, _, S) ->
    lists:foreach(fun(P) ->
                          erlang:unlink(P#peer.pid),
                          erlang:exit(P#peer.pid, terminate)
                  end, S#st.activev),
    connect:stop(),
    {stop, normal, ok, S}.

%% Respond to a forward_join, add to active or propagate and maybe add to
%% passive view.
handle_cast({forward_join, Sender, NewNode, TTL}, S0) ->
    ThisNode = S0#st.id,
    case TTL =:= 0 orelse length(S0#st.activev) =:= 1 of 
        true ->
            %% Add to active view, send a reply to the forward_join to let the
            %% other node know
            case connect:new_active(ThisNode, NewNode) of
                {error, Err} ->
                    lager:error("Forward join reply to ~p  failed with error ~p",
                                [NewNode, Err]),
                    {noreply, S0};
                P ->
                    case forward_join_reply(P, ThisNode) of
                        {error, Err} ->
                            lager:error("Forward join reply error ~p to ~p.~n",
                                        [Err, P]),
                            {noreply, S0};
                        ok ->
                            {noreply, add_node_active(P, S0)}
                    end
            end;
        false ->            
            %% Add to passive view if TTL is equal to PRWL
            PRWL = proplists:get_value(prwl, S0#st.opts),
            S1 = case TTL =:= PRWL of
                     true  -> add_node_passive(NewNode, S0);
                     false -> S0
                 end,
            
            %% Propagate the forward join using a random walk
            AllButSender = lists:keydelete(Sender, #peer.id, S1#st.activev),
            P = misc:random_elem(AllButSender),
            
            forward_join(P, S1#st.id, NewNode, TTL-1),
            {noreply, S1}
    end;

%% Respond to a shuffle request, either propagate it or accept it via a
%% temporary connection to the source of the request. If the node accept then
%% it adds the shuffle list into it's passive view and responds with with
%% a shuffle reply
handle_cast({shuffle, Sender, Requester, XList, TTL, Ref}, S0) ->
    case TTL > 0 andalso length(S0#st.activev) > 1 of
        %% Propagate the random walk
        true ->
            AllButSender = lists:keydelete(Sender, #peer.id, S0#st.activev),
            P = misc:random_elem(AllButSender),
            
            shuffle(P, S0#st.id, Requester, XList, TTL-1, Ref),
            {noreply, S0};
        %% Accept the shuffle request, add to passive view and reply
        false ->
            ReplyXList = misc:take_n_random(length(XList), S0#st.passivev),
            case connect:new_temp(S0#st.id, Requester) of
                {error, Err} ->
                    lager:error("Shuffle reply ~p to ~p failed with error: ~p",
                                [Ref, Requester, Err]),
                    {noreply, S0};
                P ->
                    shuffle_reply(P, ReplyXList, Ref),
                    {noreply, add_xlist(XList, ReplyXList, S0)}
            end
    end;

%% Accept a shuffle reply, add the reply list into the passive view and
%% close the temporary connection.
handle_cast({shuffle_reply, ReplyXList, Ref}, S0) ->
    SHist0 = S0#st.shist,
    case lists:keyfind(Ref, 1, SHist0) of
        %% Clean up the shuffle history, add the reply list to passive view
        {Ref, XList, _} ->
            SHist = lists:keydelete(Ref, 1, SHist0),
            {noreply, add_xlist(S0#st{shist=SHist}, ReplyXList, XList)};
        %% Stale data or something buggy
        false ->
            lager:info("Stale shuffle reply received, ignoring.~n"),
            {noreply, S0}
    end.

%% Timer message for periodic shuffle. Send of a shuffle request to a random
%% peer in the active view. Ignore if we don't have any active connections.     
handle_info(shuffle, S) ->
    Opts = S#st.opts,
    case S#st.activev =:= [] of
        true ->
            SHist0 = S#st.shist;
        false ->
            XList = create_xlist(S),
            P = misc:random_elem(S#st.activev),
            
            ARWL = proplists:get_value(arwl, Opts),
            Ref = erlang:make_ref(),
            Now = erlang:now(),
            New = {Ref, XList, Now},
            shuffle(P, S#st.id, S#st.id, XList, ARWL-1, Ref),
            SHist0 = [New|S#st.shist]
        end,
    
    ShufflePeriod = proplists:get_value(shuffle_period, Opts),
    shuffle_timer(ShufflePeriod),

    %% Cleanup shuffle history
    BufferSize = proplists:get_value(shuffle_buffer, Opts),
    SHist = clear_shist(BufferSize, SHist0),
    {noreply, S#st{shist=SHist}}.

code_change(_, S, _) ->
    {ok, S}.

terminate(_, S) ->
    lists:foreach(fun(P) ->
                          erlang:unlink(P#peer.pid),
                          erlang:exit(P#peer.pid, terminate)
                  end, S#st.activev),
    connect:stop().

%%%%%%%%%%%%%%%%%%%%%
%% Shuffle related %%
%%%%%%%%%%%%%%%%%%%%%

-spec shuffle_timer(ShufflePeriod :: non_neg_integer()) -> ok.           
%% @private
%% @doc Set the shuffle timer to <em>ShufflePeriod</em>.
shuffle_timer(ShufflePeriod) ->
    case ShufflePeriod of
        undefined -> 
            ok;
        ShufflePeriod ->
            erlang:send_after(ShufflePeriod, self(), shuffle_time),
            ok
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%
%% Active view related %%
%%%%%%%%%%%%%%%%%%%%%%%%%

-spec add_node_active(Peer :: #peer{}, S0 :: #st{}) -> #st{}.
%% @private
%% @doc Add <em>Peer</em> to the active view in state <em>S0</em>, removing a
%%      node if necessary. The new state is returned. If a node has to be
%%      dropped, then it is informed via a DISCONNECT message and placed in the
%%      passive view.
add_node_active(Peer, S0) ->
    Id = Peer#peer.id,
    ActiveV0 = S0#st.activev,
    case Id =/= S0#st.id andalso not lists:keymember(Id, #peer.id, ActiveV0) of
        true ->
            ASize = proplists:get_value(active_size, S0#st.opts),
            S = case length(ActiveV0) >= ASize of
                    true  -> drop_random_active(S0);
                    false -> S0
                end,
            %% Notify link change
            neighbour_up(S#st.notify, Id),
            S#st{activev=[Peer|S#st.activev]};
        false ->
            S0
    end.

-spec drop_random_active(S :: #st{}) -> #st{}.
%% @private
%% @doc Drop a random node from the active view in state down to the passive
%%      view in <em>S</em>. Send a disconnect message to the dropped node.
drop_random_active(S) ->
    PassiveSize = proplists:get_value(passive_size, S#st.opts),
    PassiveV0 = S#st.passivev,
    PassiveL = length(PassiveV0),
    Slots = PassiveL-PassiveSize+1,
    {Peer, ActiveV} = misc:drop_random(S#st.activev),
    PassiveV = [Peer#peer.id|misc:drop_n_random(Slots, PassiveV0)],

    disconnect(Peer, S#st.id),
    neighbour_down(S#st.notify, Peer#peer.id),
    S#st{activev=ActiveV, passivev=PassiveV}.

-spec find_new_active(S :: #st{}) -> #st{}.
%% @private
%% @doc Find a new active peer in state <em>S</em>. The function will send
%%      neighbour requests to nodes in passive view until it finds a good one.
find_new_active(S) ->
    Priority = get_priority(S#st.activev),

    case find_neighbour(Priority, S#st.passivev, S#st.id) of
        {Peer, PassiveV} ->
            add_node_active(Peer, S#st{passivev=PassiveV});
        no_valid ->
            lager:error("No reachable peers in passive view.~n"),
            S#st{passivev=[]}
    end.

-spec find_neighbour(Priority :: priority(), PassiveV :: list(id()),
                     ThisNode :: id()) -> {#peer{}, list(id())} | no_valid.
%% @private
%% @doc Try to find a new active neighbour to <em>ThisNode</em> with priority
%%      <em>Priority</em>. Try random nodes out of <em>PassiveV</em>, removing
%%      failing once and logging declined requests. Returns either a new active
%%      peer along with the new passive view or <b>no_valid</b> if no peers
%%      were connectable.
find_neighbour(Priority, PassiveV, ThisNode) ->
    find_neighbour(Priority, PassiveV, ThisNode, []).

-spec find_neighbour(Priority :: priority(), PassiveV :: list(id()),
                     ThisNode :: id(), Tried :: list(id())) ->
                            {#peer{}, list(id())} | no_valid.
%% @private
%% @doc Helper function for find_neighbour/3.
find_neighbour(_, [], _, _) ->
    false;
find_neighbour(Priority, PassiveV0, ThisNode, Tried) ->
    {Node, Passive} = misc:drop_random(PassiveV0),
    case connect:new_pending(ThisNode, Node) of
        {error, Err} ->
            lager:error("Neighbour ~p is unreachable with error ~p.~n",
                        [Node, Err]),
            find_neighbour(Priority, Passive, ThisNode, Tried);
        P ->
            case neighbour(P, ThisNode, Priority) of
                accept  ->
                    lager:info("Peer ~p accepted neighbour request.~n", [P]),
                    {P,Passive ++ Tried};
                decline ->
                    lager:info("Peer ~p declined neighbour request.~n", [P]),
                    find_neighbour(Priority, Passive, ThisNode, [Node|Tried]);
                {error, Err} ->
                    lager:error("Neighbour error ~p to ~p.~n", [Err, Node]),
                    find_neighbour(Priority, Passive, ThisNode, Tried)
            end
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Passive view related %%
%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec add_node_passive(Node :: id(), S :: #st{}) -> #st{}.
%% @private
%% @doc Add <em>Node</em> to the passive view in state <em>S</em>, removing
%%      random entries if needed. 
add_node_passive(Node, S) ->
    PassiveV0 = S#st.passivev,
    case Node =/= S#st.id andalso
        not lists:keymember(Node, #peer.id, S#st.activev) andalso
        not lists:member(Node, PassiveV0) of
        true -> 
            PSize = proplists:get_value(passive_size, S#st.opts),
            Slots = length(PassiveV0)-PSize+1,
            %% drop_n_random returns the same list if called with 0 or negative
            PassiveV =  [Node|misc:drop_n_random(Slots, PassiveV0)],
            S#st{passivev=PassiveV};
        false ->
            S
    end.

-spec add_xlist(S :: #st{}, XList0 :: list(id()), ReplyList :: list(id())) ->
                       #st{}.
%% @private
%% @doc Add <em>XList0</em> it into the view in state <em>S</em>. Do not add
%%      nodes that are already in active or passive view from the list. If the
%%      passive view are full, start by dropping elements from ReplyList then random
%%      elements.
add_xlist(S, XList0, ReplyList) ->
    PassiveSize = proplists:get_value(passive_size, S#st.opts),
    PassiveV0 = S#st.passivev,
    Filter = fun(Node) ->
                     Node =/= S#st.id andalso
                         not lists:keymember(Node, #peer.id, S#st.activev) andalso
                         not lists:member(Node, PassiveV0)
             end,
    XList = lists:filter(Filter, XList0),
    PassiveV = free_slots(length(PassiveV0)-PassiveSize+length(XList),
                          PassiveV0, ReplyList) ++ XList,
    S#st{passivev=PassiveV}.

-spec create_xlist(S :: #st{}) -> #st{}.
%% @private
%% @doc Create the exchange list in state <em>S</em> used in a shuffle request.
create_xlist(S) ->
    KActive = proplists:get_value(k_active, S#st.opts),
    KPassive = proplists:get_value(k_passive, S#st.opts),

    ActiveV = lists:map(fun(P) -> P#peer.id end, S#st.activev),
    
    RandomActive  = misc:take_n_random(KActive, ActiveV),
    RandomPassive = misc:take_n_random(KPassive, S#st.passivev),
    [S#st.id | (RandomActive ++ RandomPassive)].

%%%%%%%%%%%%%%%
%% Pure code %%
%%%%%%%%%%%%%%%

-spec clear_shist(BufferSize :: non_neg_integer(),
                  SHist :: list(shuffle_ent())) -> list(shuffle_ent()).
%% @pure
%% @private
%% @doc Clean-up old shuffle entries in <em>SHist</em> if the buffer contains
%%      more than <em>BufferSize</em> entries.
clear_shist(BufferSize, SHist) ->
    case length(SHist) >= BufferSize of
        true -> drop_oldest(SHist);
        false -> SHist
    end.

-spec drop_oldest(SHist :: list(shuffle_ent())) -> list(shuffle_ent()).
%% @pure
%% @private
%% @doc Drop the oldest shuffle entry from <em>SHist</em>.
drop_oldest(SHist) ->
    tl(lists:usort(fun({_,_,T1}, {_,_,T2}) -> T1 < T2 end, SHist)).

-spec get_priority(list(#peer{})) -> priority().
%% @pure
%% @private
%% @doc Find the priority of a neighbour. If no active entries exist
%%      the priority is <b>high</b>, otherwise <b>low</b>.
get_priority([]) -> high;
get_priority(_)  -> low.

-spec free_slots(I :: integer(), List :: list(T), Rs :: list(T)) -> list(T).
%% @pure
%% @private
%% @doc Free up <em>I</em> slots in <em>List</em>, start by removing elements
%%      from <em>Rs</em>, then remove at random.
free_slots(I, List, _) when I =< 0 -> List;
free_slots(I, List, []) -> misc:drop_n_random(I, List);
free_slots(I, List, [R|Rs]) ->
    case lists:member(R, List) of
        true  -> free_slots(I-1, lists:delete(R, List), Rs);
        false -> free_slots(I, List, Rs)
    end.
