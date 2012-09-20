-module(eqc_hypar_test).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-include_lib("eunit/include/eunit.hrl").

-include("hyparerl.hrl").

-compile([export_all]).

-record(st, {active = [],
             pending = [],
             peers = [],
             arwl = 6,
             prwl = 3,
             active_size = 5,
             passive_size = 30,
             k_active = 3,
             k_passive = 5}).

prepare() ->
    application:load(hyparerl),
    application:meck(start).

mock_connect() ->
    meck:new(connect),
    meck:expect(connect, initialize, fun() -> ok end),
    meck:expect(connect, stop, fun() -> ok end),                                       

    ConnFun = fun(_, To) -> #peer{id=To, pid=collector} end,
    
    meck:expect(connect, new_active, ConnFun),
    meck:expect(connect, new_temp, ConnFun),
    meck:expect(connect, new_pending, ConnFun).

unmock_connect() ->    
    meck:unload(connect).

prop_hypar_node() ->
    Options0 = application:get_all_env(hyparerl),
    Options = proplists:delete(shuffle_period, Options0),
    
    ?FORALL(Cmds, commands(?MODULE, initial_state(Options)),
            begin
                mock_connect(),
                {ok, _} = collector:start_link(),
                
                {ok, _} = hypar_node:start_link(Options),
                {H, S, Res} = run_commands(?MODULE, Cmds),                

                ok = hypar_node:stop(),
                ok = collector:stop(),
                unmock_connect(),
                ?WHENFAIL(
                   io:format("Hist: ~p\nState: ~p\n Res: ~p\n", [H, S, Res]),
                   Res == ok
                  )end).

initial_state(Opts) ->
    ARWL = proplists:get_value(arwl, Opts),
    PRWL = proplists:get_value(prwl, Opts),
    ActiveSize = proplists:get_value(active_size, Opts),
    PassiveSize = proplists:get_value(passive_size, Opts),
    KActive = proplists:get_value(k_active, Opts),
    KPassive = proplists:get_value(k_passive, Opts),

    #st{arwl=ARWL,prwl=PRWL,active_size=ActiveSize,passive_size=PassiveSize,
        k_active=KActive, k_passive=KPassive}.

next_state(S, Peer, {call, ?MODULE, create_peer, []}) ->
    S#st{peers=[Peer|S#st.peers]};
next_state(S, Disc, {call, ?MODULE, join_cluster, [Peer]}) ->
    S#st{active=lists:usort([Peer#peer.id|lists:delete(Disc, S#st.active)])}.

command(S) ->
    oneof([{call, ?MODULE, create_peer, []},
           {call, hypar_node, join_cluster, [elements(S#st.peers)]}
          ]).

precondition(_S, _C) ->
    true.

postcondition(_S, _C, _R) ->
    true.

invariant(S) ->
    lists:usort(hypar_node:get_peers()) =:= lists:usort(S#st.active).

create_peer() ->
    #peer{id=make_ref(), pid=collector}.

join_cluster(Peer) ->
    hypar_node:join_cluster(Peer#peer.id).
