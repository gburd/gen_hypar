-module(flooder).

-compile([export_all]).

-behaviour(gen_server).

-record(state, {id, received_messages=[], peers=[]}).

start(Port) ->
    hyparerl:start_local(Port, ?MODULE),
    gen_server:start({local, ?MODULE}, ?MODULE, [{{127,0,0,1},Port}], []).

start(Port, ContactPort) ->
    start(Port),
    join(ContactPort).

join(Port) ->
    hyparerl:join_cluster({{127,0,0,1}, Port}).

init([Id]) ->
    {ok, #state{id=Id}}.

handle_cast({message, From, HPacket}, S) ->
    {MId, Packet} = strap_header(HPacket),
    case lists:member(MId, S#state.received_messages) of
        true ->
            io:format("Received redundant message: ~p ~n", [MId]),
            {noreply, S};
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
    multi_send(HPacket, S#state.peers),
    NewReceived = [MId|S#state.received_messages],
    {noreply, S#state{received_messages=NewReceived}}.

deliver(Packet) ->
    io:format("Packet deliviered:~n~p~n", [Packet]).

create_message_id(Id, Bin) ->
    BNow = term_to_binary(now()),
    BId = hyparerl:encode_id(Id),
    crypto:sha(<<BNow, BId, Bin>>).

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
