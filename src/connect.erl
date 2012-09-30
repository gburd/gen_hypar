%% @private
%% @doc Module that takes care of connections in the hyparerl application
%%
%%      =Binary formats=
%%      ==Identifier=
%%      encode_id({{A, B, C, D}, Port}) = <<A, B, C, D, Port:16/integer>>
%%      (6 bytes)
%%      ==Join==
%%      <<?JOIN, BId:6/binary>>
%%      ==Forward join== 
%%      <<?FORWARDJOIN, Req:6/binary, TTL/integer>>
%%      ==Join reply==
%%      <<?JOINREPLY, BId:6/binary>>
%%      ==High priority neighbour request==
%%      <<?HNEIGHBOUR, BId:6/binary>>
%%      ==Low priority neighbour request==
%%      <<?LNEIGHBOUR, BId:6/binary>>
%%      ==Neighbour accept/decline==
%%      Accept:  <<?ACCEPT>>
%%      Decline: <<?DECLINE>>
%%      ==Disconnect==
%%      <<?DISCONNECT>>
%%      ==Shuffle==
%%      <<?SHUFFLE, BReq:6/binary, TTL/integer, Len/integer, XList/binary>>
%%      ==Shuffle reply==
%%      Len is 16 bits for convinience
%%      <<?SHUFFLEREPLY, Len/integer, XList/binary>>
%%
%% @todo
%%      Because of the format of the protocol some configuration parameters
%%      have become restricted. I do not think that it imposes any problem.
%%      Should implement a sanity check on the options when starting the
%%      application.
-module(connect).

-behaviour(ranch_protocol).
-behaviour(gen_fsm).

%% API
-export([start_link/3, start_link/4, filter_opts/1]).

%% Start, stop & send
-export([initialize/1, stop/0, send/2]).

%% Identifiers
-export([encode_id/1, decode_id/1]).

%% Incoming events to start, stop and interact with connections to remote peers
-export([join/2, forward_join/3, join_reply/2, neighbour/3, disconnect/1,
         shuffle/4, shuffle_reply/3]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

%% States
-export([wait_incoming/2, active/2, active/3, wait_for_socket/2, wait_for_ranch/2]).

-include("hyparerl.hrl").
-include("connect.hrl").

%% Record 
-record(conn, {remote,
               target,
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
    ConnectOpts = filter_opts(Options),
    {ok, _} = ranch:start_listener(hypar_conn, 20, ranch_tcp, ListenOpts,
                                   connect, ConnectOpts),
    ConnectOpts.

%% @doc Stop the ranch listener
stop() -> ranch:stop_listener(tcp_conn).

%% @doc Send a binary message <em>Bin</em> to <em>
send(Conn, Bin) -> gen_fsm:send_event(Conn, {message, Bin}).

%% @doc Create a tcp-connection to <em>To</em>. Send a join message and put this
%%      connection in active state.
join(Remote, ConnectOpts) ->
    Local = proplists:get_value(id, ConnectOpts),
    case start_connection(Remote, ConnectOpts) of
        {ok, Socket} -> send_join(Local, Remote, Socket);
        Err -> Err
    end.    

%% @doc Send a forward join over an existing active connection <em>Conn</em>.
forward_join(Peer, Req, TTL) ->
    gen_fsm:send_event(Peer#peer.conn, {forward_join, Req, TTL}).

%% @doc Create a new active connection <em>To</em> and send a join_reply.
join_reply(Remote, ConnectOpts) ->
    Local = proplists:get_value(id, ConnectOpts),
    case start_connection(Remote, ConnectOpts) of
        {ok, Socket} -> send_join_reply(Local, Remote, Socket);
        Err -> Err
    end.

%% @doc Create a new connection to <em>To</em> and send a neighbour request with
%%      priority <em>Priority</em>. 
neighbour(Remote, Priority, ConnectOpts) ->
    case start_connection(Remote, ConnectOpts) of
        {ok, Socket} ->
            send_neighbour_request(Remote, Priority, Socket, ConnectOpts);
        Err -> Err
    end.

%% @doc Send a shuffle request to an active connection <em>Conn</em>. The
%%      source node is <em>Req</em> with id <em>SId</em>, time to live
%%      <em>TTL</em> and exchange list <em>XList</em>.
shuffle(Peer, Req, TTL, XList) ->
    gen_fsm:send_event(Peer#peer.conn, {shuffle, Req, TTL, XList}).

%% @doc Send a shuffle reply to <em>To</em> in shuffle reply with id
%%      <em>SId</em> carrying the reply list <em>XList</em>.
shuffle_reply(Remote, XList, ConnectOpts) ->
    case start_connection(Remote, ConnectOpts) of
        {ok, Socket} -> send_shuffle_reply(XList, Socket);
        Err -> Err
    end.

%% @doc Disconnect an active connection <em>Conn</em>.
disconnect(Peer) -> gen_fsm:sync_send_event(Peer#peer.conn, disconnect).

%% @doc Start an incoming connection via ranch
start_link(LPid, Socket, _Transport, ConnectOpts) ->
    gen_fsm:start_link(?MODULE, [incoming, LPid, Socket, ConnectOpts], []).

%% @doc Start an outgoing active connection
start_link(ConnectOpts, Remote, Socket) ->
    gen_fsm:start_link(?MODULE, [outgoing, Remote, Socket, ConnectOpts], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([incoming, LPid, Socket, Options]) ->
    {ok, wait_for_ranch, {LPid, initial_state(Socket, Options), Options}, 0};
init([outgoing, Remote, Socket, Options]) ->
    C = initial_state(Socket, Options),
    {ok, wait_for_socket, C#conn{remote=Remote}}.

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
    Socket = C#conn.socket,
    link_down(C#conn.target, C#conn.remote),
    gen_tcp:send(Socket, <<?DISCONNECT>>),
    gen_tcp:close(Socket),
    {stop, normal, ok, C}.

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

%% @doc Try to send a join over the socket. If successful returns a peer or
%%      an error.
send_join(Local, Remote, Socket) ->
    BId = encode_id(Local),
    try_send_start_active(Remote, Socket, <<?JOIN, BId/binary>>).

%% @doc Try to send a join reply over the socket, return a peer if sucessful.
send_join_reply(Local, Remote, Socket) ->
    BId = encode_id(Local),
    try_send_start_active(Remote, Socket, <<?JOINREPLY, BId/binary>>).

%% @doc Try to send a neighbour request over the socket. Wait for a reply,
%%      and respond to that reply. If the request is successful return a peer.
send_neighbour_request(Remote, Priority, Socket, ConnectOpts) ->    
    Local = proplists:get_value(id, ConnectOpts),
    Timeout = proplists:get_value(timeout, ConnectOpts),
    BId = encode_id(Local),
    Bin = case Priority of
              high -> <<?HNEIGHBOUR, BId/binary>>;
              low  -> <<?LNEIGHBOUR, BId/binary>>
          end,
    case gen_tcp:send(Socket, Bin) of
        ok -> wait_for_neighbour_reply(Remote, Socket, Timeout);
        Err -> Err
    end.

%% @doc Receive an accept/decline byte from the socket.
wait_for_neighbour_reply(Remote, Socket, Timeout) ->
    case gen_tcp:recv(Socket, 1, Timeout) of
        {ok, <<?ACCEPT>>} ->
            {ok, new_peer(Remote, Socket)};
        {ok, <<?DECLINE>>} ->
            gen_tcp:close(Socket),
            decline;
        Err -> Err
    end.

%% @doc Send a shuffle reply
send_shuffle_reply(XList, Socket) ->
    Len = length(XList),
    BXList = encode_xlist(XList),
    Bin = <<?SHUFFLEREPLY, Len/integer, BXList/binary>>,
    case gen_tcp:send(Socket, Bin) of
        ok -> ok;
        Err -> Err
    end.

%% @doc Try to send <em>Bin</em> over <em>Socket</em>. If successful start a
%%      new controlling process and return that as a #peer{}.
try_send_start_active(Remote, Socket, Bin) ->    
    case gen_tcp:send(Socket, Bin) of
        ok -> {ok, new_peer(Remote, Socket)};
        Err -> Err
    end.

%% @doc Create a new peer, change controlling process and send a go-ahead
%%      to the new connection process.
new_peer(Remote, Socket) ->
    {ok, Pid} = supervisor:start_child(connect_sup, [Remote, Socket]),
    gen_tcp:controlling_process(Socket, Pid),
    gen_fsm:send_event(Pid, {go_ahead, Socket}),
    #peer{id=Remote, conn=Pid}.

%% Wait for the go-ahead from the hypar_node starting the connection
wait_for_socket({go_ahead, Socket}, C=#conn{socket=Socket}) ->
    inet:setopts(Socket, [{active, true}]),
    {next_state, active, C}.

%%%===================================================================
%%% Related to incoming connections
%%%===================================================================

%% @doc Accept an incoming connection on <em>Socket</em>.
%%      To accept a connection we first read one byte to check what the first
%%      message in is. This can be either:
%%      A join, forward join reply, low/high neighbour request or a shuffle
%%      reply. 
wait_incoming(timeout, {C, ConnectOpts}) ->
    Socket = C#conn.socket,
    SendTimeout = proplists:get_value(send_timeout, ConnectOpts),
    Timeout = proplists:get_value(timeout, ConnectOpts),
    inet:setopts(Socket, [{nodelay, true}, {send_timeout, SendTimeout}]),
    %% Read 1 bytes to determine what kind of message it is
    case gen_tcp:recv(Socket, 1 , Timeout) of
        {ok, Bin} ->
            case Bin of
                <<?JOIN>>         -> handle_join(Timeout, C);
                <<?JOINREPLY>>    -> handle_join_reply(Timeout, C);
                <<?LNEIGHBOUR>>   -> handle_neighbour(Timeout, C, low);
                <<?HNEIGHBOUR>>   -> handle_neighbour(Timeout, C, high);
                <<?SHUFFLEREPLY>> -> handle_shuffle_reply(Timeout, C)
            end;
        {error, Err} -> {stop, {error, Err}, C}
    end.

%% @doc Handle a incoming join. Receive the identifier and
%%      call hypar_node:join(Id) and move to active.
handle_join(Timeout, C) ->
    case recv_id(Timeout, C) of
        {ok, Id} ->
            ok = hypar_node:join(Id),
            inet:setopts(C#conn.socket, [{active, true}]),
            {next_state, active, C#conn{remote=Id}};
        Err ->
            {stop, Err, C}
    end.

%% @doc Handle an incoming join reply.
%%      Call hypar_node:join_reply(Id) and move to active
handle_join_reply(Timeout, C) -> 
    case recv_id(Timeout, C) of
        {ok, Id} ->
            ok = hypar_node:join_reply(Id),
            inet:setopts(C#conn.socket, [{active, true}]),
            {next_state, active, C#conn{remote=Id}};
        Err ->
            {stop, Err, C}
    end.

%% @doc Handle an incoming neighbour request. Construct the remote
%%      Id and call hypar_node:neighbour(Id, Priority) checking the return and
%%      either send ACCEPT or DECLINE back on the socket.
handle_neighbour(Timeout, C0, Priority) ->
    case recv_id(Timeout, C0) of
        {ok, Id} ->
            C = C0#conn{remote=Id},
            case hypar_node:neighbour(Id, Priority) of
                accept  -> accept_neighbour(C);
                decline -> decline_neighbour(C)
            end;
        Err -> 
            {stop, Err, C0}
    end.

%% @doc Accept a neighbour, send ACCEPT back on socket and move to active.
accept_neighbour(C) ->
    case gen_tcp:send(C#conn.socket, <<?ACCEPT>>) of
        ok ->
            inet:setopts(C#conn.socket, [{active, true}]),
            {next_state, active, C};
        {error, Err} ->
            hypar_node:error(C#conn.remote, Err),
            {stop, {error, Err}, C}
    end.

%% @doc Decline a neighbour, send DECLINE back on socket and close this
%%      connection.
decline_neighbour(C) ->
    Socket = C#conn.socket,
    case gen_tcp:send(Socket, <<?DECLINE>>) of
        ok  ->
            gen_tcp:close(Socket),
            {stop, normal, C};
        Err ->
            {stop, Err, C}
    end.

%% @doc Receive the exchange list of length <em>Len</em>  for shuffle with id
%%      <em>SId</em> for the shuffle reply.
handle_shuffle_reply(Timeout, C) ->
    Socket = C#conn.socket,
    case gen_tcp:recv(Socket, 1, Timeout) of
        {ok, <<0>>} ->
            hypar_node:shuffle_reply([]),
            gen_tcp:close(Socket),
            {stop, normal, C};
        {ok, <<Len/integer>>} ->
            case gen_tcp:recv(Socket, Len*6, Timeout) of
                {ok, Bin} ->
                    hypar_node:shuffle_reply(parse_xlist(Bin)),
                    gen_tcp:close(Socket),
                    {stop, normal, C};
                Err -> {stop, Err, C}
            end;        
        Err -> {stop, Err, C}
    end.


%% Wait for the go-ahead from the ranch server
wait_for_ranch(timeout, {LPid, C, Options}) ->
    ok = ranch:accept_ack(LPid),
    {next_state, wait_incoming, {C, Options}, 0}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @doc Deliver a message <em>Bin</em> to <em>Receiver</em> from connection
%%      <em>Id</em>.
deliver(Target, Id, Bin) ->
    gen_server:cast(Target, {message, Id, Bin}).

%% @doc Notify <em>Target</em> of a <b>link_down</b> event to node <em>To</em>
link_down(Target, To) ->
    lager:info("Link down: ~p~n", [To]), 
    gen_server:cast(Target, {link_down, To}).

%% @doc Start a connection to a remote host
start_connection({RemoteIp, RemotePort}, ConnectOpts) ->
    {LocalIp, _} = proplists:get_value(id, ConnectOpts),
    TimeOut = proplists:get_value(timeout, ConnectOpts),
    SendTimeOut = proplists:get_value(send_timeout, ConnectOpts),
    
    Args = [{ip, LocalIp}, {send_timeout, SendTimeOut}, {active, false},
            binary, {packet, raw}, {nodelay, true}],
    
    case gen_tcp:connect(RemoteIp, RemotePort, Args, TimeOut) of
        {ok, Socket} -> {ok, Socket};
        Err -> Err
    end.

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

%% @doc Try to receive an identifier and decoding it. Might return an error.
recv_id(Timeout, C) ->
    case gen_tcp:recv(C#conn.socket, 6, Timeout) of
        {ok, BId} -> {ok, decode_id(BId)};
        Err -> Err
    end.

%% @doc Try to send <em>Bin</em> over active connection <em>C</em>. Move
%%      to active if successful otherwise stop.
try_send(C, Bin) ->
    case gen_tcp:send(C#conn.socket, Bin) of
        ok -> {next_state, active, C};
        {error, Reason} -> 
            ok = hypar_node:error(C#conn.remote, Reason),
            {stop, {error, Reason}, C}
    end.

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

%% @pure
%% @doc Filter out the options related to this module
filter_opts(Options) ->
    Valid = [id, target, timeout, send_timeout],
    lists:filter(fun({Opt,_}) -> lists:member(Opt, Valid) end, Options).                         
    
%% @pure
%% @doc Create the inital state from <em>Options</em>.        
initial_state(Socket, Options) ->
    #conn{target = proplists:get_value(target, Options),
          socket = Socket,
          data = <<>>
         }.

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
