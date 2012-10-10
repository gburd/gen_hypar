-module(gen_hypar_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_,_) ->
    application:start(ranch),
    application:start(gproc).

stop(_) ->
    ok.
