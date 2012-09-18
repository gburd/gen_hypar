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

-record(st, {active=[], passive=[], nodes,
             arwl, prwl, active_size, passive_size}).

-define(NUMNODES, 200).

test() ->
    eqc:start(),
    application:start(meck),
    application:load(hyparerl),
    eqc:quickcheck(?MODULE:prop_hypar_node()).

prop_hypar_node() ->
    Options0 = application:get_all_env(hyparerl),
    Options = proplists:delete(shuffle_period, Options0),

    NodeIDs = [list_to_atom("node" ++ integer_to_list(X)) ||
                  X <- lists:seq(1,?NUMNODES)],

    {ok,_} = test_sup:start_link(),
    timer:sleep(10),
    [dummy_node:start_dummy_node(Node) || Node <- NodeIDs],
    
    ?FORALL(Cmds, commands(?MODULE, initial_state({Options, NodeIDs})),
            begin
                setup(Options),
                
                {H, S, Res} = run_commands(?MODULE, Cmds),
                
                cleanup(),
                
                ?WHENFAIL(
                   io:format("~p~n~p~n~p~n", [H,S,Res]),
                   Res =:= ok)
            end).

initial_state({Opts, NodeIDs}) ->
    ARWL = proplists:get_value(arwl, Opts, 6),
    PRWL = proplists:get_value(prwl, Opts, 3),
    ActiveSize = proplists:get_value(active_size, Opts, 5),
    PassiveSize = proplists:get_value(passive_size, Opts, 30),

    #st{nodes=NodeIDs, arwl=ARWL, prwl=PRWL,
        active_size=ActiveSize, passive_size=PassiveSize}.

command(S) ->
    Cmds =
        [[{1, {call, ?MODULE, join_cluster, [elements(S#st.nodes)]}}]],
    
    frequency(lists:flatten(Cmds)).

precondition(_S,{call,_,_,_}) ->
    true.

%% After a join_cluster we expect the contact node to be in the active view,
%% if the active view was full, then we expect a disconnect to be sent
postcondition(S, {call, ?MODULE, join_cluster, [Node]}, _) ->
    Active = hyparerl:get_peers(),
    Disconnect = [N || {disconnect, N} <- test:messages()],
    Join = [N || {join, N} <- test:messages()],
    Join =:= [{join, Node}] andalso
        lists:member(Node, Active) andalso
        case length(S#st.active) =:= S#st.active_size of
            true ->
                length(Disconnect) =:= 1 andalso
                    lists:member(Disconnect, S#st.active);
            false ->
                Disconnect =:= []
        end.

next_state(S,_, {call, ?MODULE, join_cluster, [Node]}) ->
    test:add_node(Node),
    [test:remove_node(D) || {disconnect, D} <- test:messages()],
    test:empty_messages(),
    S#st{active=test:active_view()}.

%% @doc Let the hypar_node join cluster via Node
join_cluster(Node) ->
    hypar_node:join_cluster(Node).

%% @doc Send a join message
join(NewNode) ->
    send(NewNode, {join, NewNode}).

%% @doc Send a forward-join message
forward_join(NewNode, TTL, Sender) ->
    send(Sender, {forward_join, NewNode, TTL, Sender}).

%% @doc Send a reply to a forward-join message
forward_join_reply(Sender) ->
    send(Sender, {forward_join_reply, Sender}).

%% @doc Send a disconnect message
disconnect(Peer) ->
    send(Peer, {disconnect, Peer}).

%% @doc Send a neighbour-request message
neighbour_request(Sender, Priority) ->
    send(Sender, {neighbour_request, Sender, Priority}).

%% @doc Send a neighbour-accept message
neighbour_accept(Sender) ->
    send(Sender, {neighbour_accept, Sender}).

%% @doc Send a neighbour-decline message
neighbour_decline(Sender) ->
    send(Sender, {neighbour_decline, Sender}).

%% @doc Send a shuffle-request message
shuffle_request(XList, TTL, Sender, Ref) ->
    send(Sender, {shuffle_request, XList, TTL, Sender, Ref}).

%% @doc Send a shuffle-reply message
shuffle_reply(Sender, ExchangeList, Ref) ->
    send(Sender, {shuffle_reply, ExchangeList, Ref}).

%% Helpers

is_disconnect({disconnect,_}) -> true;
is_disconnect(_) -> false.

is_join({join,_}) -> true;
is_join(_) -> false.

is_forward_join({forward_join,_,_,_}) -> true;
is_forward_join(_) -> false.

is_forward_join_reply({forward_join_reply,_}) -> true;
is_forward_join_reply(_) -> false.

is_neighbour_request({neighbour_request,_,_}) -> true;
is_neighbour_request(_) -> false.

is_neighbour_accept({neighbour_accept,_}) -> true;
is_neighbour_accept(_) -> false.

is_neighbour_decline({neighbour_decline,_}) -> true;
is_neighbour_decline(_) -> false.

is_shuffle_request({shuffle_request,_,_,_,_}) -> true;
is_shuffle_request(_) -> false.

is_shuffle_reply({shuffle_reply, _, _}) -> true;
is_shuffle_reply(_) -> false.

%% Setup & Clean-up
setup(Options) ->
    setup_meck(),
    {ok,_} = hypar_node:start_link(Options).

cleanup() ->
    Pid = erlang:whereis(hypar_node),
    erlang:unlink(Pid),
    erlang:exit(kill,Pid),
    
    Pid2 = erlang:whereis(test_sup),
    erlang:unlink(Pid2),
    erlang:exit(kill, Pid2),
    
    cleanup_meck().

setup_meck() ->
    %% Mock away ranch call to start listeners
    meck:new(ranch),
    meck:expect(ranch, start_listener, fun(_,_,_,_,_,_) -> {ok, ok} end),
    
    %% Mock away connect
    meck:new(connect),
    
    %% Reroute the sending of control-messages straight to the test-process.
    meck:expect(connect, send_control, fun test:send/2),
    %% To make a new connection we 
    meck:expect(connect, new_connection,
                fun(To, _) ->
                        case erlang:whereis(To) of
                            undefined ->
                                {error, no_connection};
                            Pid ->
                                MRef = erlang:monitor(process, Pid),
                                {ok, Pid, MRef}
                        end            
                end),
    meck:expect(connect, new_temp_connection,
                fun(To, _) ->
                        case erlang:whereis(To) of
                            undefined ->
                                {error, no_connection};
                            Pid ->
                                {ok, Pid}
                        end
                end),
    meck:expect(connect, kill, fun(_) -> ok end),
    true = meck:validate(ranch),
    true = meck:validate(connect).

cleanup_meck() ->
    meck:unload(ranch),
    meck:unload(connect).


%% Dummy send, the node thinks Pid sent the message
send(Sender, Msg) ->
    Pid = erlang:whereis(Sender),
    gen_server:cast(hypar_node, {Msg, Pid}).
