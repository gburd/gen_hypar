%%% @author Emil Falk <emil.falk.1988@gmail.com>
%%% @copyright (C) 2012, Emil Falk
%%% @doc
%%% Test an isolated hypar_node
%%% All communication is mock'd away and the node is sent messages and
%%% the responses are checked.
%%% @end


-module(isolated_node_test).


-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-compile(export_all).

prop_hypar_node() ->
    ?FORALL(Cmds, commands(?MODULE),
            begin
                setup_meck(),
                Options = get_options(),
                {ok, Pid} = hypar_node:start_link(Options),
                {H, S, Res} = run_commands(?MODULE, Cmds),
                erlang:exit(Pid, kill),
                cleanup_meck(),
                Res =:= ok
            end).

setup_meck() ->
    application:start(meck),

    %% Mock away ranch call to start listeners
    meck:new(ranch),
    meck:expect(ranch, start_listener, fun(_,_,_,_,_,_) -> {ok, ok} end),
    
    %% Mock away connect
    meck:new(connect),
    
