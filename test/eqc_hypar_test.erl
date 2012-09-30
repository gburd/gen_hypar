-module(eqc_hypar_test).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-include_lib("eunit/include/eunit.hrl").

-include("hyparerl.hrl").
-include("connect.hrl").

-compile([export_all, debug_info]).

%% Test the node logic

-record(st, {id           = {{127,0,0,1},6000},
             active       = [],
             nodes        = [],
             arwl         = 6,
             prwl         = 3,
             active_size  = 5,
             passive_size = 30,
             xlistsize    = 7
            }).

test() ->
    application:load(hyparerl),
    application:start(meck),
    timer:sleep(1),
    eqc:quickcheck(prop_hypar_node()).

prop_hypar_node() ->
    Options0 = application:get_all_env(hyparerl),
    Options = proplists:delete(shuffle_period, Options0),

    noshrink(
      ?FORALL(Cmds, commands(?MODULE, initial_state(Options)),
              aggregate(command_names(Cmds),
                        begin
                            mock_connect(),
                            register(test, self()),
                            {ok, _} = hypar_node:start_link(Options),
                            {H, S, Res} = run_commands(?MODULE, Cmds),                
                            
                            catch hypar_node:stop(),
                            catch unregister(test),
                            ?WHENFAIL(
                               io:format("Hist: ~p~nState: ~p~n Res: ~p~n", [H, S, Res]),
                               Res == ok
                            )
                        end
                       ))).

command(S) when S#st.nodes =:= [] ->
    {call, erlang, make_ref, []};
command(S) ->
    oneof([{call, erlang, make_ref, []}] ++
              [{call, hypar_node, join, [elements(S#st.nodes)]} || S#st.nodes =/= []] ++
              [{call, hypar_node, join_reply, [elements(S#st.nodes)]} || S#st.nodes =/= []] ++
              [{call, hypar_node, disconnect, [elements(S#st.active)]} || S#st.active =/= []] ++
              [{call, hypar_node, neighbour, [elements(S#st.nodes), oneof([low, high])]} || S#st.nodes =/= []] ++ 
              [{call, hypar_node, error, [elements(S#st.active), an_error]} || S#st.active =/= []]).

next_state(S, Node, {call, erlang, make_ref, []}) ->
    S#st{nodes=[Node|S#st.nodes]};
next_state(S, _, {call, hypar_node, join, [Node]}) ->
    Nodes =  lists:delete(Node, S#st.nodes),
    maybe_disconnect(add_node(Node, S#st{nodes=Nodes}));
next_state(S, _, {call, hypar_node, forward_join, [_, Req, TTL]}) ->
    case TTL =:= 0 orelse length(S#st.active) =:= 1 of
        true  -> maybe_disconnect(add_node(Req, S));
        false -> S
    end;
next_state(S, _, {call, hypar_node, join_reply, [Node]}) ->
    Nodes =  lists:delete(Node, S#st.nodes),
    maybe_disconnect(add_node(Node, S#st{nodes=Nodes}));
next_state(S, _, {call, hypar_node, neighbour, [Node, Priority]}) ->
    Nodes = lists:delete(Node, S#st.nodes),
    case Priority of
        high ->            
            maybe_disconnect(add_node(Node, S#st{nodes=Nodes}));
        low ->
            case length(S#st.active) < S#st.active_size of
                true -> add_node(Node, S#st{nodes=Nodes});
                false -> S
            end
    end;
next_state(S, _, {call, hypar_node, disconnect, [Node]}) ->
    Nodes = [Node|S#st.nodes],
    delete_node(Node, S#st{nodes=Nodes});
next_state(S, _, {call, hypar_node, error, [Node, _]}) ->
    Nodes = [Node|S#st.nodes],
    maybe_neighbour(delete_node(Node, S#st{nodes=Nodes}));
next_state(S, _, {call, hypar_node, shuffle, []}) ->
    receive_shuffle(S);
next_state(S,_,_) ->
    S.

precondition(_,_) ->
    true.

postcondition(S, {call, hypar_node, join, [Node]}, _) ->
    in_active_view(Node) andalso forward_joins_sent(S);
postcondition(_, {call, hypar_node, join_reply, [Node]}, _) ->
    in_active_view(Node);
%% postcondition(S, {call, hypar_node, forward_join, [_, Req, TTL]}, _) ->
%%     case TTL =:= 0 orelse length(S#st.active) =:= 1 of
%%         %% The forward join is accepted, node is added.
%%         true -> in_active_view(Req);
%%         %% If TTL == PRWL then node should be in passive view
%%         false ->
%%             PRWL = if TTL =:= S#st.prwl ->
%%                            in_passive_view([Req]);
%%                       true ->
%%                            true
%%                    end,
%%             PRWL andalso forward_join_propagated()
%%     end;
postcondition(_, {call, hypar_node, neighbour, [Node, high]}, R) ->
    in_active_view(Node) andalso R =:= accept;
postcondition(S, {call, hypar_node, neighbour, [Node, low]}, R) ->
    case length(S#st.active) < S#st.active_size of
        true  -> R =:= accept andalso in_active_view(Node);
        false -> R =:= decline
    end;
%% postcondition(S, {call, hypar_node, shuffle, [_, _, TTL, XList]}, _) ->
%%     case TTL =:= 0 orelse length(S#st.active) =:= 1 of
%%         %% Shuffle accepted
%%         %% XList should be in passive view
%%         true -> in_passive_view(XList) andalso shuffle_reply_sent();
%%         %% Shuffle propataged
%%         false -> shuffle_propagated()
%%     end;
%% postcondition(_, {call, hypar_node, shuffle_reply, [ReplyXList]}, _) ->
%%     in_passive_view(ReplyXList);
postcondition(_, {call, hypar_node, error, [Node, _]}, _) ->
    not in_active_view(Node);
postcondition(_, {call, hypar_node, disconnect, [Node]}, _) ->
    not in_active_view(Node);
postcondition(_,_,_) ->
    true.

invariant(S) ->    
    lists:usort([Node || {Node,_} <- hypar_node:get_peers()]) =:= lists:usort(S#st.active).

initial_state(Opts) ->
    ARWL = proplists:get_value(arwl, Opts),
    PRWL = proplists:get_value(prwl, Opts),
    ActiveSize = proplists:get_value(active_size, Opts),
    PassiveSize = proplists:get_value(passive_size, Opts),
    KActive = proplists:get_value(k_active, Opts),
    KPassive = proplists:get_value(k_passive, Opts),

    #st{arwl=ARWL,
        prwl=PRWL,
        active_size=ActiveSize,
        passive_size=PassiveSize,
        xlistsize=1+KActive+KPassive}.

%% Check that a forward join is propagated
forward_join_propagated() ->
    receive {forward_join, _, _, _} -> true
    after 0 -> false end.

%% Check that forward joins are sent to all members of active view
forward_joins_sent(S) ->
    FJs = receive_forward_joins(),
    case length(S#st.active) < S#st.active_size of
        true  -> length(FJs) =:= length(S#st.active);            
        false -> length(FJs) =:= S#st.active_size-1
    end.

receive_forward_joins() ->
    receive {forward_join, _, _, _}=FJ -> [FJ|receive_forward_joins()]
    after 0 -> [] end.

receive_shuffle(S) ->
    receive {shuffle, _, _, _, _} -> S
    after 0 -> S end.

%% Check that a shuffle is propagated
shuffle_propagated() ->
    receive {shuffle, _, _, _, _} -> true
    after 0 -> false end.

%% Check that a shuffle reply is sent
shuffle_reply_sent() ->
    receive {shuffle_reply, _, _} -> true
    after 0 -> false end.

maybe_disconnect(S) ->
    receive
        {disconnect, Node} ->
            delete_node(Node, S)
    after 0 ->
            S
    end.

maybe_neighbour(S) ->
    receive
        {neighbour, Node} ->
            add_node(Node, S)
    after 0 ->
            S
    end.

%% Add a active node
add_node(Node, S) ->
    S#st{active=lists:usort([Node|S#st.active])}.

%% Remove an active node
delete_node(Node, S) ->
    S#st{active=lists:delete(Node, S#st.active)}.

%% Check if Node is in the current active view
in_active_view(Node) ->
    lists:keymember(Node, 1, hypar_node:get_peers()).

%% Check if Nodes are in the current passive view
in_passive_view(Nodes) when is_list(Nodes) ->
    Active = hypar_node:get_peers(),
    Passive = hypar_node:get_passive_peers(),
    all([case lists:keymember(Node, 1, Active) of
             true -> true;
             false ->lists:member(Node, Passive)
         end || Node <- Nodes]).

%% Create argument generators
make_neighbour_args(S) ->
    InActive = S#st.nodes -- S#st.active,
    [elements(InActive), oneof([low, high])].

make_shuffle_args(S) ->
    ?LET(Sender, elements(S#st.active),
         ?LET(Req, elements(lists:delete(Sender, S#st.nodes)),
              [Sender,
               Req,
               choose(0,S#st.arwl-1),
               xlist(S)               
              ])).

make_forward_join_args(S) ->
    InActive = S#st.nodes -- S#st.active,
    ?LET(Sender, elements(S#st.active),
         [Sender,
          elements(InActive),
          choose(0,S#st.arwl)]).

xlist(S) ->
    Size = 1 + S#st.xlistsize,
    random_n_list(Size, S#st.nodes).

random_n_list(_, []) ->
    [];
random_n_list(0, _) ->
    [];
random_n_list(N, List) ->
    ?LET(Node, elements(List),         
         [Node|random_n_list(N-1, lists:delete(Node, List))]).

%% Random internal functions

all([]) ->
    true;
all([H|T]) -> H andalso all(T).

%% Meck

mock_connect() ->
    meck:unload(),
    meck:new(connect),

    Init = fun(_) -> ok end,
    Stop = fun() -> ok end,
    Terminate = fun(_) -> ok end,
    Join = fun(Id, _) ->
                   {ok, #peer{id=Id, conn=test}}
           end,
    ForwardJoin = fun(Peer, Req, TTL) -> 
                          test ! {forward_join, Peer#peer.id, Req, TTL}
                  end,
    ForwardJoinReply = fun(Id, _) ->
                               {ok, #peer{id=Id, conn=test}}
                       end,
    Neighbour = fun(Id, Priority, _) ->
                        case Priority of
                            high ->
                                test ! {neighbour, Id},
                                {ok, #peer{id=Id, conn=test}};
                            low ->
                                case random:uniform(2) of
                                    1 -> 
                                        test ! {neighbour, Id},
                                        {ok, #peer{id=Id, conn=test}};
                                    2 ->
                                        decline
                                end
                        end
                end,
    Shuffle = fun(Peer, Req, TTL, XList) ->
                      test ! {shuffle, Peer#peer.id, Req, TTL, XList}
              end,
    ShuffleReply = fun(To, XList, _) -> 
                           test ! {shuffle_reply, To, XList}
                   end,
    Disconnect = fun(Peer) ->
                         test ! {disconnect, Peer#peer.id}
                 end,    
    
    meck:expect(connect, initialize, Init),
    meck:expect(connect, stop, Stop),
    meck:expect(connect, join, Join),
    meck:expect(connect, forward_join, ForwardJoin),
    meck:expect(connect, join_reply, ForwardJoinReply),
    meck:expect(connect, neighbour, Neighbour),
    meck:expect(connect, shuffle, Shuffle),
    meck:expect(connect, shuffle_reply, ShuffleReply),
    meck:expect(connect, disconnect, Disconnect),
    meck:expect(connect, terminate, Terminate).
