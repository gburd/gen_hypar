-module(test_mod).
-behaviour(gen_hypar).
-behaviour(gen_server).

-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2]).

start(Port) ->
    gen_hypar:start_link({{127,0,0,1},Port}, ?MODULE, [], []).

start_link(Identifier, _) ->
    gen_server:start_link({?MODULE, local}, ?MODULE, [Identifier, _], []).

bcast(Msg) ->
    gen_server:cast(?MODULE, {bcast, Msg}).

init([Identifier]) ->
    {ok, {Identifier, []}}.

handle_call(_,_,S) ->
    {stop, not_used, S}.

handle_cast({bcast, Msg}, {Id, Peers}) ->
    broadcast(Msg, Peers),
    {noreply, S}.

handle_info({message, From, Msg}, S) ->
    io:format("Received~nFrom:~p~n~Message:~p~n", [From, Msg]),
    {noreply, S};
handle_info({link_up, {Peer, Pid}}, S) ->
    io:format("Link up~nPeer:~p~nPid:~p~n", [Peer, Pid]),
    {noreply, S};
handle_info({link_down, Peer}, S) ->
    io:format("Link down~nPeer:~p~n", Peer),
    {noreply, S}.

code_change(_,S,_) ->
    {ok, S}.

terminate(_, _) ->
    ok.

broadcast(Msg, Peers) ->    
    [gen_hypar:send(Pid, Msg) || {_, Pid} <- Peers].
