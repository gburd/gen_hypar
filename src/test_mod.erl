-module(test_mod).
-behaviour(gen_hypar).
-behaviour(gen_server).

-export([test/1, join_them/1, get_peers/1]).

-export([start/1, bcast/2, start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2]).

test(N) ->
    application:start(ranch),
    application:start(gproc),
    [start(local_id(5000+I)) || I <- lists:seq(0,N)].

join_them(N) ->
    [gen_hypar:join_cluster(local_id(5000+I), local_id(5000)) || I <- lists:seq(1,N)].

get_peers(Port) ->
    gen_hypar:get_peers(local_id(Port)).

local_id(Port) ->
    {{127,0,0,1}, Port}.

start(Identifier) ->
    gen_hypar:start_link(Identifier, ?MODULE, [], []).

start_link(Identifier, _) ->
    gen_server:start_link(?MODULE, [Identifier], []).

bcast(Port, Msg) ->
    gen_server:cast(gen_hypar:where(local_id(Port)), {bcast, Msg}).

init([Identifier]) ->
    ok = gen_hypar:register_and_wait(Identifier),
    {ok, {Identifier, []}}.

handle_call(_,_,S) ->
    {stop, not_used, S}.

handle_cast({bcast, Msg}, {_, Peers}=S) ->
    broadcast(Msg, Peers),
    {noreply, S}.

handle_info({message, From, Msg}, S) ->
    io:format("Received~nFrom:~p~nMessage:~p~n", [From, Msg]),
    {noreply, S};
handle_info({link_up, {Peer, Pid}=E}, {Id, Peers}) ->
    io:format("Link up~nPeer:~p~nPid:~p~n", [Peer, Pid]),
    {noreply, {Id, [E|Peers]}};
handle_info({link_down, Peer}, {Id, Peers}) ->
    io:format("Link down~nPeer:~p~n", [Peer]),
    {noreply, {Id, lists:keydelete(Peer, 1, Peers)}}.

code_change(_,S,_) ->
    {ok, S}.

terminate(_, _) ->
    ok.

broadcast(Msg, Peers) ->    
    [gen_hypar:send_message(Pid, Msg) || {_, Pid} <- Peers].
