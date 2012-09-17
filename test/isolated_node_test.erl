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



-record(st, {active, passive, arwl, prwl, active_size, passive_size}).

prop_hypar_node() ->
    ?FORALL(Cmds, commands(?MODULE),
            begin
                erlang:register(test, self())
                
                setup_meck(),
                Options = get_options(),
                {ok, Pid} = hypar_node:start_link(Options),
                {H, S, Res} = run_commands(?MODULE, Cmds),
                erlang:exit(Pid, kill),
                cleanup_meck(),
                
                erlang:unregister(test),

                Res =:= ok
            end).

initial_state() ->
    Opts = get_options(),
    
    ARWL = proplists:get_value(arwl, Env, 6),
    PRWL = proplists:get_value(prwl, Env, 3),
    ActiveSize = proplists:get_value(active_size, Env, 5),
    PassiveSize = proplists:get_value(passive_size, Env, 30),

    #state{active=[], passive=[], arwl=ARWL, prwl=PRWL,
           active_size=ActiveSize, passive_size=PassiveSize}.

setup_meck() ->
    application:start(meck),

    %% Mock away ranch call to start listeners
    meck:new(ranch),
    meck:expect(ranch, start_listener, fun(_,_,_,_,_,_) -> {ok, ok} end),
    
    %% Mock away connect
    meck:new(connect),
    meck:expect(connect, send_control, fun(Pid, Msg) ->            
                                               test ! {Pid, Msg}
                                       end),
    meck:expect(connect, new_connection, fun(IDa, IDb) ->
                                                 Pid = spawn(fun loop/0),
                                                 MRef = erlang:monitor(process, Pid),
                                                 {ok, Pid, MRef}
                                         end),
    meck:expect(connect, new_temp_connection, fun(IDa, IDb) ->
                                                      Pid = spawn(fun loop/0),
                                                      {ok, Pid}
                                              end).

get_options() ->
    application:load(hyparerl),
    application:get_all_env(hyparerl).

loop() ->
    receive kill -> exit(kill) end.

%% @doc Send a join message
join(NewNode) ->
    send(Pid, {join, NewNode}).

%% @doc Send a forward-join message
forward_join(Pid, NewNode, TTL, Sender) ->
    send(Pid, {forward_join, NewNode, TTL, Sender}).

%% @doc Send a reply to a forward-join message
forward_join_reply(Pid, Sender) ->
    send(Pid, {forward_join_reply, Sender}).

%% @doc Send a disconnect message
disconnect(Pid, Peer) ->
    send(Pid, {disconnect, Peer}).

%% @doc Send a neighbour-request message
neighbour_request(Pid, Sender, Priority) ->
    send(Pid, {neighbour_request, Sender, Priority}).

%% @doc Send a neighbour-accept message
neighbour_accept(Pid, Sender) ->
    send(Pid, {neighbour_accept, Sender}).

%% @doc Send a neighbour-decline message
neighbour_decline(Pid, Sender) ->
    send(Pid, {neighbour_decline, Sender}).

%% @doc Send a shuffle-request message
shuffle_request(Pid, XList, TTL, Sender, Ref) ->
    send(Pid, {shuffle_request, XList, TTL, Sender, Ref}).

%% @doc Send a shuffle-reply message
shuffle_reply(Pid, ExchangeList, Ref) ->
    send(Pid, {shuffle_reply, ExchangeList, Ref}).

send(Pid, Msg) ->
    gen_server:cast(Pid, {Msg, Pid}).
