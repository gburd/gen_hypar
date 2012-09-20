%% @doc A connection layer on top of TCP for the use in hyparerl
%% @todo Should make this a gen_fsm

-module(connect).

-behaviour(gen_server).

%% API
-export([start_link/3, start_link/4]).

-export([initialize/1, stop/0, send/2, new_active/2, new_pending/2, new_temp/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("hyparerl.hrl").

-record(conn, {state=temp,
               id,
               lpeer,
               sock,
               data}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(ListenerPid, Socket, _Transport, [LID]) ->
    gen_server:start_link(?MODULE, [incoming, ListenerPid, LID, Socket], []).

start_link(Socket, RID, State) ->
    gen_server:start_link(?MODULE, [outgoing, Socket, RID, State], []).

initialize(LID) ->
    {IP, Port} = LID,
    ListenOpts = [{port,Port},{ip,IP},{keepalive, true}],
    {ok, _} = ranch:start_listener(tcp_conn, 100,
                                   ranch_tcp, ListenOpts,
                                   connect, [LID]).

stop() ->
    ranch:stop_listener(tcp_conn).

new_active(From, To) ->
    new_connection(From, To, active).

new_pending(From, To) ->
    new_connection(From, To, pending).

new_temp(From, To) ->
    new_connection(From, To, temp).

send(Peer, Msg) ->
    gen_server:call(Peer#peer.pid, Msg).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([incoming, ListenerPid, LID, Socket]) ->
    ok = ranch:accept_ack(ListenerPid),    
    ranch_tcp:setopts(Socket, [{active, once}]),
    {ok, #conn{state = temp,
               lpeer = #peer{id=LID,
                             pid=hypar_node},
               sock = Socket,
               data = <<>>}};
init([outgoing, Socket, LID, RID, State]) ->
    {ok, #conn{state  = State,
               id     = RID,
               lpeer  = #peer{id=LID,
                             pid=hypar_node},
               sock   = Socket,
               data   = <<>>}, 0}.

handle_call({disconnect, _},_ ,C=#conn{state=active}) ->
    ranch_tcp:close(C#conn.sock),
    {stop, normal, C};
handle_call({neighbour_accept, _}=Msg, _, C=#conn{state=pending}) ->
    Reply = ranch_tcp:send(C#conn.sock, encode(Msg)),
    {reply, Reply, C#conn{state=active}};
handle_call({forward_join_reply, _}=Msg, _, C=#conn{state=temp}) ->
    Reply = ranch_tcp:send(C#conn.sock, encode(Msg)),
    {reply, Reply, C#conn{state=active}};
handle_call(Msg, _, C) ->
    Reply = ranch_tcp:send(C#conn.sock, encode(Msg)),
    {reply, Reply, C}.

handle_cast(_, C) ->
    {stop, not_used, C}.

handle_info({tcp, _, Bin}, C=#conn{data=RemBin0}) ->
    {Packets, RemBin} = decode(<<RemBin0/binary, Bin/binary>>),
    handle_packets(Packets, C#conn{data=RemBin});

handle_info({tcp_closed, _}, C) ->
    case C#conn.state of
        active  -> hypar_node:disconnect(C#conn.lpeer, C#conn.id);
        pending -> hypar_node:error(C#conn.id, pending_disconnected);
        _ -> ok                  
    end, 
    {stop, normal, C};
handle_info({tcp_error, _, Reason}, C) ->
    case C#conn.state of
        active  -> hypar_node:error(C#conn.id, Reason);
        pending -> hypar_node:error(C#conn.id, Reason);
        temp -> ok
    end,
    {stop, normal, C};
handle_info(timeout, C=#conn{sock=Socket}) ->
    receive 
        {ok, Socket} -> {noreply, C}
    end.

terminate(_, _) ->
    ok.

code_change(_, C, _) ->
    {ok, C}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_packets([], C) ->
    C;
handle_packets([P|Ps], C0) ->
    C = handle_packet(P, C0),
    handle_packets(Ps, C).

handle_packet({neighbour_request, RID, _}=Msg, C=#conn{state=temp}) ->
    route_msg(Msg),
    C#conn{id=RID, state=pending};
handle_packet({neighbour_accept, _}=Msg, C=#conn{state=pending})->
    route_msg(Msg),
    C#conn{state=active};
handle_packet({forward_join_reply, RID}=Msg, C=#conn{state=temp})->
    route_msg(Msg),
    C#conn{id=RID, state=active};
handle_packet({join, _}=Msg, C=#conn{state=temp}) ->
    route_msg(Msg),
    C#conn{state=active};
handle_packet(Msg, C) ->
    route_msg(Msg),
    C.

route_msg(Msg) ->
    gen_server:call(hypar_node, Msg).

encode(Msg) ->
    Bin = erlang:term_to_binary(Msg),
    Len = erlang:byte_size(Bin),
    <<Len:32/big-unsigned-integer, Bin>>.

decode(Bin) ->
    {Chunks, RemBin} = packets(Bin, []),
    {lists:map(fun erlang:binary_to_term/1, Chunks), RemBin}.

packets(<<Len:32/big-unsigned-integer, Chunk/binary>>=Bin, Packets) ->
    case erlang:byte_size(Chunk) < Len of
        true ->
            {Packets, Bin};
        false ->
            <<Packet:Len/binary, RemBin/binary>> = Chunk,
            packets(RemBin, [Packet|Packets])
    end;
packets(Bin, Packets) ->
    {Packets, Bin}.

new_connection({LIP,_}, RID={RIP, RPort}, State) ->
    Args = [{ip, LIP}, {keepalive, true}],
    case ranch_tcp:connect(RIP, RPort, Args) of
        {ok, Socket} ->
            {ok, Pid} = ?MODULE:start_link(Socket, RID, State),
            Pid ! {ok, Socket},
            #peer{id=RID, pid=Pid};
        Err ->
            Err
    end.
