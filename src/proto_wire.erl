%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @private
%% @title Implements the on-wire-protocol
%% @doc The implementation of ze bits 'n ze bytes 
%% -------------------------------------------------------------------
-module(proto_wire).

-include("gen_hypar.hrl").

-export([start_connection/3, close/1, send/2, send_join/2, send_join_reply/2,
         send_shuffle_reply/2, send_neighbour_request/3,
         wait_for_neighbour_reply/2, send_accept/1, send_decline/1]).
-export([message/1, forward_join/2, shuffle/3, disconnect/0, keep_alive/0]).
-export([handle_incoming_connection/2, decode_msg/1]).

%% Protocol string, a new connection should always start with this
-define(PROTOSTR, "hypar").
-define(PROTOSTRSIZE, 5).

%% Byte representation of the different messages
-define(MESSAGE,      1). %% Payload message
-define(JOIN,         2). %% Join message
-define(FORWARDJOIN,  3). %% Forward join message
-define(JOINREPLY,    4). %% Forward join reply
-define(HNEIGHBOUR,   5). %% High priority neighbour request
-define(LNEIGHBOUR,   6). %% Low priority neighbour request
-define(SHUFFLE,      7). %% Shuffle request
-define(SHUFFLEREPLY, 8). %% Shuffle reply message
-define(DISCONNECT,   9). %% Disconnect message
-define(KEEPALIVE,   10). %% Keep alive message

%% Either accept or decline
-define(DECLINE, 0). %% Decline a neighbour request
-define(ACCEPT,  1). %% Accept a neighbour request

-spec handle_incoming_connection(Socket :: inet:socket(), Options :: options()) ->
                                        {join, id()} |
                                        {join_reply, id()} |
                                        {neighbour, id(), priority()} |
                                        {shuffle_reply, xlist()}.
%% @private These are the possible incoming first messages on a connection
handle_incoming_connection(Socket, Options) ->
    inet:setopts(Socket, sockopts(Options)),
    Timeout = gen_hypar_opts:timeout(Options),
    {ok, <<?PROTOSTR>>} = gen_tcp:recv(Socket, ?PROTOSTRSIZE, Timeout),
    {ok, <<PacketLength:32>>} = gen_tcp:recv(Socket, 4, Timeout),
    {ok, Packet} = gen_tcp:recv(Socket, PacketLength, Timeout),
    case Packet of
        <<?SHUFFLEREPLY, BXList/binary>> ->
            {shuffle_reply, gen_hypar_util:decode_idlist(BXList)};
        <<?JOIN, Id:?IDSIZE/binary>> ->
            {join, gen_hypar_util:decode_id(Id)};
        <<?JOINREPLY, Id:?IDSIZE/binary>> ->
            {join_reply, gen_hypar_util:decode_id(Id)};
        <<?HNEIGHBOUR, Id:?IDSIZE/binary>> ->
            {neighbour, gen_hypar_util:decode_id(Id), high};
        <<?LNEIGHBOUR, Id:?IDSIZE/binary>> ->
            {neighbour, gen_hypar_util:decode_id(Id), low}
    end.

%% Send functions

%% @private Send a binary but packet it with a length header first
send(Socket, Bin) ->
    Len = byte_size(Bin),
    ok = gen_tcp:send(Socket, <<Len:32/integer, Bin/binary>>).

%% @private Send a join
send_join(Socket, Identifier) ->
    send(Socket, join(Identifier)).

%% @private Send a join reply
send_join_reply(Socket, Identifier) ->
    send(Socket, join_reply(Identifier)).

%% @private Send a neighbour request
send_neighbour_request(Socket, Myself, Priority) ->
    send(Socket, neighbour(Myself, Priority)).

%% @private Send an accept byte
send_accept(Socket) ->
    send(Socket, accept()).

%% @private Send a decline byte
send_decline(Socket) ->
    send(Socket, decline()).

%% @private Send a shuffle reply
send_shuffle_reply(Socket, XList) ->
    send(Socket, shuffle_reply(XList)).

%% @private Wait for a neighbour reply, receive the packet header and
%%          the accept/decline byte.
wait_for_neighbour_reply(Socket, Timeout) ->
    case gen_tcp:recv(Socket, 5, Timeout) of
        {ok, <<1:32, ?ACCEPT>>}  -> accept;                           
        {ok, <<1:32, ?DECLINE>>} -> decline
    end.

%% Start and close a connection

%% @private Start a new connection, send the protocol string and return the socket.
start_connection({LocalIp, _}, {RemoteIp, RemotePort}, Options) ->
    Timeout = gen_hypar_opts:timeout(Options),
    Opts = [{ip, LocalIp}|sockopts(Options)],
    {ok, Socket} = gen_tcp:connect(RemoteIp, RemotePort, Opts, Timeout),
    ok = gen_tcp:send(Socket, <<?PROTOSTR>>),
    {ok, Socket}.

%% @private The socket options used
sockopts(Options) ->
    [binary, {active, false}, {packet, raw}, {nodelay, true},
     {send_timeout, gen_hypar_opts:send_timeout(Options)}].

%% @private Close a socket
close(Socket) ->
    gen_tcp:close(Socket).

%% Binary messages
accept()     -> <<?ACCEPT>>.
decline()    -> <<?DECLINE>>.
keep_alive() -> <<?KEEPALIVE>>.
disconnect() -> <<?DISCONNECT>>.

message(Bin) ->
    <<?MESSAGE, Bin/binary>>.

join(Identifier) ->
    BId = gen_hypar_util:encode_id(Identifier),
    <<?JOIN, BId:?IDSIZE/binary>>.

join_reply(Identifier) ->
    BId = gen_hypar_util:encode_id(Identifier),
    <<?JOINREPLY, BId:?IDSIZE/binary>>.

forward_join(Identifier, TTL) ->
    BId = gen_hypar_util:encode_id(Identifier),
    <<?FORWARDJOIN, BId:?IDSIZE/binary, TTL/integer>>.

neighbour(Identifier, high) ->
    BId = gen_hypar_util:encode_id(Identifier),
    <<?HNEIGHBOUR, BId:?IDSIZE/binary>>;
neighbour(Identifier, low) ->
    BId = gen_hypar_util:encode_id(Identifier),
    <<?LNEIGHBOUR, BId:?IDSIZE/binary>>.

shuffle(Identifier, TTL, XList) ->
    BId = gen_hypar_util:encode_id(Identifier),
    BXList = gen_hypar_util:encode_idlist(XList),
    <<?SHUFFLE, BId:?IDSIZE/binary, TTL/integer, BXList/binary>>.

shuffle_reply(XList) ->
    BXList = gen_hypar_util:encode_idlist(XList),
    <<?SHUFFLEREPLY, BXList/binary>>.

%% @doc Decode incoming binaries
decode_msg(<<?MESSAGE, Msg/binary>>) ->
    {message, Msg};
decode_msg(<<?FORWARDJOIN, BId:?IDSIZE/binary, TTL/integer>>) ->
    {forward_join, gen_hypar_util:decode_id(BId), TTL};
decode_msg(<<?SHUFFLE, BId:?IDSIZE/binary, TTL/integer, BXList/binary>>) ->
    {shuffle, gen_hypar_util:decode_id(BId), TTL,
     gen_hypar_util:decode_idlist(BXList)};
decode_msg(<<?DISCONNECT>>) ->
    disconnect;
decode_msg(<<?KEEPALIVE>>) ->
    keep_alive.
