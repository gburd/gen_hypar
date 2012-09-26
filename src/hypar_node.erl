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

%% Notification
-export([notify_me/0, stop_notifying/0]).

%% View related
-export([get_peers/0, get_passive_peers/0]).

%% Synchronus events
-export([join/1, join_reply/1, neighbour/2, disconnect/1, error/2]).

%% ASynchronus events
-export([forward_join/3, shuffle/5, shuffle_reply/2]).

%% gen_server callbacks
-export([init/1, terminate/2, code_change/3,
         handle_call/3, handle_cast/2, handle_info/2]).

%%%%%%%%%%%
%% State %%
%%%%%%%%%%%

-record(st, {id            :: id(),              %% This nodes identifier
             activev = []  :: active_view(),     %% The active view
             passivev = [] :: passive_view(),    %% The passive view
             shist = []    :: shuffle_history(), %% History of shuffle requests sent
             scount = 0    :: pos_integer(),     %% The shuffle id
             opts          :: options(),         %% Options
             notify        :: proc() |undefined  %% Notify process with link_up/link_down
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
    ?MODULE !shuffle.

%%%%%%%%%%%%%%%%%%%%%
%% Peer operations %%
%%%%%%%%%%%%%%%%%%%%%

-spec get_peers() -> list({id(), pid()}).
%% @doc Get all the current active peers.
get_peers() ->
    gen_server:call(?MODULE, get_peers).

-spec get_passive_peers() -> passive_view().
%% @doc Get all the current passive peers.
get_passive_peers() ->
    gen_server:call(?MODULE, get_passive_peers).

%%%%%%%%%%%%
%% Events %%
%%%%%%%%%%%%

-spec join(Sender :: id()) -> ok | {error, already_in_active}.
%% @doc Join <em>Sender</em>.
join(Sender) ->
    gen_server:call(?MODULE, {join, Sender}).

-spec forward_join(Sender :: id(), NewNode :: id(), TTL :: non_neg_integer()) ->
                          ok.
%% @doc Forward join <em>NewNode</em> from <em>Sender</em> with time to live
%%      <em>TTL</em>.
forward_join(Sender, NewNode, TTL) ->
    gen_server:cast(?MODULE, {forward_join, Sender, NewNode, TTL}).

-spec join_reply(Sender :: id()) -> ok | {error, already_in_active}.
%% @doc Join reply from <em>Sender</em>.
join_reply(Sender) ->
    gen_server:call(?MODULE, {join_reply, Sender}).

-spec neighbour(Sender :: id(), Priority :: priority()) ->
                       accept | decline | {error, already_in_active}.
%% @doc Neighbour request from <em>Sender</em> with <em>Priority</em>.
neighbour(Sender, Priority) ->
    gen_server:call(?MODULE, {neighbour, Sender, Priority}).

-spec disconnect(Sender :: id()) -> ok | {error, not_in_active}.
%% @doc Disconnect <em>Sender</em>.
disconnect(Sender) ->
    gen_server:call(?MODULE, {disconnect, Sender}).

-spec error(Sender :: id(), Reason :: any()) -> ok | {error, not_in_active}.
%% @doc Let the <b>hypar_node</b> know that <em>Sender</em> has failed
%%      with <em>Reason</em>.
error(Sender, Reason) ->
    gen_server:call(?MODULE, {error, Sender, Reason}).

-spec shuffle(Sender :: id(), Requester :: id(), XList :: xlist(),
              TTL :: non_neg_integer(), SId :: binary()) -> ok.
%% @doc Shuffle request from <em>Sender</em>. The shuffle request originated in
%%      node <em>Requester</em> and <em>XList</em> contains sample node
%%      identifiers. The message has a time to live of <em>TTL</em> and is
%%      tagged by the reference <em>Ref</em>.
shuffle(Sender, Requester, XList, TTL, SId) ->
    gen_server:cast(?MODULE, {shuffle, Sender, Requester, XList, TTL, SId}).

-spec shuffle_reply(SId :: binary(), ReplyXList :: xlist()) -> ok.
%% @doc Shuffle reply to shuffle request with reference <em>Ref</em> sent from
%%      <em>Sender</em> that carries the sample list <em>ReplyXList</em>.
shuffle_reply(SId, ReplyXList) ->
    gen_server:cast(?MODULE, {shuffle_reply,SId, ReplyXList}).

%%%%%%%%%%%%
%% Notify %%
%%%%%%%%%%%%

%% @doc Add yourself to the processes that receives notifications
%%      Also returns the current active view
notify_me() ->
    gen_server:call(?MODULE, notify_me).

%% @doc Stop sending notification to a process
stop_notifying() ->
    gen_server:call(?MODULE, stop_notifying).

%% @doc Notify <em>Pids</em> of a <b>link_up</b> event to node <em>To</em>.
neighbour_up(undefined, To, Conn) ->
    lager:info("Link up: ~p~n", [{To, Conn}]);
neighbour_up(Serv, To, Conn) ->
    lager:info("Link up: ~p~n", [{To, Conn}]),
    Serv ! {link_up, {To, Conn}}.

%% @doc Notify <em>Pids</em> of a <b>link_down</b> event to node <em>To</em>.
neighbour_down(undefined, To) ->
    lager:info("Link down: ~p~n", [To]);
neighbour_down(Serv, To) ->
    lager:info("Link down: ~p~n", [To]), 
    Serv !  {link_down, To}.

%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_server callbacks %%
%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec init(Options :: options()) -> {ok, #st{}}.
%% Initialize the hypar_node
init(Options) ->
    %% Seed the random generator!
    random:seed(now()),

    %% Find this nodes id
    ThisNode = proplists:get_value(id, Options),
    lager:info([{options, Options}], "Initializing..."),

    %% Start shuffle
    ShufflePeriod = proplists:get_value(shuffle_period, Options),
    shuffle_timer(ShufflePeriod),

    {ok, #st{id = ThisNode, opts = Options}}.

%% Join a cluster via a given contact-node
%% According to the paper this should only be done once. I don't really see
%% why one would not be able to do multiple cluster joins to rejoin or to
%% populate the active view faster
handle_call({join_cluster, ContactNode}, _, S0) ->
    case connect:join(ContactNode) of
        {error, Err} ->
            lager:error("Join cluster via ~p failed with error ~p.~n",
                        [ContactNode, Err]),
            {reply, {error, Err}, S0};
        P ->
            {reply, ok, add_node_active(P, S0)}
    end;

%% Add newly joined node to active view, propagate forward joins
handle_call({join, Sender}, {Pid,_}, S0) ->
    case lists:keyfind(Sender, #peer.id, S0#st.activev) of
        #peer{id=Sender} ->
            {reply, {error, already_in_active}, S0};
        false ->
            S = add_node_active(#peer{id=Sender, conn=Pid}, S0),

            %% Send forward joins
            ARWL = proplists:get_value(arwl, S#st.opts),
            
            ForwardFun =
                fun(X) ->
                        connect:forward_join(X#peer.conn, Sender, ARWL)
                end,
            FilterFun  = fun(X) -> X#peer.id =/= Sender end,
            ForwardNodes = lists:filter(FilterFun, S#st.activev),
            
            lists:foreach(ForwardFun, ForwardNodes),
            
            {reply, ok, S}
    end;

%% Accept a connection from the join procedure
handle_call({join_reply, Sender}, {Pid,_} , S0) ->
    case lists:keyfind(Sender, #peer.id, S0#st.activev) of
        #peer{id=Sender} ->
            {reply, {error, already_in_active}, S0};
        false ->
            {reply, ok, add_node_active(#peer{id=Sender, conn=Pid}, S0)}
    end;

%% Disconnect an open active connection, add disconnecting node to passive view
handle_call({disconnect, Sender}, _, S0) ->
    case lists:keyfind(Sender, #peer.id, S0#st.activev) of
        #peer{id=Sender} ->
            %% Disconnect the peer, close the connection and add node to passive view
            ActiveV = lists:keydelete(Sender, #peer.id, S0#st.activev),
            neighbour_down(S0#st.notify, Sender),
            {reply, ok, add_node_passive(Sender, S0#st{activev=ActiveV})};
        false ->
            {reply, {error, not_in_active}, S0}
    end;

%% Neighbour request, either accept or decline based on priority and current
%% active view
handle_call({neighbour, Sender, Priority},{Pid,_} , S) ->
    case lists:keyfind(Sender, #peer.id, S#st.activev) of
        #peer{id=Sender} ->
            {reply, {error, already_in_active}, S};
        false ->
            P = #peer{id=Sender, conn=Pid},
            case Priority of
                %% High priority neighbour request thus the node needs to accept
                %% the request what ever the current active view is
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
            end
    end;

%% Handle failing connections. Try to find a new one if possible
handle_call({error, Sender, Reason}, _, S0) ->
    case lists:keyfind(Sender, #peer.id, S0#st.activev) of
        false ->
            lager:error("Received error ~p from non-active link ~p~n",
                        [Reason, Sender]),
            {reply, {error, not_in_active}, S0};
        #peer{} ->
            lager:error("Active link to ~p failed with error ~p.~n",
                        [Sender, Reason]),
            neighbour_down(S0#st.notify, Sender),
            S = S0#st{activev=lists:keydelete(Sender, #peer.id, S0#st.activev)},
            {reply, ok, find_new_active(S)}
    end;

%% Return current active peers
handle_call(get_peers, _, S) ->
    Active = [{P#peer.id, P#peer.conn} || P <- S#st.activev],
    {reply, Active, S};

%% Return current passive peers
handle_call(get_passive_peers, _, S) ->
    {reply, S#st.passivev, S};

%% Start sending notifications to a process
handle_call(notify_me, {Pid, _}, S) when S#st.notify =:= undefined->
    MRef = erlang:monitor(process, Pid),
    Active = [{P#peer.id, P#peer.conn} || P <- S#st.activev],
    {reply, Active, S#st{notify={Pid, MRef}}};
handle_call(notify_me, _, S) ->
    {reply, {error, already_notifying}, S};

%% Stop notifying a process
handle_call(stop_notifying, {Pid, _}, S=#st{notify={Pid,MRef}}) ->
    erlang:unmonitor(MRef, [flush]),
    {reply, ok, S#st{notify=undefined}};
handle_call(stop_notifying, _, S) ->
    {reply, {error, not_notifying}, S};

%% Stop the hypar_node
handle_call(stop, _, S) ->
    connect:stop(),
    {stop, normal, ok, S}.

%% Respond to a forward_join, add to active or propagate and maybe add to
%% passive view.
handle_cast({forward_join, Sender, NewNode, TTL}, S0) ->
    case TTL =:= 0 orelse length(S0#st.activev) =:= 1 of
        true ->
            %% Add to active view, send a reply to the forward_join to let the
            %% other node know
            case connect:join_reply(NewNode) of
                {error, Err} ->
                    lager:error("Join reply error ~p to ~p.~n", [Err, NewNode]),
                    {noreply, S0};
                P -> 
                    {noreply, add_node_active(P, S0)}
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

            connect:forward_join(P#peer.conn, NewNode, TTL-1),
            {noreply, S1}
    end;

%% Respond to a shuffle request, either propagate it or accept it via a
%% temporary connection to the source of the request. If the node accept then
%% it adds the shuffle list into it's passive view and responds with with
%% a shuffle reply
handle_cast({shuffle, Sender, Req, SId, TTL, XList}, S0) ->
    case TTL > 0 andalso length(S0#st.activev) > 1 of
        %% Propagate the random walk
        true ->
            AllButSender = lists:keydelete(Sender, #peer.id, S0#st.activev),
            P = misc:random_elem(AllButSender),
            connect:shuffle(P#peer.conn, Req, SId, TTL-1, XList),
            {noreply, S0};
        %% Accept the shuffle request, add to passive view and reply
        false ->
            ReplyXList = misc:take_n_random(length(XList), S0#st.passivev),
            connect:shuffle_reply(Req, SId, ReplyXList),
            {noreply, add_xlist(S0, XList, ReplyXList)}
    end;

%% Accept a shuffle reply, add the reply list into the passive view and
%% close the temporary connection.
handle_cast({shuffle_reply, SId, ReplyXList}, S0) ->
    SHist0 = S0#st.shist,
    case lists:keyfind(SId, 1, SHist0) of
        %% Clean up the shuffle history, add the reply list to passive view
        {SId, XList, _} ->
            SHist = lists:keydelete(SId, 1, SHist0),
            {noreply, add_xlist(S0#st{shist=SHist}, ReplyXList, XList)};
        %% Stale data or something buggy
        false ->
            lager:info("Stale shuffle reply with id, ignoring.~n", [SId]),
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
            Now = erlang:now(),
            SId = S#st.scount,
            New = {SId, XList, Now},
            connect:shuffle(P#peer.conn, S#st.id, SId, ARWL-1, XList),
            SHist0 = [New|S#st.shist]
        end,

    ShufflePeriod = proplists:get_value(shuffle_period, Opts),
    shuffle_timer(ShufflePeriod),

    %% Cleanup shuffle history
    BufferSize = proplists:get_value(shuffle_buffer, Opts),
    SHist = clear_shist(BufferSize, SHist0),
    {noreply, S#st{scount=(S#st.scount+1) rem 256, shist=SHist}}.

code_change(_, S, _) ->
    {ok, S}.

terminate(_, _) ->
    connect:stop().

%%%%%%%%%%%%%%%%%%%%%
%% Shuffle related %%
%%%%%%%%%%%%%%%%%%%%%

-spec shuffle_timer(ShufflePeriod :: non_neg_integer()) -> ok;
                   (undefined) -> ok.
%% @private
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
                          PassiveV0, ReplyList),
    S#st{passivev=PassiveV++XList}.

-spec create_xlist(S :: #st{}) -> xlist().
%% @private
%% @doc Create the exchange list in state <em>S</em> used in a shuffle request.
create_xlist(S) ->
    KActive = proplists:get_value(k_active, S#st.opts),
    KPassive = proplists:get_value(k_passive, S#st.opts),

    ActiveV = lists:map(fun(P) -> P#peer.id end, S#st.activev),

    RandomActive  = misc:take_n_random(KActive, ActiveV),
    RandomPassive = misc:take_n_random(KPassive, S#st.passivev),
    [S#st.id | (RandomActive ++ RandomPassive)].

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
            neighbour_up(S#st.notify, Id, Peer#peer.conn),
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

    connect:disconnect(Peer#peer.conn),
    neighbour_down(S#st.notify, Peer#peer.id),
    S#st{activev=ActiveV, passivev=PassiveV}.

-spec find_new_active(S :: #st{}) -> #st{}.
%% @private
%% @doc Find a new active peer in state <em>S</em>. The function will send
%%      neighbour requests to nodes in passive view until it finds a good one.
find_new_active(S) ->
    Priority = get_priority(S#st.activev),

    case find_neighbour(Priority, S#st.passivev) of
        {no_valid, Passive} ->
            lager:info("No accepting peers in passive view.~n"),
            S#st{passivev=Passive};
        {Peer, PassiveV} ->
            add_node_active(Peer, S#st{passivev=PassiveV})
    end.

-spec find_neighbour(Priority :: priority(), PassiveV :: passive_view()) ->
                            {#peer{} | no_valid, passive_view()}.
%% @private
%% @doc Try to find a new active neighbour to <em>ThisNode</em> with priority
%%      <em>Priority</em>. Try random nodes out of <em>PassiveV</em>, removing
%%      failing once and logging declined requests. Returns either a new active
%%      peer along with the new passive view or <b>no_valid</b> if no peers
%%      were connectable.
find_neighbour(Priority, PassiveV) ->
    find_neighbour(Priority, PassiveV, []).

-spec find_neighbour(Priority :: priority(), PassiveV :: passive_view(),
                     Tried :: view()) -> {#peer{} | no_valid, passive_view()}.
%% @private
%% @doc Helper function for find_neighbour/3.
find_neighbour(_, [], Tried) ->
    {no_valid, Tried};
find_neighbour(Priority, PassiveV0, Tried) ->
    {Node, Passive} = misc:drop_random(PassiveV0),
    case connect:neighbour(Node, Priority) of
        {error, Err} ->
            lager:error("Neighbour error ~p to ~p.~n", [Err, Node]),
            find_neighbour(Priority, Passive, Tried);
        decline ->
            lager:info("Peer ~p declined neighbour request.~n", [Node]),
            find_neighbour(Priority, Passive, [Node|Tried]);
        P  ->
            lager:info("Peer ~p accepted neighbour request.~n", [P]),
            {P,Passive ++ Tried}
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

%%%%%%%%%%%%%%%
%% Pure code %%
%%%%%%%%%%%%%%%

-spec clear_shist(BSize :: non_neg_integer(), SHist :: shuffle_history()) ->
                         shuffle_history().
%% @pure
%% @private
%% @doc Clean-up old shuffle entries in <em>SHist</em> if the buffer contains
%%      more than <em>BSize</em> entries.
clear_shist(BSize, SHist) ->
    case length(SHist) >= BSize of
        true -> drop_oldest(SHist);
        false -> SHist
    end.

-spec drop_oldest(SHist :: shuffle_history()) -> shuffle_history().
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
