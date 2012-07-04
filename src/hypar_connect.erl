-module(hypar_connect).

-behaviour(gen_server).

%% API
-export([start_link/2, start_link/3, join/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(conn, {id     :: node_id(),
               socket :: socket()}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(ListenSocket, Myself) ->
    gen_server:start_link(?MODULE, [listen, ListenSocket, Myself], []).

start_link(_ListenSocket, Myself, NodeID) ->
    gen_server:start_link(?MODULE, [connect, NodeID, Myself], []).

join(Pid) ->
    gen_server:cast(Pid, join).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([listen, ListenSocket, Myself]) ->
    gen_server:cast(self(), accept),
    {ok, #conn{id=Myself, socket=ListenSocket}}.
init([connect, NodeID, Myself]) ->
    {IPAddr, Port} = NodeID,
    {MyIPAddr, _MyPort} = Myself,
    {ok, Socket} = gen_tcp:connect(IPAddr, Port, [{ip, MyIPAddr},
                                                  binary,
                                                  {active, once},
                                                  {packet, 2},
                                                  {keepalive, true}]),
    {ok, #conn{id=Myself, socket=Socket}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(accept, Conn=#conn{socket=ListenSocket}) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    hypar_connect_sup:start_listener(),
    {noreply, Conn#conn{socket=Socket}};
handle_cast(join, Conn=#conn{id=Myself, socket=Socket}) ->
    send_msg({join, Myself}, Socket).

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @doc send a message over a TCP-socket
send_msg(Msg, Socket) ->
    gen_tcp:send(Socket, term_to_binary(Msg)).
