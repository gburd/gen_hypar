-module(hyparerl_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    hyparerl_sup:start_link(application:get_all_env(hyparerl)).

stop(_State) ->
    ok.
