-module(hyparerl).

-export([start/0, test_start/1]).

start() ->
    ok = application:start(ranch),
    ok = application:start(hyparerl).

test_start(Port) ->
    net_kernel:connect('node6000@localhost'),

    application:start(ranch),
    application:load(hyparerl),
    application:set_env(hyparerl, id, {{127,0,0,1}, Port}),
    application:start(hyparerl).
