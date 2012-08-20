%% Test module
%% TODO:
%% Let eunit call proper tests
%% Mock away the connect/connect_sup module
%% Define the stateful model for the node
%% Test away!

-module(hypar_man_test).

-include_lib("proper/include/proper.hrl").

-include_lib("eunit/include/eunit.hrl").

hyper_man_test() ->
    proper:quickcheck(?MODULE:prop_hyper_man()).

prop_hyper_man() ->
    ?FORALL(N, pos_integer(),
            lists:nth(N, lists:seq(1,N)) == N
            ).

meck_connect_sup() ->
    meck:new(connect_sup),
    meck:expect
