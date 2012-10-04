%% @todo Comments
-module(flooder).
-compile([export_all, debug_info]).
-behaviour(gen_server).

-include("hyparerl.hrl").
-export([init/1, handle_cast/2, handle_call/3, handle_info/2,
        code_change/3, terminate/2]).

-export([start_link/0, start_link/1, broadcast/1]).

-record(state, {id, received_messages=gb_sets:new(), peers=[]}).

start_link() ->
    ok = hyparerl:start([{mod, ?MODULE}]),
    {ok, _} = gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


start_link(ContactPort) ->
    {ok,If}=inet:getif(),
    {Ip,_,_} = hd(lists:keydelete({127,0,0,1}, 1, If)),
    Contact = {Ip, ContactPort},
    ok = hyparerl:start([{mod, ?MODULE}, {contact_nodes, [Contact]}]),
    {ok, _} = gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_peers() ->
    gen_server:call(?MODULE, get_peers).

broadcast(Packet) ->
    gen_server:cast(?MODULE, {broadcast, Packet}).

init([]) ->
    
    {ok, #state{id=hyparerl:get_id(), peers=hyparerl:get_peers()}}.

handle_cast({link_up, Peer}, S) ->
    {noreply, S#state{peers=[Peer|S#state.peers]}};

handle_cast({link_down, Peer},  S) ->
    {noreply, S#state{peers=lists:delete(Peer, S#state.peers)}};
    
handle_cast({broadcast, Packet}, S) ->
    MId = create_message_id(S#state.id, Packet),
    deliver(Packet),
    mcast(<<MId:20/binary, Packet/binary>>, S#state.peers),
    NewReceived = gb_sets:add(MId, S#state.received_messages),
    {noreply, S#state{received_messages=NewReceived}};

handle_cast({message, Sender, <<MId:20/binary, Packet/binary>> = HPacket}, S) ->
    case gb_sets:is_member(MId, S#state.received_messages) of
        true  ->
            {noreply, S};
        false ->
            deliver(Packet),
            send_to_all_but(HPacket, S#state.peers, Sender),
            NewReceived = gb_sets:add(MId, S#state.received_messages),
            {noreply, S#state{received_messages=NewReceived}}
    end.

handle_call(get_peers,_,S) ->
    {reply, S#state.peers, S}.

handle_info(_, S) ->
    {stop, not_used, S}.

%% Delivery function
deliver(Packet) ->
    io:format("Packet deliviered:~n~p~n", [Packet]).

%% Hyparerl callbacks
deliver(Id, Bin) ->
    gen_server:cast(?MODULE, {message, Id, Bin}).

link_up(Peer) ->
    gen_server:cast(?MODULE, {link_up, Peer}).

link_down(Peer) ->
    gen_server:cast(?MODULE, {link_down, Peer}).


%% Internal
create_message_id(Id, Bin) ->
    BId = hyparerl:encode_id(Id),
    crypto:sha(<<Bin/binary, BId/binary>>).

send_to_all_but(Packet, Peers, Peer) ->
    mcast(Packet, lists:delete(Peer, Peers)).

mcast(Packet, Peers) ->
    [hyparerl:send(P, Packet) || P <- Peers].

code_change(_,_,_) -> ok.

terminate(_,_) -> ok.
