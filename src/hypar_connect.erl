-module(hypar_connect).

-behaviour(gen_server).

%% API
-export([start_link/2, start_link/3, send_message/2, kill/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("hyparerl.hrl").

-record(conn, {id     :: node_id(),
               socket :: inet:socket(),
               sync_msgs = []}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Start a tcp-handler that accepts connections from a listen-socket
start_link(ListenSocket, Myself) ->
    gen_server:start_link(?MODULE, [listen, ListenSocket, Myself], []).

%% @doc Start a tcp-handler with a started tcp-connection
start_link(_ListenSocket, Myself, Socket) ->
    gen_server:start_link(?MODULE, [connect, Socket, Myself], []).

%% @doc Wrapper function over gen_server:cast
send_message(Pid, Msg) ->
    gen_server:cast(Pid, {message, Msg}).

send_sync_message(Pid, Msg) ->
    gen_server:call(Pid, {message, Msg})

reply_sync_message(Pid, Ref, Reply) ->
    gen_server:cast(Pid, {reply, Ref, Reply}).

%% @doc Kill a tcp-handler
kill(Pid) ->
    gen_server:cast(Pid, kill).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([listen, ListenSocket, Myself]) ->
    gen_server:cast(self(), accept),
    {ok, #conn{id=Myself, socket=ListenSocket}};
init([connect, Socket, Myself]) ->
    {ok, #conn{id=Myself, socket=Socket}}.

handle_call({message, Msg}, From, State=#state{sync_msgs=Msgs}) ->
    Ref = make_ref(),
    gen_tcp:send(Socket, term_to_binary({sync, Ref, Msg})),
    {noreply, State#state{sync_msgs=[{Ref, From}|Msgs]}.

handle_cast(accept, Conn=#conn{socket=ListenSocket}) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    hypar_connect_sup:start_listener(),
    {noreply, Conn#conn{socket=Socket}};
handle_cast({message, Msg}, Conn=#conn{socket=Socket}) ->
    gen_tcp:send(Socket, term_to_binary({async, Msg})),
    {noreply, Conn};
handle_cast({reply, _, _}=Msg, Conn=#conn{socket=Socket}) ->
    gen_tcp:send(Socket, term_to_binary(Msg)
handle_cast(kill, Conn=#conn{socket=Socket}) ->
    gen_tcp:close(Socket),
    {stop, normal, Conn}.

handle_info({tcp, _Socket, Data}, Conn) ->
    Msg = binary_to_term(Data),
    hypar_man:deliver_msg(Msg),
    {noreply, Conn};
handle_info({tcp_closed, _Socket}, Conn) ->
    {stop, normal, Conn};
handle_info({tcp_error, _Socket, _Reason}, Conn) ->
    {stop, normal, Conn}.

terminate(_Reason, _Conn) ->
    ok.

code_change(_OldVsn, Conn, _Extra) ->
    {ok, Conn}.

%%%===================================================================
%%% Internal functions
%%%===================================================================    
