%% @private
%% @doc A connection layer on top of TCP for the use in hyparerl
%%
%%      =Binary formats=
%%      All messages sent as first contact(join, forward_join_reply, neighbour
%%      requests and shuffle replys have basically the same format:
%%      <<?MSG_TYPE, Id:48>>
%%      ==Identifier=
%%      encode_id({{A, B, C, D}, Port}) = <<A, B, C, D, Port:16/integer>>
%%      (6 bytes)
%%      ==Join==
%%      <<?JOIN, Port:16/integer>>
%%      Only the Port is sent, the IP is grabbed via the socket
%%      ==Forward join== 
%%      <<?FORWARDJOIN, Req:6/binary, TTL/integer>>
%%      ==Join reply==
%%      <<?JOINREPLY, Port:16/integer>>
%%      See join.
%%      ==High priority neighbour request==
%%      <<?HNEIGHBOUR, Port:16/integer>>
%%      ==Low priority neighbour request==
%%      <<?LNEIGHBOUR, Port:16/integer>>
%%      ==Neighbour accept/decline==
%%      Accept:  <<?ACCEPT>>
%%      Decline: <<?DECLINE>>
%%      ==Disconnect==
%%      <<?DISCONNECT>>
%%      ==Shuffle==
%%      <<?SHUFFLE, BReq:6/binary, TTL/integer, Len/integer, XList/binary>>
%%      ==Shuffle reply==
%%      Len is 16 bits for convinience
%%      <<?SHUFFLEREPLY, Len:16/integer, XList/binary>>
%%
%% @todo
%%      Because of the format of the protocol some configuration parameters
%%      have become restricted. I do not think that it imposes any problem.
%%      Should implement a sanity check on the options when starting the
%%      application.
%%
%%      I tried to use socket close as the disconnect operation. But I do not
%%      think that it operates correctly due to OS-specific/erts reasons. When
%%      a process dies for example a close is done, I would want that to be a
%%      tcp_error. I change this to a DISCONNECT-byte and consider closes to be
%%      errors, as far as the hypar_node cares atleast.
-module(connect).

-behaviour(ranch_protocol).
-behaviour(gen_fsm).

%% API
-export([start_link/1, start_link/4, filter_opts/1]).

%% Start, stop & send
-export([initialize/1, stop/0, send/2]).

%% Identifiers
-export([encode_id/1, decode_id/1]).

%% Incoming events to start, stop and interact with connections to remote peers
-export([join/1, forward_join/3, join_reply/1, neighbour/2, disconnect/1,
         shuffle/4, shuffle_reply/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

%% States
-export([wait_incoming/2, wait_outgoing/2, wait_outgoing/3, active/2, active/3,
         wait_for_neighbour_reply/1, wait_for_socket/2]).

-include("hyparerl.hrl").
-include("connect.hrl").

%% Record 
-record(conn, {local,
               remote,
               target,
               send_timeout,
               timeout,
               socket,
               data
              }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Start the ranch listener with <em>Options</em>.
initialize(Options) ->
    {IP, Port} = proplists:get_value(id, Options),
    ListenOpts = [{ip, IP}, {port,Port}],
    {ok, _} = ranch:start_listener(hypar_conn, 20, ranch_tcp, ListenOpts,
                                   connect, filter_opts(Options)).

%% @doc Stop the ranch listener
stop() -> ranch:stop_listener(tcp_conn).

%% @doc Send a binary message <em>Bin</em> to <em>
send(Conn, Bin) -> gen_fsm:send_event(Conn, {message, Bin}).

%% @doc Create a tcp-connection to <em>To</em>. Send a join message and put this
%%      connection in active state.
join(To) ->
    {ok, Conn} = supervisor:start_child(connect_sup, []),
    case gen_fsm:sync_send_event(Conn, {join, To}) of
        ok ->  #peer{id=To, conn=Conn};
        Err -> Err
    end.

%% @doc Send a forward join over an existing active connection <em>Conn</em>.
forward_join(Conn, Req, TTL) ->
    gen_fsm:send_event(Conn, {forward_join, Req, TTL}).

%% @doc Create a new active connection <em>To</em> and send a join_reply.
join_reply(To) ->
    {ok, Conn} = supervisor:start_child(connect_sup, []),
    case gen_fsm:sync_send_event(Conn, {join_reply, To}) of
        ok ->  #peer{id=To, conn=Conn};            
        Err -> Err
    end.

%% @doc Create a new connection to <em>To</em> and send a neighbour request with
%%      priority <em>Priority</em>. 
neighbour(To, Priority) ->
    {ok, Conn} = supervisor:start_child(connect_sup, []),
    case gen_fsm:sync_send_event(Conn, {neighbour, To, Priority}) of
        accept  -> #peer{id=To, conn=Conn};
        decline -> decline;
        {error, Err} -> {error, Err}                      
    end.

%% @doc Send a shuffle request to an active connection <em>Conn</em>. The
%%      source node is <em>Req</em> with id <em>SId</em>, time to live
%%      <em>TTL</em> and exchange list <em>XList</em>.
shuffle(Conn, Req, TTL, XList) ->
    gen_fsm:send_event(Conn, {shuffle, Req, TTL, XList}).

%% @doc Send a shuffle reply to <em>To</em> in shuffle reply with id
%%      <em>SId</em> carrying the reply list <em>XList</em>.
shuffle_reply(To, XList) ->
    {ok, Conn}  = supervisor:start_child(connect_sup, []),
    gen_fsm:send_event(Conn, {shuffle_reply, To, XList}).

%% @doc Disconnect an active connection <em>Conn</em>.
disconnect(Conn) -> gen_fsm:sync_send_event(Conn, disconnect).

%% @doc Start an incoming connection via ranch
start_link(LPid, Socket, _Transport, Options) ->
    gen_fsm:start_link(?MODULE, [LPid, Socket, Options], []).

%% @doc Start an outgoing connection
start_link(Options) ->
    gen_fsm:start_link(?MODULE, [Options], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([LPid, Socket, Options]) ->
    {ok, wait_for_socket, {LPid, initial_state(Options, Socket)}, 0};
init([Options]) ->
    {ok, wait_outgoing, initial_state(Options)}.

%% @doc Active state
%%      Four possibilities; Either it is a binary message, a forward-join,
%%      a shuffle or a disconnect.
active({message, Bin}, C) ->
    Len = byte_size(Bin),
    try_send(C, <<?MESSAGE, Len:32/integer, Bin/binary>>);
active({forward_join, Req, TTL}, C) ->
    BReq = encode_id(Req),
    try_send(C, <<?FORWARDJOIN, BReq:6/binary, TTL/integer>>);
active({shuffle, Req, TTL, XList}, C) ->
    Len = length(XList),
    BReq = encode_id(Req),
    BXList = encode_xlist(XList),
    Bin = <<?SHUFFLE, BReq:6/binary, TTL/integer, Len/integer, BXList/binary>>,
    try_send(C, Bin).

active(disconnect, _, C) ->
    link_down(C#conn.target, C#conn.remote),
    gen_tcp:send(C#conn.socket, <<?DISCONNECT>>),
    {reply, ok, temporary, C}.

%% Receive socket data
handle_info({tcp, Socket, Data}, active, C) ->
    inet:setopts(Socket, [{active, once}]),
    RestBin = C#conn.data,
    parse_packets(C, <<RestBin/binary, Data/binary>>);
handle_info({tcp_closed, _}, active, C) ->
    link_down(C#conn.target, C#conn.remote),
    hypar_node:error(C#conn.remote, tcp_closed),
    {stop, normal, C};
handle_info({tcp_closed, _}, temporary, C) ->
    {stop, normal, C};
handle_info({tcp_error, _, Reason}, active, C) ->
    link_down(C#conn.target, C#conn.remote),
    hypar_node:error(C#conn.remote, Reason),
    {stop, normal, C};
handle_info({tcp_error, _, _}, temporary, C) ->
    {stop, normal, C}.


%%%===================================================================
%%% Outgoing connections
%%%===================================================================

%% Start a connection and send a join
wait_outgoing({join, To}, _, C) ->
    {_, Port} = C#conn.local,
    Bin = <<?JOIN, Port:16/integer>>,
    try_connect_send(C#conn{remote=To}, Bin);

%% Start a connection and send a join reply
wait_outgoing({join_reply, To}, _, C) ->
    {_, Port} = C#conn.local,
    Bin = <<?JOINREPLY, Port:16/integer>>,
    try_connect_send(C#conn{remote=To}, Bin);

%% Start a connection and send a neighbour request then wait for a response
wait_outgoing({neighbour, To, Priority}, _, C0) ->
    {_, Port} = C0#conn.local,
    C = C0#conn{remote=To},
    Bin = case Priority of
              high -> <<?HNEIGHBOUR, Port:16/integer>>;
              low  -> <<?LNEIGHBOUR, Port:16/integer>>
          end,

    case start_conn(C) of
        {ok, Socket} ->
            case gen_tcp:send(Socket, Bin) of
                ok  -> wait_for_neighbour_reply(C#conn{socket=Socket});
                Err -> {stop, Err, Err, C}
            end;
        Err -> {stop, Err, Err, C}
    end.                                        

%% Start a temporary connection and send a shuffle reply
wait_outgoing({shuffle_reply, To, XList}, C0) ->
    C = C0#conn{remote=To},
    case start_conn(C) of
        {ok, Socket} ->
            Len = length(XList),
            BXList = encode_xlist(XList),
            Bin = <<?SHUFFLEREPLY, Len:16/integer, BXList/binary>>,
            case gen_tcp:send(Socket, Bin) of
                ok ->  {next_state, temporary, Socket};
                Err -> {stop, Err, C}
            end;
        Err -> {stop, Err, C}
    end.

%% Wait for a reply on a neighbour request
wait_for_neighbour_reply(C=#conn{socket=Socket}) ->
    case gen_tcp:recv(Socket, 1, C#conn.timeout) of
        {ok, <<?ACCEPT>>}  -> {reply, accept, active, C};
        {ok, <<?DECLINE>>} -> {stop, normal, decline, C};
        Err                -> {stop, normal, Err, C}
    end.

%%%===================================================================
%%% Related to incoming connections
%%%===================================================================

%% @doc Accept an incoming connection on <em>Socket</em>.
%%      To accept a connection we first read one byte to check what the first
%%      message in is. This can be either:
%%      A join, forward join reply, low/high neighbour request or a shuffle
%%      reply. 
wait_incoming(timeout, C0) ->
    Socket = C0#conn.socket,
    inet:setopts(Socket, [{nodelay, true}, {send_timeout, C0#conn.send_timeout}]),
    {ok, {RemoteIP, _}} = inet:sockname(Socket),
    C = C0#conn{remote={RemoteIP,undefined}},
    %% Read 3 bytes to determine what kind of message it is
    case gen_tcp:recv(Socket, 3 ,C#conn.timeout) of
        {ok, Bin} ->
            case Bin of
                <<?JOIN, Port:16/integer>>       -> handle_join(C, Port);
                <<?JOINREPLY, Port:16/integer>>  -> handle_join_reply(C, Port);
                <<?LNEIGHBOUR, Port:16/integer>> -> handle_neighbour(C, Port, low);
                <<?HNEIGHBOUR, Port:16/integer>> -> handle_neighbour(C, Port, high);
                <<?SHUFFLEREPLY, Len:16/integer>>      -> handle_shuffle_reply(C, Len)
            end;
        {error, Err} -> {stop, {error, Err}, C}
    end.

%% Wait for the go-ahead from the ranch server
wait_for_socket(timeout, {LPid, C}) ->
    ok = ranch:accept_ack(LPid),
    {next_state, wait_incoming, C, 0}.

%%%===================================================================
%%% Not used
%%%===================================================================

handle_event(_, _, S) ->
    {stop, not_used, S}.

handle_sync_event(_, _, _, S) ->
    {stop, not_used, S}.

code_change(_,StateName, StateData, _) ->
    {ok, StateName, StateData}.

terminate(_, _, _) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @doc Notify <em>Target</em> of a <b>link_down</b> event to node <em>To</em>
link_down(Target, To) ->
    lager:info("Link down: ~p~n", [To]), 
    gen_server:cast(Target, {link_down, To}).

%% @doc Deliver a message <em>Bin</em> to <em>Receiver</em> from connection
%%      <em>Id</em>.
deliver(Target, Id, Bin) ->
    gen_server:cast(Target, {message, Id, Bin}).

%% @doc Parse the incoming stream of bytes in the active state.
parse_packets(C, <<?MESSAGE, Len:32/integer, Rest0/binary>>)
  when byte_size(Rest0) >= Len -> 
    <<Msg:Len/binary, Rest/binary>> = Rest0,
    deliver(C#conn.target, C#conn.remote, Msg),
    parse_packets(C, Rest);
parse_packets(C, <<?FORWARDJOIN, BReq:6/binary, TTL/integer, Rest0/binary>>) ->
    hypar_node:forward_join(C#conn.remote, decode_id(BReq), TTL),
    parse_packets(C, Rest0);
parse_packets(C, <<?SHUFFLE, BReq:6/binary, TTL/integer, Len/integer,
                   Rest0/binary>>)
  when byte_size(Rest0) >= Len*6 ->
    XListLen = Len*6,
    <<BinXList:XListLen/binary, Rest/binary>> = Rest0,
    XList = parse_xlist(BinXList),
    hypar_node:shuffle(C#conn.remote, decode_id(BReq), TTL, XList),
    parse_packets(C, Rest);
parse_packets(C, <<?DISCONNECT>>) ->
    link_down(C#conn.target, C#conn.remote),
    hypar_node:disconnect(C#conn.remote),
    gen_tcp:close(C#conn.socket),
    {stop, normal, C};
parse_packets(C, <<>>) ->
    {next_state, active, C};
parse_packets(C, Rest) ->
    {next_state, active, C#conn{data=Rest}}.

%% @doc Handle a incoming join. Construct the identifier.
%%      Call hypar_node:join(Id) and move to active.
handle_join(C, Port) -> handle(join, C, Port).

%% @doc Handle an incoming join reply.
%%      Call hypar_node:join_reply(Id) and move to active
handle_join_reply(C, Port) -> handle(join_reply, C, Port).

%% @doc Handle an incoming neighbour request. Construct the remote
%%      Id and call hypar_node:neighbour(Id, Priority) checking the return and
%%      either send ACCEPT or DECLINE back on the socket.
handle_neighbour(C0, Port, Priority) ->
    {RemoteIP, _} = C0#conn.remote,
    Id = {RemoteIP, Port},
    C = C0#conn{remote=Id},
    case hypar_node:neighbour(Id, Priority) of
        accept  -> accept_neighbour(C);
        decline -> decline_neighbour(C)
    end.

%% @doc Accept a neighbour, send ACCEPT back on socket and move to active.
accept_neighbour(C) ->
    Socket = C#conn.socket,
    case gen_tcp:send(Socket, <<?ACCEPT>>) of
        ok           -> inet:setopts(Socket, [{active, once}]),
                        {next_state, active, C};
        {error, Err} -> hypar_node:error(C#conn.remote, Err),
                        {stop, {error, Err}, C}
    end.

%% @doc Decline a neighbour, send DECLINE back on socket and close this
%%      connection.
decline_neighbour(C) ->
    case gen_tcp:send(C#conn.socket, <<?DECLINE>>) of
        ok  -> {next_state, temporary, C};
        Err -> {stop, Err, C}
    end.

%% @doc Receive the exchange list of length <em>Len</em>  for shuffle with id
%%      <em>SId</em> for the shuffle reply.
handle_shuffle_reply(C, 0) ->
    hypar_node:shuffle_reply([]),
    gen_tcp:close(C#conn.socket),
    {stop, normal, C};
handle_shuffle_reply(C, Len) ->
    Socket = C#conn.socket,
    case gen_tcp:recv(Socket, Len*6, C#conn.timeout) of
        {ok, Bin} -> hypar_node:shuffle_reply(parse_xlist(Bin)),
                     gen_tcp:close(Socket),
                     {stop, normal, C};
        Err        -> {stop, Err, C}
    end.

%% @doc Try to start a connection <em>C</em> to a remote node try to send
%%      <em>Bin</em> over the socket. And then moving into the active state.
%%      If an error occurs, return the error and stop the connection.
try_connect_send(C0, Bin) ->
    case start_conn(C0) of
        {ok, Socket} ->
            case gen_tcp:send(Socket, Bin) of                                
                ok  -> inet:setopts(Socket, [{active, true}]),
                       {reply, ok, active, C0#conn{socket=Socket}};
                Err -> {stop, Err, Err, Socket}
            end;
        Err -> {stop, Err, Err, C0}
    end.

%% @doc Try to start a connection <em>C</em>.
start_conn(C) ->
    {LocalIP, _} = C#conn.local,
    {RemoteIP, RemotePort} = C#conn.remote,
    Args = [{ip, LocalIP}, {send_timeout, C#conn.send_timeout},
            {active, false}, binary, {packet, raw}, {nodelay, true}],
    
    gen_tcp:connect(RemoteIP, RemotePort, Args, C#conn.timeout).

%% @doc Try to send <em>Bin</em> over active connection <em>C</em>. Move
%%      to active if successful otherwise stop.
try_send(C, Bin) ->
    case gen_tcp:send(C#conn.socket, Bin) of
        ok ->  {next_state, active, C};
        Err -> {_, Reason} = Err,
               ok = hypar_node:error(C#conn.remote, Reason),
               {stop, Err, C}
    end.

%% @doc Helper function for handle_join and handle_join_reply.
handle(F, C0, Port) ->
    {RemoteIP, _} = C0#conn.remote,
    Id = {RemoteIP, Port},
    ok = hypar_node:F(Id),
    inet:setopts(C0#conn.socket, [{active, once}]),
    {next_state, active, C0#conn{remote=Id}}.

%% @doc Parse an XList
parse_xlist(<<>>) -> [];
parse_xlist(<<Id:6/binary, Rest/binary>>) -> [decode_id(Id)|parse_xlist(Rest)].

%% @doc Encode an XList
encode_xlist(XList) ->
    encode_xlist(XList, <<>>).

encode_xlist([], All) -> All;
encode_xlist([Id|Rest], All) ->
    BId = encode_id(Id),
    encode_xlist(Rest, <<BId:6/binary, All/binary>>).
                     
%% @pure
%% @doc Encode an identifier as a binary
encode_id({{A,B,C,D},Port}) ->
    <<A/integer, B/integer, C/integer, D/integer, Port:16/integer>>.

%% @pure
%% @doc Parse a 6-byte identifier
decode_id(<<A/integer, B/integer, C/integer, D/integer, Port:16/integer>>) ->
    {{A, B, C, D}, Port}.

filter_opts(Options) ->
    Valid = [id, target, timeout, send_timeout],
    lists:filter(fun({Opt,_}) -> lists:member(Opt, Valid) end, Options).                         
    
%% @pure
%% @doc Create the inital state from <em>Options</em>.        
initial_state(Options) ->
    #conn{local = proplists:get_value(id, Options),
          target = proplists:get_value(target, Options),
          timeout = proplists:get_value(timeout, Options),
          send_timeout = proplists:get_value(send_timeout, Options),
          data = <<>>
         }.

initial_state(Options, Socket) ->
    S = initial_state(Options),
    S#conn{socket=Socket}.
