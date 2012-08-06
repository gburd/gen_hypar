%% @doc Module that implements the tcp-connection handling between two
%%      nodes in hyparview. Either listens to a socket for connections
%%      or provided with an existing open socket.

-module(connect).

-behaviour(gen_server).

%% API
-export([start_link/2, start_link/3, send_control/2, send_message/2, kill/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TIMEOUT, infinity).

-include("hyparerl.hrl").

%% Local state
-record(conn_st, {socket     :: inet:socket(),
                  recipient  :: atom()}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Start a tcp-handler that accepts connections from a listen-socket
start_link(ListenSocket, Recipient) ->
    Args = [listen, ListenSocket, Recipient],
    gen_server:start_link(?MODULE, Args, []).

%% @doc Start a tcp-handler with a started tcp-connection
start_link(_ListenSocket, Recipient, Socket) ->
    Args = [connect, Socket, Recipient],
    gen_server:start_link(?MODULE, Args, []).

-spec send_control(Peer :: #peer{}, Msg :: any()) -> ok.
%% @doc Send a control message (i.e node -> node)
send_control(Peer, Msg) ->
    gen_server:cast(Peer#peer.pid, {control, Msg}).

-spec send_message(Peer :: #peer{}, Msg :: any()) -> ok.
%% @doc Send a message to a peer, this will be routed to the configured
%%      recipient process. (For example the plumtree service)
send_message(Peer, Msg) ->
    gen_server:cast(Peer#peer.pid, {message, Msg}).

-spec kill(Peer :: #peer{}) -> ok.
%% @doc Kill a tcp-handler
kill(Peer) ->
    gen_server:cast(Peer#peer.pid, kill).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% Either initiate a connection via a listen socket or existing socket
init([listen, ListenSocket, Recipient]) ->
    ?INFO([{?MODULE, "Starting a listening connection-handler..."},
           {pid, self()}]),

    gen_server:cast(self(), accept),
    ConnSt = #conn_st{socket=ListenSocket,
                      recipient=Recipient},
    {ok, ConnSt};
init([connect, Socket, Recipient]) ->
    ?INFO([{?MODULE, "Starting a connection-handler on existing socket..."},
           {pid, self()}]),
    
    inet:setopts(Socket, [{active, once}]),
    ConnSt = #conn_st{socket=Socket,
                      recipient=Recipient},
    {ok, ConnSt}.

%% Handle the sending of messages
handle_cast(Msg={message, _Payload}, ConnSt=#conn_st{socket=Socket}) ->
    ?INFO([{?MODULE, "Sending message..."},
           {pid, self()}]),

    send(Socket, Msg),
    {noreply, ConnSt};

%% Handle the sending of control-messages
handle_cast(Msg={control, Payload}, ConnSt=#conn_st{socket=Socket}) ->
    ?INFO([{?MODULE, "Sending control-message..."},
           {pid, self()},
           {msg, Payload}]),

    send(Socket, Msg),
    {noreply, ConnSt};

%% Accept an incoming connection
handle_cast(accept, ConnSt=#conn_st{socket=ListenSocket}) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    ?INFO([{?MODULE, "Accepting an incoming connection..."},
           {pid, self()}]),

    connect_sup:start_listener(),
    {noreply, ConnSt#conn_st{socket=Socket}};

%% Kill the connection
handle_cast(kill, ConnSt=#conn_st{socket=Socket}) ->
    ?INFO([{?MODULE, "Killing connection..."},
           {pid, self()}]),

    gen_tcp:close(Socket),
    {stop, normal, ConnSt}.

%% Take care of incoming tcp-data
handle_info({tcp, Socket, Data}, ConnSt=#conn_st{recipient=Recipient}) ->
    case binary_to_term(Data) of
        {message, Msg} -> 
            ?INFO([{?MODULE, "Received a message, sending it to recipient..."},
                   {pid, self()},
                   {recipient, Recipient}]),
            gen_server:cast(Recipient, {Msg, self()});
        {control, Msg} ->
            ?INFO([{?MODULE, "Received a control-message, sending it to manager..."},
                   {pid, self()}]),
            gen_server:cast(hypar_man, {Msg, self()})
    end,
    inet:setopts(Socket, [{active, once}]),
    {noreply, ConnSt};

%% If the connection is closed, stop the handler
handle_info({tcp_closed, _Socket}, ConnSt) ->
    ?INFO([{?MODULE, "TCP-connection closed..."},
           {pid, self()}]),
    
    {stop, normal, ConnSt};

%% If the connection experience an error, stop the handler
handle_info({tcp_error, _Socket, Reason}, ConnSt) ->
    ?ERROR([{?MODULE, "TCP-connection experienced an error, closing it..."},
            {error, Reason},
            {pid, self()}]),
    
    {stop, normal, ConnSt}.

%% No handle_call used
handle_call(_Msg, _From, ConnSt) ->
    {stop, not_used, ConnSt}.

terminate(_Reason, _Conn_St) ->
    ok.

code_change(_OldVsn, Conn_St, _Extra) ->
    {ok, Conn_St}.

%%%===================================================================
%%% Internal functions
%%%===================================================================    

-spec send(Socket :: gen_tcp:socket(), Msg :: any()) -> ok | {error, term()}.
%% Wrapper for gen_tcp:send and term_to_binary.
send(Socket, Msg) ->
    gen_tcp:send(Socket, term_to_binary(Msg)).
