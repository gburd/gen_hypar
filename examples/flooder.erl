-module(flooder).
-compile([export_all, debug_info]).
-behaviour(gen_server).

-include("hyparerl.hrl").
-export([init/1, handle_cast/2, handle_call/3, handle_info/2,
        code_change/3, terminate/2]).

-export([start_link/1, start_link/2, broadcast/1]).

-record(state, {id, received_messages=[], peers=[]}).

start_link(Port) ->
    Id = {{127,0,0,1},Port},
    {ok, Pid} = gen_server:start_link({local, ?MODULE}, ?MODULE, [Id], []),
    hyparerl:start(Id, ?MODULE),
    {ok, Pid}.

start_link(Port, ContactPort) ->
    Ip = {127,0,0,1},
    Id = {Ip,Port},
    ContactNode = {Ip, ContactPort},
    {ok, Pid} = gen_server:start_link({local, ?MODULE}, ?MODULE, [Id], []),
    hyparerl:start(Id, ?MODULE, [ContactNode]),
    {ok, Pid}.

broadcast(Packet) ->
    gen_server:cast(?MODULE, {broadcast, Packet}).

init([Id]) ->
    {ok, #state{id=Id}}.

handle_cast({link_up, Peer}, S) ->
    {noreply, S#state{peers=[Peer|S#state.peers]}};

handle_cast({link_down, Id},  S) ->
    {noreply, S#state{peers=lists:keydelete(Id, #peer.id, S#state.peers)}};
    
handle_cast({broadcast, Packet}, S) ->
    MId = create_message_id(S#state.id, Packet),
    deliver(Packet),
    HPacket = header(MId, Packet),
    multi_send(S#state.peers, HPacket),
    NewReceived = [MId|S#state.received_messages],
    {noreply, S#state{received_messages=NewReceived}};

handle_cast({message, From, HPacket}, S) ->
    {MId, Packet} = strap_header(HPacket),
    case lists:member(MId, S#state.received_messages) of
        true  -> {noreply, S};
        false ->
            deliver(Packet),
            AllButFrom = lists:keydelete(From, 1, S#state.peers),
            multi_send(AllButFrom, HPacket),
            NewReceived = [MId|S#state.received_messages],
            {noreply, S#state{received_messages=NewReceived}}
    end.

handle_call(_,_,S) ->
    {stop, not_used, S}.

handle_info(_, S) ->
    {stop, not_used, S}.

deliver(Packet) ->
    io:format("Packet deliviered:~n~p~n", [Packet]).

%% Hyparerl callbacks
deliver(Id, Bin) ->
    gen_server:cast(?MODULE, {message, Id, Bin}).

link_up(Peer) ->
    gen_server:cast(?MODULE, {link_up, Peer}).

link_down(To) ->
    gen_server:cast(?MODULE, {link_down, To}).

create_message_id(Id, Bin) ->
    BNow = term_to_binary(now()),
    BId = hyparerl:encode_id(Id),
    crypto:sha(<<BNow/binary, BId/binary, Bin/binary>>).

header(MId, Payload) ->
    <<MId/binary, Payload/binary>>.

strap_header(<<MId:20/binary, Packet/binary>>) ->
    {MId, Packet}.

multi_send(Peers, Packet) ->
    lists:foreach(fun(P) -> hyparerl:send(P, Packet) end, Peers).

code_change(_,_,_) -> ok.

terminate(_,_) -> ok.
