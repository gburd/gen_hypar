-module(flooder).

-compile([export_all, debug_info]).

-behaviour(gen_server).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2,
        code_change/3, terminate/2]).

-export([start/1, start/2, join/1, broadcast/1]).

-record(state, {id, received_messages=[], peers=[]}).

start(Port) ->
    hyparerl:start_local(Port, ?MODULE),
    gen_server:start({local, ?MODULE}, ?MODULE, [{{127,0,0,1},Port}], []).

start(Port, ContactPort) ->
    start(Port),
    join(ContactPort).

join(Port) ->
    hyparerl:join_cluster({{127,0,0,1}, Port}).

broadcast(Packet) ->
    gen_server:cast(?MODULE, {broadcast, Packet}).

init([Id]) ->
    {ok, #state{id=Id}}.

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
    end;

handle_cast({link_up, Id, Conn}, S) ->
    {noreply, S#state{peers=[{Id, Conn}|S#state.peers]}};

handle_cast({link_down, Id}, S) ->
    {noreply, S#state{peers=lists:keydelete(Id, 1, S#state.peers)}};
    
handle_cast({broadcast, Packet}, S) ->
    MId = create_message_id(S#state.id, Packet),
    deliver(Packet),
    HPacket = header(MId, Packet),
    multi_send(S#state.peers, HPacket),
    NewReceived = [MId|S#state.received_messages],
    {noreply, S#state{received_messages=NewReceived}}.

handle_info(_, S) ->
    {stop, not_used, S}.

deliver(Packet) ->
    io:format("Packet deliviered:~n~p~n", [Packet]).

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

handle_call(_,_,S) -> {stop, unused, S}.

terminate(_,_) -> ok.
