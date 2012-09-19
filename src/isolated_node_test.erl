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

-record(st, {active=[], passive=[], nodes=[], dead_nodes=[],
             id, arwl, prwl, active_size, passive_size}).

-define(NUMNODES, 200).

prepare() ->
    eqc:start(),
    application:start(meck),
    timer:sleep(1),
    setup_meck(),
    application:load(hyparerl).

test() ->
    eqc:quickcheck(?MODULE:prop_hypar_node()).

prop_hypar_node() ->
    Options0 = application:get_all_env(hyparerl),
    Options = proplists:delete(shuffle_period, Options0),
    test:start_link(),
    timer:sleep(1),

    NodeIDs = [list_to_atom("node" ++ integer_to_list(X)) ||
                  X <- lists:seq(1,?NUMNODES)],

       ?FORALL(Cmds, commands(?MODULE, initial_state({Options, NodeIDs})),
               ?TRAPEXIT(
                  begin
                      %% Setup & Clean-up
                      test:reset(),
                      hypar_node:start_link(Options),
                      timer:sleep(1),

                      {H, S, Res} = run_commands(?MODULE, Cmds),                     

                      hypar_node:stop(),
                      timer:sleep(1),
                      [kill_node(Node) || Node <- NodeIDs],
                      timer:sleep(1),
                      ?WHENFAIL(
                         io:format("History:~p~nState:~p~nRes:~p~n", [H,S,Res]),
                         Res =:= ok)
                  end)).

initial_state({Opts, NodeIDs}) ->
    ARWL = proplists:get_value(arwl, Opts, 6),
    PRWL = proplists:get_value(prwl, Opts, 3),
    ActiveSize = proplists:get_value(active_size, Opts, 5),
    PassiveSize = proplists:get_value(passive_size, Opts, 30),
    ID = proplists:get_value(id, Opts, {{127,0,0,1},6000}),

    #st{id=ID, arwl=ARWL, prwl=PRWL, dead_nodes=NodeIDs,
        active_size=ActiveSize, passive_size=PassiveSize}.

command(S) ->
    Unjoined = S#st.nodes -- S#st.active,
    Cmds =
        %% We can only try to join via unjoined nodes not in the active view.
        [{call, ?MODULE, join_cluster, [elements(Unjoined)]}        || Unjoined =/= []] ++
        %% Join command, will always be an unjoined nodes due to the nature of TCP
        [{call, ?MODULE, join, [elements(Unjoined)]}                || Unjoined =/= []] ++
        %% Spawn nodes
        [{call, ?MODULE, spawn_node,   [elements(S#st.dead_nodes)]} || S#st.dead_nodes =/= []],
            
    oneof(Cmds).

precondition(_S,{call,_,_,_}) ->
    true.

%% After a join_cluster we expect the contact node to be in the active view,
%% if the active view was full, then we expect a disconnect to be sent
postcondition(S, {call, ?MODULE, join_cluster, [{Node,Pid}]}, _) ->
    Active = hyparerl:get_peers(),
    Passive = hyparerl:get_passive_peers(),
    Join = [N || {{join, N},APid} <- test:messages(), APid =:= Pid],
    Disconnect = [{N,APid} || {{disconnect, N},APid} <- test:messages()],
    all([Join =:= [S#st.id],
         lists:keymember(Node, 1, Active),
         case length(S#st.active) < S#st.active_size of
             true ->
                 Disconnect =:= [];
             false ->
                 {Id, APid} = hd(Disconnect),
                 {ANode, APid} = lists:keyfind(APid, 2, S#st.active),
                 all([lists:member(ANode, Passive),
                      S#st.id =:= Id])
         end]);
postcondition(S, {call, ?MODULE, join, [{Node, _Pid}]}, _) ->
    Active = hyparerl:get_peers(),
    Passive = hyparerl:get_passive_peers(),
    ForwardJoins0 = [APid || {{forward_join, ANode, TTL, Sender},APid} <- test:messages(),
                             ANode =:= Node, TTL =:= S#st.arwl, Sender =:= S#st.id],
    ForwardJoins = lists:usort([lists:keyfind(APid, 2, S#st.active) || APid <- ForwardJoins0]),
    Disconnect = [{N,APid} || {{disconnect, N},APid} <- test:messages()],
    all([lists:keymember(Node, 1, Active),
         lists:usort(S#st.active) =:= ForwardJoins,
         case length(S#st.active) < S#st.active_size of
             true ->
                 Disconnect =:= [];
             false ->
                 {Id, APid} = hd(Disconnect),
                 {ANode, APid} = lists:keyfind(APid, 2, S#st.active),
                 all([lists:member(ANode, Passive),
                      S#st.id =:= Id])
         end]);
postcondition(_S, {call, _, _, _}, _) ->
    true.

next_state(S,Pid, {call, ?MODULE, spawn_node, [Node]}) ->
    S#st{nodes=[{Node, Pid}|S#st.nodes], dead_nodes=lists:delete(Node, S#st.dead_nodes)};
next_state(S,_, {call, ?MODULE, join_cluster, [{Node,Pid}]}) ->
    test:add_node({Node,Pid}),
   [test:remove_node(APid) || {{disconnect, _},APid} <- test:messages()],
    test:empty_messages(),
    S#st{active=test:active_view()};
next_state(S,_, {call, ?MODULE, join, [{Node,Pid}]}) ->
    test:add_node({Node,Pid}),
    [test:remove_node(APid) || {{disconnect, _},APid} <- test:messages()],
    test:empty_messages(),
    S#st{active=test:active_view()}.

invariant(S) ->
    all([lists:usort(hyparerl:get_peers()) =:= lists:usort(S#st.active),
         length(S#st.active) =< S#st.active_size]).

%% @doc Spawn a dummy node
spawn_node(Node) ->
    spawn(?MODULE, dummy_node, [Node]).

%% @doc Let the hypar_node join cluster via Node
join_cluster({Node, _Pid}) ->
    hypar_node:join_cluster(Node).

%% @doc Send a join message
join({NewNode, Pid}) ->
    send(Pid, {join, NewNode}).

%% @doc Send a forward-join message
forward_join({NewNode, Pid}, TTL, Sender) ->
    send(Pid, {forward_join, NewNode, TTL, Sender}).

%% @doc Send a reply to a forward-join message
forward_join_reply({Sender, Pid}) ->
    send(Pid, {forward_join_reply, Sender}).

%% @doc Send a disconnect message
disconnect({Node,Pid}) ->
    send(Pid, {disconnect, Node}).

%% @doc Send a neighbour-request message
neighbour_request({Sender, Pid}, Priority) ->
    send(Pid, {neighbour_request, Sender, Priority}).

%% @doc Send a neighbour-accept message
neighbour_accept({Sender, Pid}) ->
    send(Pid, {neighbour_accept, Sender}).

%% @doc Send a neighbour-decline message
neighbour_decline({Sender, Pid}) ->
    send(Pid, {neighbour_decline, Sender}).

%% @doc Send a shuffle-request message
shuffle_request({Sender, Pid}, XList, TTL, Ref) ->
    send(Pid, {shuffle_request, XList, TTL, Sender, Ref}).

%% @doc Send a shuffle-reply message
shuffle_reply({_Sender, Pid}, ExchangeList, Ref) ->
    send(Pid, {shuffle_reply, ExchangeList, Ref}).

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
    meck:expect(connect, close, fun(_) -> ok end).

%% Dummy send, the node thinks Pid sent the message
send(Pid, Msg) ->
    gen_server:cast(hypar_node, {Msg, Pid}).

dummy_node(Node) ->
    erlang:register(Node, self()),
    receive {kill, Pid} ->
            erlang:unregister(Node),            
            Pid ! ok
    end.

all([]) ->
    true;
all([H|T]) ->
    case H of
        true ->
            all(T);
        false ->
            false
    end.

kill_node(Node) ->
    case catch(Node ! {kill, self()}) of
        kill ->
            receive ok -> ok end;                    
        _ ->
            ok
    end.
            
