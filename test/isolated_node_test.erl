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



-record(st, {active, passive, pending}).

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
                                                 {ok, Pid} = spawn(fun loop/0),
                                                 MRef = erlang:monitor(process, Pid),
                                                 {ok, Pid, MRef}
                                         end),
    meck:expect(connect, new_temp_connection, fun(IDa, IDb) ->
                                                      spawn(fun loop/0)
                                              end),
    

loop() ->
    receive kill -> exit(kill) end.

%% @doc Send a join message
join(NewNode) ->
    hypar_node:control_msg({join, NewNode}).

%% @doc Send a forward-join message
forward_join(Pid, NewNode, TTL, Sender) ->
    hypar_node:control_msg({forward_join, NewNode, TTL, Sender}).

%% @doc Send a reply to a forward-join message
forward_join_reply(Pid, Sender) ->
    hypar_node:control_msg({forward_join_reply, Sender}).

%% @doc Send a disconnect message
disconnect(Pid, Peer) ->
    hypar_node:control_msg({disconnect, Peer}).

%% @doc Send a neighbour-request message
neighbour_request(Pid, Sender, Priority) ->
    hypar_node:control_msg({neighbour_request, Sender, Priority}).

%% @doc Send a neighbour-accept message
neighbour_accept(Pid, Sender) ->
    hypar_node:control_msg({neighbour_accept, Sender}).

%% @doc Send a neighbour-decline message
neighbour_decline(Pid, Sender) ->
    hypar_node:control_msg({neighbour_decline, Sender}).

%% @doc Send a shuffle-request message
shuffle_request(Pid, XList, TTL, Sender, Ref) ->
    hypar_node:control_msg({shuffle_request, XList, TTL, Sender, Ref}).

%% @doc Send a shuffle-reply message
shuffle_reply(Pid, ExchangeList, Ref) ->
    hypar_node:control_msg({shuffle_reply, ExchangeList, Ref}).
