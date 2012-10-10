%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @private
%% @title The peer supervisor
%% @doc The peer supervisor
%% -------------------------------------------------------------------
-module(peer_sup).
-behaviour(supervisor).

-export([start_link/1, wait_for/1]).
-export([init/1]).

-include("gen_hypar.hrl").

-spec start_link(Identifier :: id()) -> {ok, pid()}.
%% @private Start the peer supervisor
start_link(Identifier) ->
    {ok, Pid} = supervisor:start(?MODULE, [Identifier]),
    yes = register_peer_sup(Identifier, Pid),
    {ok, Pid}.

-spec wait_for(Identifier :: id()) -> {ok, pid()}.
%% @private Wait for the peer supervisor to start
wait_for(Identifier) ->
    gen_hypar_util:wait_for(name(Identifier)).

init([Identifier]) ->
    Peer = {peer,
            {peer, start_link, [Identifier]},
            temporary, 5000, supervisor, [peer]},
    {ok, {simple_one_for_one, 5, 10}, [Peer]}.

-spec register_peer_sup(Identifier :: id(), Pid :: pid()) -> yes | no.
register_peer_sup(Identifier, Pid) ->
    gen_hypar_util:register(name(Identifier), Pid).

-spec name(Identifier :: id()) -> {peer_sup, id()}.
name(Identifier) ->
    {peer_sup, Identifier}.
