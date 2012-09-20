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

%% Peer related
-export([get_peers/0, get_passive_peers/0, get_pending_peers/0,
         get_all_peers/0]).

%% Events
-export([join/2, forward_join/4, forward_join_reply/2,
         neighbour_request/3, neighbour_accept/2, neighbour_decline/2,
         shuffle_request/6, shuffle_reply/3, error/2]).

%% Send related
-export([]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%%%%%%%%%%
%% State %%
%%%%%%%%%%%

-record(st, {id                :: id(),           %% This nodes identifier
             activev           :: list(#peer{}),  %% The active view
             passivev          :: list(id()),     %% The passive view
             pendingv = []     :: list(#peer{}),  %% The pending view (current neighbour requests)
             shuffle_hist = [] :: list(shuffle_ent()), %% History of shuffle requests sent
             opts = []         :: list(proplists:property()), %% Options
             notify            :: pid() | atom(), %% Notify process with link_up/link_down
             rec               :: pid() | atom()  %% Process that receives messages
            }).

%%%%%%%%%
%% API %%
%%%%%%%%%

%%%%%%%%%%%%%%%%
%% Operations %%
%%%%%%%%%%%%%%%%

-spec start_link(Options :: list(proplists:property())) -> 
                        {ok, pid()} | ignore | {error, any()}.
%% @doc Start the <b>hypar_node</b> with <em>Options</em>.
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

-spec stop() -> ok.
%% @doc Stop the <b>hypar_node</b>.
stop() ->
    gen_server:call(?MODULE, stop).

-spec join_cluster(ContactNode :: id()) -> view_change() | {error, any()}.
%% @doc Let the <b>hypar_node</b> join a cluster via <em>ContactNode</em>.
%%      The return value is the view changes.
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

-spec get_peers() -> view().
%% @doc Get all the current active peers.
get_peers() ->
    gen_server:call(?MODULE, get_peers).

-spec get_passive_peers() -> view().
%% @doc Get all the current passive peers.
get_passive_peers() ->
    gen_server:call(?MODULE, get_passive_peers).

-spec get_pending_peers() -> view().
%% @doc Get all current pending peers
get_pending_peers() ->
    gen_server:call(?MODULE, get_pending_peers).

-spec get_all_peers() -> {view(), view(), view()}.
%% @doc Get all the current peers
get_all_peers() ->
    gen_server:call(?MODULE, get_all_peers).

%%%%%%%%%%%%
%% Events %%
%%%%%%%%%%%%

-spec join(Peer :: #peer{}, Sender :: id()) -> ok | view_change().
%% @doc Join <em>Sender</em> to the <em>Peer</em>. If <em>Peer</em> is
%%      <b>hypar_node</b> it will return the potential disconnect.
join(Peer, Sender) ->
    connect:send(Peer, join_msg(Sender)).

-spec forward_join(Peer :: #peer{}, Sender :: id(), NewNode :: id(),
                   TTL :: non_neg_integer()) ->
                          ok | view_change() | {error, any()}.
%% @doc Forward join <em>NewNode</em> from <em>Sender</em> to the <em>Peer</em>
%%      with time to live <em>TTL</em>. If <em>Peer</em> is <b>hypar_node</b> it
%%      will return the potential disconnect.
forward_join(Peer, Sender, NewNode, TTL) ->
    connect:send(Peer, forward_join_msg(Sender, NewNode, TTL)).

-spec forward_join_reply(Peer :: #peer{}, Sender :: id()) -> ok | view_change().
%% @doc Forward join reply <em>Sender</em> to the <b>hypar_node</b>. If
%%      <em>Peer</em> is <b>hypar_node</b> it will return the potential
%%      disconnect.
forward_join_reply(Peer, Sender) ->
    connect:send(Peer, forward_join_reply_msg(Sender)).

-spec neighbour_request(Peer :: #peer{}, Sender :: id(),
                        Priority :: priority()) -> ok | view_change().
%% @doc Neighbour request from <em>Sender</em> to <em>Peer</em> with
%%      <em>Priority</em>. If <em>Peer</em> is <b>hypar_node</b> it will return
%%      the potential disconnect.
neighbour_request(Peer, Sender, Priority) ->
    connect:send(Peer, neighbour_request_msg(Sender, Priority)).

-spec neighbour_accept(Peer :: #peer{}, Sender :: id()) ->
                              ok | view_change().
%% @doc Accept a neighbour request from <em>Sender</em> to <b>Peer</b>. If
%%      <em>Peer</em> is <b>hypar_node</b> it will return the potential
%%      disconnect.
neighbour_accept(Peer, Sender) ->
    connect:send(Peer, neighbour_accept_msg(Sender)).

-spec neighbour_decline(Peer :: #peer{}, Sender :: id()) ->
                               ok | id() | no_peer | {error, any()}.
%% @doc Decline a neighbour request from Sender to <em>Peer</em>. If
%%      <em>Peer</em> is <b>hypar_node</b> it will return the new potential
%%      neighbour or no_peer if no valid peers exist.
neighbour_decline(Peer, Sender) ->
    connect:send(Peer, neighbour_decline_msg(Sender)).

-spec shuffle_request(Peer :: #peer{}, Sender :: id(), Requester :: id(),
                      XList :: list(id()), TTL :: non_neg_integer(),
                      Ref :: reference()) -> ok | {error, any()}.
%% @doc Shuffle request from <em>Sender</em> to <em>Peer</em>. The shuffle
%%      request originated in node <em>Requester</em> and <em>XList</em>
%%      contains sample node identifiers. The message has a time to live of
%%      <em>TTL</em> and is tagged by the reference <em>Ref</em>. 
shuffle_request(Peer, Sender, Requester, XList, TTL, Ref) ->
    connect:send(Peer,
                    shuffle_request_msg(Sender, Requester, XList, TTL, Ref)).

-spec shuffle_reply(Peer :: #peer{}, ReplyXList :: list(id()),
                    Ref :: reference()) -> ok | view_change().
%% @doc Shuffle reply to shuffle request with reference <em>Ref</em> sent to
%%      <em>Peer</em> that carries the sample list <em>ReplyXList</em>.
shuffle_reply(Peer, ReplyXList, Ref) ->
    connect:send(Peer, shuffle_reply_msg(ReplyXList, Ref)).

-spec disconnect(Peer :: #peer{}, Sender :: id()) -> ok.
%% @doc Disconnect <em>Peer</em> from <em>Sender</em>. 
disconnect(Peer, Sender) ->
    connect:send(Peer, {disconnect, Sender}).

-spec error(Sender :: id(), Reason :: any()) ->
                   id() | no_peer | {error, any()}.
%% @doc Let the <b>hypar_node</b> know that <em>Sender</em> has failed
%%      with <em>Reason</em>. Returns the new potential neighbour or
%%      no_peer if no valid peers exist.
error(Sender, Reason) ->
    connect:send(?MODULE, {error, Sender, Reason}).

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
shuffle_reply_msg(XList, Ref) ->
    {shuffle_reply, XList, Ref}.

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
             rec      = Receiver}}.

%% Join a cluster via a given contact-node
handle_call({join_cluster, ContactNode}, _, S0=#st{id=ThisNode}) ->
    case lists:keyfind(ContactNode, #peer.id, S0#st.activev) of
        undefined ->            
            case connect:new_active(ThisNode, ContactNode) of
                {error, Err} ->
                    lager:error("Join cluster via ~p failed with error ~p",
                                [ContactNode, Err]),
                    {reply, {error, Err}, S0};
                P ->
                    ok = join(P, ThisNode),
                    {Disc, S} = add_node_active(P, S0),
                    {reply, Disc, S}
            end;
        P -> 
            lager:info("Attempting to join via existing peer ~p", [P]),
            {reply, {error, already_in_active_view}, S0}
    end;

%% Add newly joined node to active view, propagate a forward join
handle_call({join, P}, _, S0) ->
    {Disc, S} = add_node_active(P, S0),

    %% Send forward joins
    ARWL = proplists:get_value(arwl, S#st.opts),

    ForwardFun = fun(X) -> ok = forward_join(X, S#st.id, P#peer.id, ARWL) end,
    FilterFun  = fun(X) -> X#peer.id =/= P#peer.id end,
    ForwardNodes = lists:filter(FilterFun, S#st.activev),
    
    lists:foreach(ForwardFun, ForwardNodes),

    {reply, Disc, S};

%% Respond to a forward_join, add to active or propagate and maybe add to
%% passive view.
handle_call({forward_join, Sender, NewNode, TTL}, _, S0) ->
    case TTL =:= 0 orelse length(S0#st.activev) =:= 1 of 
        true ->
            %% Add to active view, send a reply to the forward_join to let the
            %% other node know
            case connect:new_active(S0#st.id, NewNode) of
                {error, Err} ->
                    lager:error("Reply to forward join from ~p failed with error ~p",
                                [NewNode, Err]),
                    {reply, {error, Err}, S0};
                P ->
                    ok = forward_join_reply(P, S0#st.id),
                    {Disc, S} = add_node_active(P, S0),
                    {reply, Disc, S}
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
            
            ok = forward_join(P, S1#st.id, NewNode, TTL-1),
            {reply, no_disconnect, S1}
    end;

%% Accept a connection from the join procedure
handle_call({forward_join_reply, P},_ , S0) ->
    {Disc, S} = add_node_active(P, S0),
    {reply, Disc, S};

%% Disconnect an open active connection, add disconnecting node to passive view
handle_call({disconnect, Sender}, _, S0) ->
    P = lists:keyfind(Sender, #peer.id, S0#st.activev),
    %% Disconnect the peer, close the connection and add node to passive view
    ActiveV = lists:keydelete(P#peer.id, #peer.id, S0#st.activev),
    neighbour_down(S0#st.notify, P#peer.id),
    S = add_node_passive(P#peer.id, S0#st{activev=ActiveV}),
    {reply, ok, S};

%% Respond to a neighbour request, either accept or decline based on priority
%% and current active view
handle_call({neighbour_request, P, Priority},_ , S0) ->
    case Priority of
        %% High priority neighbour request thus the node needs to accept the
        %% request what ever the current active view is
        high ->
            lager:info("Accepted high priority neighbour request from ~p",
                       [P]),
            ok = neighbour_accept(P, S0#st.id),
            {Disc, S} = add_node_active(P, S0),
            {reply, Disc, S};
        %% Low priority request, only accept if we have space in the
        %% nodes active view
        low ->
            ActiveSize = proplists:get_value(active_size, S0#st.opts),
            case length(S0#st.activev) < ActiveSize of
                true ->
                    ok = neighbour_accept(P, S0#st.id),
                    {Disc, S} = add_node_active(P, S0),
                    {reply, Disc, S};
                false ->
                    lager:info("Declined neighbour request from ~p due to space",
                               [P]),
                    ok = neighbour_decline(P, S0#st.id),
                    {reply, no_disconnect, S0}
            end
    end;

%% A neighbour request has been accepted, add to active view
handle_call({neighbour_accept, Sender},_ , S0) ->
    %% Remove the request from the request history
    P = lists:keyfind(Sender, #peer.id, S0#st.pendingv),
    PendingV = lists:keydelete(Sender, #peer.id, S0#st.pendingv),
    {Disc, S} = add_node_active(P, S0#st{pendingv=PendingV}),
    {reply, Disc, S};

%% A neighbour request has been declined, find a new one
handle_call({neighbour_decline, Sender}, _, S0) ->
    %% Remove the request
    P = lists:keyfind(Sender, #peer.id, S0#st.pendingv),
    PendingV = lists:keydelete(P#peer.id, #peer.id, S0#st.pendingv),
    {P, S} = find_new_active(S0#st{pendingv=PendingV}),
    {reply, P, S#st{passivev=[Sender|S#st.passivev]}};

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
            
            ok = shuffle_request(P, S0#st.id, Requester, XList, TTL-1, Ref),
            {reply, ok, S0};
        %% Accept the shuffle request, add to passive view and reply
        false ->
            N = length(XList),
            ReplyXList = misc:take_n_random(N, S0#st.passivev),
            case connect:new_temp(S0#st.id, Requester) of
                {error, Err} ->
                    lager:error("Shuffle reply to ~p failed with error ~p",
                                [Requester, Err]),
                    {reply, {error, Err}, S0};
                P ->
                    ok = shuffle_reply(P, ReplyXList, Ref),
                    S = add_xlist(XList, ReplyXList, S0),
                    {reply, ok, S}
            end
    end;

%% Accept a shuffle reply, add the reply list into the passive view and
%% close the temporary connection.
handle_call({shuffle_reply, ReplyXList, Ref}, _, S0) ->
    case lists:keyfind(Ref, 1, S0#st.shuffle_hist) of
        %% Clean up the shuffle history, add the reply list to passive view
        {Ref, XList, _} ->
            ShuffleHist = lists:keydelete(Ref, 1, S0#st.shuffle_hist),
            S = add_xlist(ReplyXList, XList, S0),
            {reply, ok, S#st{shuffle_hist=ShuffleHist}};
        %% Stale data or something buggy
        false ->
            lager:info("Stale shuffle reply received, ignoring."),
            {reply, stale, S0}
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
    
    {NP, S} = find_new_active(S1),
    {reply, NP, S};

%% Return current active peers
handle_call(get_peers, _, S) ->
    ActiveV = [P#peer.id || P <- S#st.activev],
    {reply, ActiveV, S};

%% Return current passive peers
handle_call(get_passive_peers, _, S) ->
    {reply, S#st.passivev, S};

%% Return current pending peers
handle_call(get_pending_peers, _, S) ->
    PendingV = [P#peer.id || P <- S#st.pendingv],
    {reply, PendingV, S};

%% Return all peers
handle_call(get_all_peers, _, S) ->
    #st{activev=ActiveV0, passivev=PassiveV, pendingv=PendingV0} = S,
    ActiveV  = [P#peer.id || P <- ActiveV0],
    PendingV = [P#peer.id || P <- PendingV0],
    {reply, {ActiveV, PassiveV, PendingV}, S};

%% Stop the hypar_node
handle_call(stop, _, S) ->
    lists:foreach(fun(P) -> erlang:unlink(P#peer.pid) end,
                  S#st.activev ++ S#st.pendingv),
    connect:stop(),
    {stop, normal, ok, S}.

%% Timer message for periodic shuffle. Send of a shuffle request to a random
%% peer in the active view. Ignore if we don't have any active connections.     
handle_info(shuffle_time, S0) ->
    ShuffleHist = 
        case S0#st.activev =:= [] of
            true ->
                S0#st.shuffle_hist;
            false ->
                XList = create_xlist(S0),
                P = misc:random_elem(S0#st.activev),
                
                ARWL = proplists:get_value(arwl, S0#st.opts),
                Ref = erlang:make_ref(),
                Now = erlang:now(),
                New = {Ref, XList, Now},
                shuffle_request(P, S0#st.id, S0#st.id, XList, ARWL-1, Ref),
                [New|S0#st.shuffle_hist]
        end,
    
    start_shuffle_timer(S0#st.opts),

    %% Cleanup shuffle history and add new shuffle
    S = clear_shuffle_history(S0#st{shuffle_hist=ShuffleHist}),
    {noreply, S}.

handle_cast(_,S) ->
    {stop, not_used, S}.

code_change(_, S, _) ->
    {ok, S}.

terminate(_, S) ->
    lists:foreach(fun(P) ->
                          erlang:unlink(P#peer.pid),
                          erlang:exit(P#peer.pid, terminate)
                  end, S#st.activev ++ S#st.pendingv),
    connect:stop().

%% Internal

-spec clear_shuffle_history(S :: #st{}) -> #st{}.
%% @private
%% @doc Clean-up old shuffle entries
clear_shuffle_history(S) ->
    ShuffleBuffer = proplists:get_value(shuffle_buffer, S#st.opts),

    case length(S#st.shuffle_hist) >= ShuffleBuffer of
        true ->
            ShuffleHist = drop_oldest(S#st.shuffle_hist),
            S#st{shuffle_hist=ShuffleHist};
        false ->
            S
    end.

-spec drop_oldest(List :: list(shuffle_ent())) -> list(shuffle_ent()).
drop_oldest(ShuffleHist) ->
    tl(lists:usort(fun({_,_,T1}, {_,_,T2}) -> T1 < T2 end, ShuffleHist)).

-spec start_shuffle_timer(Opts :: list(proplists:property())) -> ok.           
%% @private
%% @doc Start the shuffle timer
start_shuffle_timer(Options) ->
    case proplists:get_value(shuffle_period, Options) of
        undefined     ->
            ok;
        ShufflePeriod ->
            erlang:send_after(ShufflePeriod, self(), shuffle_time),
            ok
    end.

%% @doc Add a node to an active view, removing a node if necessary.
%%      The new state is returned. If a node has to be dropped, then
%%      it is informed via a DISCONNECT message.
add_node_active(Peer, S0) ->
    case Peer#peer.id =/= S0#st.id andalso
        not lists:keymember(Peer#peer.id, #peer.id, S0#st.activev) of
        true ->
            ActiveSize = proplists:get_value(active_size, S0#st.opts),
            {Disc, S} =
                case length(S0#st.activev) >= ActiveSize of
                    true  -> drop_random_active(S0);
                    false -> {no_disconnect, S0}
                end,
            %% Notify link change
            neighbour_up(S0#st.notify, Peer#peer.id),
            {Disc, S#st{activev=[Peer|S#st.activev]}};
        false ->
            {no_disconnect, S0}
    end.

%% @doc Add a node to the passive view, removing random entries if needed
add_node_passive(Node, S) ->
    case Node =/= S#st.id andalso
        not lists:keymember(Node, #peer.id, S#st.activev) andalso
        not lists:member(Node, S#st.passivev) of
        true -> 
            PassiveSize = proplists:get_value(passive_size, S#st.opts),
            N = length(S#st.passivev),
            {_, PassiveV} = 
                case N >= PassiveSize of
                    true ->  misc:drop_random(S#st.passivev, N-PassiveSize+1);
                    false -> {[], S#st.passivev}
            end,
            S#st{passivev=[Node|PassiveV]};
        false ->
            S
    end.

%% @private
%% @doc Drop a random node from the active view down to the passive view.
%%      Send a DISCONNECT message to the dropped node.
%% @todo Here I use add_node_passive. This isn't done in the paper.
%%       Because of this the size constraint on the passive size might
%%       be violated. I opt to just use add_node_passive since I don't
%%       think it matter. Should be noted though, might be that it does
%%       matter.
drop_random_active(S) ->
    PassiveSize = proplists:get_value(passive_size, S#st.opts),
    PassiveV = S#st.passivev,
    PassiveL = length(PassiveV),
    {Peer, ActiveV} = misc:drop_random(S#st.activev),
    PassiveV = free_slots(PassiveL-PassiveSize+1, PassiveV),

    disconnect(Peer, S#st.id),
    neighbour_down(S#st.notify, Peer#peer.id),
    {Peer#peer.id, S#st{activev=ActiveV, passivev=[Peer#peer.id|PassiveV]}}.

%% @doc Create the exchange list used in a shuffle.
create_xlist(S) ->
    KActive = proplists:get_value(k_active, S#st.opts),
    KPassive = proplists:get_value(k_passive, S#st.opts),

    ActiveV = lists:map(fun(P) -> P#peer.id end, S#st.activev),
    
    RandomActive  = misc:take_n_random(KActive, ActiveV),
    RandomPassive = misc:take_n_random(KPassive, S#st.passivev),
    [S#st.id | (RandomActive ++ RandomPassive)].

%% @doc Takes the exchange-list and adds it into the state. Removes nodes
%%      that are already in active/passive view from the list. If the passive
%%      view are full, start by dropping elements from ReplyList then random
%%      elements.
add_xlist(S, XList0, ReplyL) ->
    PassiveSize = proplists:get_value(passive_size, S#st.opts),
    
    Filter = fun(Node) ->
                     Node =/= S#st.id andalso
                         not lists:keymember(Node, #peer.id, S#st.activev) andalso
                         not lists:member(Node, S#st.passivev)
             end,
    XList = lists:filter(Filter, XList0),

    PassiveV = free_slots(length(S#st.passivev)-PassiveSize+length(XList),
                          S#st.passivev, ReplyL),

    S#st{passivev=XList ++ PassiveV}.

free_slots(N, List) ->
    free_slots(N, List, []).

%% @doc Free up slots in the List, start by removing elements
%%      from the RemoveFirst, then remove at random. Return the
%%      removed elements aswell as the new list.
free_slots(I, List, _RemoveFirst) when I =< 0 ->
    List;
free_slots(I, List, []) ->
    {L, _} = misc:drop_n_random(I, List),
    L;
free_slots(I, List, [Remove|RemoveFirst]) ->
    case lists:member(Remove, List) of
        true  -> free_slots(I-1, lists:delete(Remove, List), RemoveFirst);
        false -> free_slots(I, List, RemoveFirst)
    end.

%% @doc When a node is thought to have died this function is called.
%%      It will recursively try to find a new neighbour from the passive
%%      view until it finds a good one, send that node an asynchronous
%%      neighbour request and logs the request in the state.
find_new_active(S) ->
    Priority = get_priority(S#st.activev ++ S#st.pendingv),

    case find_neighbour(Priority, S#st.passivev, S#st.id) of
        {Peer, PassiveDrops, PassiveV} ->
            lager:info("Found potential neighbour ~p.", [Peer]),
            {{Peer, PassiveDrops}, S#st{passivev=PassiveV,
                                        pendingv=[Peer|S#st.pendingv]}};
        false ->
            lager:error("Could not find any peers to connect to in passive view."),
            {{no_peer, S#st.passivev}, S#st{passivev=[]}}
    end.

find_neighbour(Priority, Passive, ThisNode) ->
    find_neighbour(Priority, Passive, ThisNode, []).

find_neighbour(_, [], _, _) ->
    false;
find_neighbour(Priority, Passive0, ThisNode, Tried) ->
    {Node, Passive} = misc:drop_random(Passive0),
    case connect:new_pending(ThisNode, Node) of
        {error, Err} ->
            lager:error("Potential neighbour ~p is unreachable with error ~p",
                        [Node, Err]),
            find_neighbour(Priority, Passive, ThisNode, [Node|Tried]);
        P ->
            ok = neighbour_request(P, ThisNode, Priority),
            {P, Tried, Passive}
    end.

%% @pure
%% @doc Find the priority of a new neighbour. If no active entries exist
%%      the priority is high, otherwise low.
get_priority([]) -> high;
get_priority(_)  -> low.
