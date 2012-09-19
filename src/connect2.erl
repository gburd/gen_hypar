-module(connect2).

-behaviour(gen_server).

%% API
-export([start_link/3, start_link/4]).

-export([initialize/1, new_connection/2, new_temp_connection/2, disconnect/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("hyparerl.hrl").

-record(conn, {state=temporary,
               remote_id,
               sock,
               data}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(ListenerPid, Socket, _Transport, []) ->
    gen_server:start_link(?MODULE, [incoming, ListenerPid, Socket], []).

start_link(Socket, RID, State) ->
    gen_server:start_link(?MODULE, [outgoing, Socket, RID, State], []).

initialize(LID) ->
    {IP, Port} = LID,
    ListenOpts = [{port,Port},{ip,IP},{keepalive, true}],
    {ok, _} = ranch:start_listener(tcp_conn, 100,
                                   ranch_tcp, ListenOpts,
                                   connect, []).

new_connection(From, To) ->
    new_connection(From, To, normal).

new_temp_connection(From, To) ->
    new_connection(From, To, temporary).

send_message(#peer{pid=Pid}, Msg) ->
    gen_server:call(Pid, {send_message, Msg}).

disconnect(#peer{pid=Pid}) ->
    gen_server:call(Pid, disconnect).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([incoming, ListenerPid, Socket]) ->
    ok = ranch:accept_ack(ListenerPid),    
    ranch_tcp:setopts(Socket, [{active, once}]),
    {ok, #conn{sock = Socket,
               data = <<>>}};
init([outgoing, Socket, RID, State]) ->
    {ok, #conn{state     = State,
               remote_id = RID,
               sock      = Socket,
               data      = <<>>}, 0}.

handle_call({send_message, Msg}, _, C) ->
    Bin0 = erlang:term_to_binary(Msg),
    Len = erlang:byte_size(Bin0),
    Bin = <<Len:32/big-unsigned-integer, Bin0/binary>>,
    ok = ranch_tcp:send(C#conn.sock, Bin),
    {reply, ok, C};
handle_call(disconnect, _, C) ->
    ranch_tcp:close(C#conn.sock),
    {stop, normal, C};
handle_call(_, _, C) ->
    {stop, not_used, C}.

handle_cast(_, C) ->
    {stop, not_used, C}.

handle_info({tcp, Socket, Bin}, C0=#conn{data=RemBin}) ->
    {Packets, RemBin} = decode(<<RemBin/binary, Bin/binary>>),
    lists:foreach(fun map_fun/1, Packets),
    C#conn{data=RemBin};
handle_info({tcp_closed, _}, C) ->
    case C#conn.state =:= normal of
        true -> hypar_node:disconnect(C#conn.remote_id)
    end,        
    {stop, normal, C};
handle_info({tcp_error, _, Reason}, C) ->
    case C#conn.state =:= normal of
        true -> hypar_node:error(C#conn.remote_id, Reason)
    end,
    {stop, normal, C};
handle_info(timeout, C) ->
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
