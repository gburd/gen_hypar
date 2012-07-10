-module(hyparerl_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    hyparerl_sup:start_link(merge_options()).

stop(_State) ->
    ok.

%% ===================================================================
%% Internal functions
%% ===================================================================
merge_options() ->
    DefFun = fun({Opt, Def}, Acc0) ->
                     Head = case application:get_key(hyparerl, Opt) of
                                undefined -> {Opt, Def};
                                {ok, Val} -> {Opt, Val}
                            end,
                     [Head|Acc0]
             end,
    lists:foldl(DefFun, [], default_options()).

%% @doc Default options for the hyparview-manager
default_options() ->
    [{ipaddr, {127,0,0,1}},
     {port, 6666},
     {active_size, 5},
     {passive_size, 30},
     {arwl, 6},
     {prwl, 3},
     {k_active, 3},
     {k_passive, 4}].
