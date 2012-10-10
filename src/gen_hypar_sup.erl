%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @private
%% @title Top level supervisor
%% @doc Top level supervisor for gen_hypar
%% -------------------------------------------------------------------
-module(gen_hypar_sup).

-behaviour(supervisor).

-include("gen_hypar.hrl").

-export([start_link/4, start_gen_hypar/3, wait_for/1]).
-export([init/1]).

-spec start_link(Identifier :: id(), Mod :: module(), ModArgs :: any(),
                 Options :: options()) -> {ok, pid()}.
%% @doc Start the top level supervisor
start_link(Identifier, Mod, ModArgs, Options) ->
    supervisor:start_link(?MODULE, [Identifier, Mod, ModArgs, Options]).

init([Identifier, Mod, ModArgs, Options]) ->
    HyparNode = {hypar_node,
                 {hypar_node, start_link, [Identifier, Options]},
                 permanent, 5000, worker, [hypar_node]},
    PeerSup = {peer_sup,
               {peer_sup, start_link, [Identifier]},
               permanent, 5000, supervisor, [peer_sup]},
    GenHypar = {gen_hypar,
                {?MODULE, start_gen_hypar, [Identifier, Mod, ModArgs]},
                permanent, 5000, worker, [gen_hypar, Mod]},
    {ok, { {one_for_all, 5, 10}, [HyparNode, PeerSup, GenHypar]}}.

-spec start_gen_hypar(Identifier :: id(), Mod :: module(),
                      ModArgs :: any()) -> {ok, pid()}.
%% @private Start the gen hypar process
start_gen_hypar(Identifier, Mod, ModArgs) ->
    {ok, Pid} = Mod:start_link(Identifier, ModArgs),
    yes = register_gen_hypar(Identifier, Pid),
    {ok, Pid}.

-spec register_gen_hypar(Identifier :: id(), Pid :: pid()) -> yes | no.
%% @private register the gen_hypar process                              
register_gen_hypar(Identifier, Pid) ->
    gen_hypar_util:register(name(Identifier), Pid).

%% @private Wait for the gen_hypar process to start
-spec wait_for(Identifier :: id()) -> ok.
wait_for(Identifier) ->
    gen_hypar_util:wait_for(name(Identifier)).

-spec name(Identifier :: id()) -> {gen_hypar, id()}.
name(Identifier) ->
    {gen_hypar, Identifier}.
