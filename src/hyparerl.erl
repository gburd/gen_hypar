-module(hyparerl).

-export([start/0, test_start/1, join_cluster/1, shuffle/0,
         get_peers/0, get_passive_peers/0, get_all_peers/0,
         get_pending_peers/0]).

start() ->
    lager:start(),
    application:start(ranch),
    application:start(hyparerl).

test_start(Port) ->

    lager:start(),
    application:start(ranch),
    
    timer:sleep(1000),

    lager:set_loglevel(lager_console_backend, debug),

    application:load(hyparerl),
    application:set_env(hyparerl, id, {{127,0,0,1}, Port}),
    application:start(hyparerl).

join_cluster(ContactNode) ->
    hypar_node:join_cluster(ContactNode).

shuffle() ->
    hypar_node:shuffle().

get_peers() ->
    hypar_node:get_peers().

get_pending_peers() ->
    hypar_node:get_pending_peers().

get_passive_peers() ->
    hypar_node:get_passive_peers().

get_all_peers() ->
    hypar_node:get_all_peers().
