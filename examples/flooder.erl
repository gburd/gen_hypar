%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @private
%% @title Example gen_hypar process
%% @doc A very naive flooder as an example of a gen_hypar process
%% -------------------------------------------------------------------
-module(flooder).
-behaviour(gen_hypar).
-behaviour(gen_server).

%% Operations
-export([start_link/1, join/2, broadcast/2, local_id/1]).

%% gen_hypar callback
-export([start_link/2]).

%% gen_server callbacks
-export([init/1, handle_cast/2, handle_call/3, handle_info/2,
        code_change/3, terminate/2]).

%% State
-record(state, {id, received_messages=gb_sets:new(), peers=[]}).

%% A local identifier
local_id(Port) ->
    {{127,0,0,1}, Port}.

%% Start the flooder
start_link(Identifier) ->
    gen_hypar:start_link(Identifier, ?MODULE, [], []).

%% gen_hypar callback
start_link(Identifier, _) ->
    gen_server:start_link(?MODULE, [Identifier], []).

%% Broadcast a message
broadcast(Identifier, Message) ->
    gen_server:cast(gen_hypar:where(Identifier), {broadcast, Message}).

%% Join the flooder to a cluster
join(Identifier, Contact) ->
    gen_hypar:join_cluster(Identifier, Contact).

init([Identifier]) ->    
    gen_hypar:register_and_wait(Identifier),
    {ok, #state{id=Identifier}}.
   
handle_cast({broadcast, Packet}, S) ->
    MId = create_message_id(S#state.id, Packet),
    deliver(Packet),
    mcast(<<MId:20/binary, Packet/binary>>, S#state.peers),
    NewReceived = gb_sets:add(MId, S#state.received_messages),
    {noreply, S#state{received_messages=NewReceived}}.

handle_info({message, Sender, <<MId:20/binary, Packet/binary>> = HPacket}, S) ->
    case gb_sets:is_member(MId, S#state.received_messages) of
        true  ->
            {noreply, S};
        false ->
            deliver(Packet),
            send_to_all_but(HPacket, S#state.peers, Sender),
            NewReceived = gb_sets:add(MId, S#state.received_messages),
            {noreply, S#state{received_messages=NewReceived}}
    end;

handle_info({link_up, Peer}, S) ->
    {noreply, S#state{peers=[Peer|S#state.peers]}};

handle_info({link_down, PeerId},  S) ->
    {noreply, S#state{peers=lists:keydelete(PeerId, 1, S#state.peers)}}.

%% Delivery function
deliver(Packet) ->
    io:format("Packet deliviered:~n~p~n", [Packet]).

%% Internal
create_message_id(Id, Bin) ->
    BId = gen_hypar_util:encode_id(Id),
    crypto:sha(<<Bin/binary, BId/binary>>).

send_to_all_but(Packet, Peers, Peer) ->
    mcast(Packet, lists:keydelete(Peer, 1, Peers)).

mcast(Packet, Peers) ->
    [gen_hypar:send_message(Pid, Packet) || {_,Pid} <- Peers].

handle_call(_, _, S) ->
    {stop, not_used, S}.

code_change(_,_,_) -> ok.

terminate(_,_) -> ok.
