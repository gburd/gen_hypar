-module(hyparerl_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1, test_help/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    hyparerl_sup:start_link(application:get_all_env(hyparerl)).

stop(_State) ->
    ok.

test_help(Port) ->
    application:load(hyparerl),
    application:set_env(hyparerl, this, {{127,0,0,1}, Port}),
    application:start(hyparerl),
    hypar_man:join_cluster({127,0,0,1}, 6666).
