-module(flooder).

-compile([export_all, debug_info]).

-behaviour(gen_server).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2,
        code_change/3, terminate/2]).

-export([start_link/1, start_link/2, join/1, broadcast/1]).

-record(state, {id, received_messages=[], peers=[]}).

-define(CLUSTER, flood_cluster).

start_link(Port) ->
    Id = {{127,0,0,1},Port},
    hyparerl:start(),    
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Id], []),
    hyparerl:start_cluster(?CLUSTER, Id, ?MODULE, []).

start_link(Port, ContactPort) ->
    Ip = {127,0,0,1},
    Id = {Ip,Port},
    ContactNode = {Ip, ContactPort},
    hyparerl:start(),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Id], []),
    hyparerl:start_cluster(?CLUSTER, Id, ?MODULE, [], [ContactNode]).

join(Port) ->
    hyparerl:join_cluster(?CLUSTER, {{127,0,0,1}, Port}).

broadcast(Packet) ->
    gen_server:cast(?MODULE, {broadcast, Packet}).

init([Id]) ->
    {ok, #state{id=Id}}.

handle_call({link_up, Id, Conn},_, S) ->
    {reply, ok, S#state{peers=[{Id, Conn}|S#state.peers]}};

handle_call({link_down, Id}, _, S) ->
    {reply, ok, S#state{peers=lists:keydelete(Id, 1, S#state.peers)}}.
    
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

handle_info(_, S) ->
    {stop, not_used, S}.

deliver(Packet) ->
    io:format("Packet deliviered:~n~p~n", [Packet]).


%% Hyparerl callbacks
deliver(Id, Bin) ->
    gen_server:cast(?MODULE, {message, Id, Bin}).

link_up(To, Conn) ->
    gen_server:call(?MODULE, {link_up, To, Conn}).

link_down(To) ->
    gen_server:call(?MODULE, {link_down, To}).

create_message_id(Id, Bin) ->
    BNow = term_to_binary(now()),
    BId = hyparerl:encode_id(Id),
    crypto:sha(<<BNow/binary, BId/binary, Bin/binary>>).

header(MId, Payload) ->
    <<MId/binary, Payload/binary>>.

strap_header(<<MId:20/binary, Packet/binary>>) ->
    {MId, Packet}.

multi_send([], _Packet) ->
    ok;
multi_send([{_,C}|Peers], Packet) ->
    hyparerl:send(C, Packet),
    multi_send(Peers, Packet).

code_change(_,_,_) -> ok.

terminate(_,_) -> ok.
