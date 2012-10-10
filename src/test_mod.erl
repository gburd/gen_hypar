-module(test_mod).
-behaviour(gen_hypar).
-behaviour(gen_server).

-export([start/1, bcast/1, start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2]).

start(Port) ->
    gen_hypar:start_link({{127,0,0,1},Port}, ?MODULE, [], []).

start_link(Identifier, _) ->
    gen_server:start_link({?MODULE, local}, ?MODULE, [Identifier], []).

bcast(Msg) ->
    gen_server:cast(?MODULE, {bcast, Msg}).

init([Identifier]) ->
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
    io:format("Link down~nPeer:~p~n", Peer),
    {noreply, {Id, lists:keydelete(Peer, 1, Peers)}}.

code_change(_,S,_) ->
    {ok, S}.

terminate(_, _) ->
    ok.

broadcast(Msg, Peers) ->    
    [gen_hypar:send(Pid, Msg) || {_, Pid} <- Peers].
