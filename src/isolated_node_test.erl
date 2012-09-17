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
        [[{1, {call, ?MODULE, join_cluster, [elements(S#st.nodes)]}},
          {1, {call, ?MODULE, join, [elements(S#st.nodes)]}}] ++
             [{1, {call, dummy_node, kill, [elements(S#st.active)]}} || S#st.active =/= []]],

    frequency(lists:flatten(Cmds)).

precondition(_S,{call,_,_,_}) ->
    true.

postcondition(S, {call, ?MODULE, join_cluster, [Node]}, _) ->
    lists:member(Node, S#st.active) andalso
        [{join, Node}] =:= test:get_messages() andalso
        lists:usort(S#st.active) =:= lists:usort(hyparerl:get_peers());
postcondition(S,{call, ?MODULE, join, [Node]}, _) ->
    FJoins = lists:usort(fun({_,_,_,N1},{_,_,_,N2}) -> N1 =< N2 end,test:get_messages()),
    lists:member(Node, S#st.active) andalso
        length(FJoins) =:= length(S#st.active)
    
    lists:member(Node, S#st.active),

next_state(S,_, {call, ?MODULE, join_cluster, [Node]}) ->
    test:add_node(Node),
    S#st{active=test:active_view()};
next_state(S, _, {call, ?MODULE, join, [Node]}) ->
    test:add_node(Node),
    S#st{active=test:active_view()};
next_state(S, _, {call, ?MODULE, kill, [Node]}) ->
    test:remove_node(Node),
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

%% Setup & Clean-up

setup(Options) ->

    {ok,_} = hypar_node:start_link(Options),    

    setup_meck().

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
