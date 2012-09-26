-module(eqc_hypar_test).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-include_lib("eunit/include/eunit.hrl").

-include("hyparerl.hrl").

-compile([export_all, debug_info]).

%% Test the node logic
%% Does not test outgoing messages yet

-record(st, {id           = {{127,0,0,1},6000},
             active       = [],
             passive      = [],
             nodes        = [],
             shuffles     = [],
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
    Options1 = proplists:delete(shuffle_period, Options0),
    Options = proplists:delete(shuffle_buffer, Options1),
    
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
                             io:format("Hist: ~p\nState: ~p\n Res: ~p\n", [H, S, Res]),
                             Res == ok
                            )
                      end
                     )).

initial_state(Opts) ->
    ARWL = proplists:get_value(arwl, Opts),
    PRWL = proplists:get_value(prwl, Opts),
    ActiveSize = proplists:get_value(active_size, Opts),
    PassiveSize = proplists:get_value(passive_size, Opts),
    KActive = proplists:get_value(k_active, Opts),
    KPassive = proplists:get_value(k_passive, Opts),
    Id = proplists:get_value(id, Opts),

    #st{arwl=ARWL,prwl=PRWL,active_size=ActiveSize,passive_size=PassiveSize,
        xlistsize = KActive + KPassive, id=Id}.

command(S) when S#st.nodes =:= [] ->
    {call, erlang, make_ref, []};
command(S) ->
    oneof([{call, erlang, make_ref, []},
           {call, hypar_node, shuffle, []},
           {call, hypar_node, neighbour, [elements(S#st.nodes), oneof([low, high])]},
           {call, hypar_node, forward_join_reply, [elements(S#st.nodes)]},
           {call, hypar_node, join, [elements(S#st.nodes)]},
           {call, hypar_node, disconnect, [elements(S#st.nodes)]},
           {call, hypar_node, error, [elements(S#st.nodes), an_error]}] ++
              [{call, hypar_node, shuffle, make_args(elements(S#st.active), elements(S#st.nodes), S)} || S#st.active =/= []] ++
              [{call, hypar_node, shuffle_reply, [elements(S#st.nodes, misc:take_n_random(S#st.xlistsize+1, S#st.nodes), elements(S#st.shuffles)]} || S#st.nodes =/= [], S#st.shuffles =/= []] ++
              [{call, hypar_node, forward_join, [elements(S#st.active), elements(S#st.nodes), choose(0,S#st.arwl)]} || S#st.active =/= []]
         ).

next_state(S, Node, {call, erlang, make_ref, []}) ->
    S#st{nodes=[Node|S#st.nodes]};
next_state(S, _, {call, hypar_node, join, [Node]}) ->
    maybe_disconnect(add_node(Node, S));
next_state(S, _, {call, hypar_node, forward_join, [_, Req, TTL]}) ->
    case TTL =:= 0 orelse length(S#st.active) =:= 1 of
        true  -> maybe_disconnect(add_node(Req, S));
        false -> S
    end;
next_state(S, _, {call, hypar_node, forward_join_reply, [Node]}) ->
    maybe_disconnect(add_node(Node, S));
next_state(S, _, {call, hypar_node, neighbour, [Node, Priority]}) ->
    case Priority of
        high ->
            maybe_disconnect(add_node(Node, S));
        low ->
            case length(S#st.active) < S#st.active_size of
                true -> add_node(Node, S);
                false -> S
            end
    end;
next_state(S, _, {call, hypar_node, shuffle, []}) when S#st.active =:= [] ->
    S;
next_state(S, _, {call, hypar_node, shuffle, []}) ->
    receive {shuffle, Ref} ->
            S#st{shuffles=[Ref|S#st.shuffles]}
    after 0 ->
            S
    end;
next_state(S, _, {call, hypar_node, shuffle, [_,_,_,_,_]}) ->
    S;
next_state(S, _, {call, hypar_node, shuffle_reply, [_, Ref]}) ->
    S#st{shuffles=lists:keydelete(Ref, 1, S#st.shuffles)};
next_state(S, _, {call, hypar_node, disconnect, [Node]}) ->
    delete_node(Node, S);
next_state(S, _, {call, hypar_node, error, [Node, _]}) ->
    maybe_neighbour(delete_node(Node, S)).

precondition(S, {call, hypar_node, shuffle_reply, [_, Ref]}) ->
    lists:member(Ref, S#st.shuffles);
precondition(_S, _C) ->
    true.

postcondition(S, {call, hypar_node, join, [Node]}, {error, already_in_active}) ->
    lists:member(Node, S#st.active);
postcondition(_, {call, hypar_node, join, [Node]}, ok) ->
    %% Node is in active view after join
    in_active_view(Node);
postcondition(S, {call, hypar_node, forward_join, [_, Req, TTL]}, _) ->
    case TTL =:= 0 orelse length(S#st.active) =:= 1 of
        %% The forward join is accepted, node is added.
        true -> 
            in_active_view(Req);
        %% If TTL == PRWL then node should be in passive view
        false ->
            if TTL =:= S#st.prwl ->
                    in_passive_view([Req]);
               true ->
                    true
            end
    end;
postcondition(S, {call, hypar_node, neighbour, [Node, _]}, {error, already_in_active}) ->
    lists:member(Node, S#st.active);
postcondition(S, {call, hypar_node, neighbour, [Node, Priority]}, accept) ->
    in_active_view(Node) andalso
        (Priority =:= high orelse length(S#st.active) < S#st.active_size);
postcondition(S, {call, hypar_node, neighbour, [_, Priority]}, decline) ->
    length(S#st.active) >= S#st.active_size andalso Priority =:= low;
postcondition(S, {call, shuffle, [_, _, XList, TTL, _]}, _) ->
    case TTL =:= 0 orelse length(S#st.active) =:= 1 of
        %% Shuffle accepted
        %% XList should be in passive view
        true -> in_passive_view(XList);
        %% Shuffle propataged
        false -> true
    end;
postcondition(_, {call, hypar_node, shuffle_reply, [ReplyXList, _]}, _) ->
    in_passive_view(ReplyXList);
postcondition(S, {call, hypar_node, error, [Node, _]}, {error, not_in_active}) ->
    not lists:member(Node, S#st.active);
postcondition(_, {call, hypar_node, error, _}, ok) ->
    true;
postcondition(S, {call, hypar_node, disconnect, [Node]}, {error, not_in_active}) ->
    not lists:member(Node, S#st.active);
postcondition(_, {call, hypar_node, disconnect, [Node]}, ok) ->
    not in_active_view(Node);
postcondition(_,_,_) ->
    true.

invariant(S) ->
    lists:usort([P#peer.id || P <- hypar_node:get_peers()]) =:= lists:usort(S#st.active).

make_args(Sender, Requester, S) ->
    [Sender, Requester, [Requester|misc:take_n_random(S#st.xlistsize, lists:delete(Requester, S#st.nodes))], choose(0, S#st.arwl-1), make_ref()].

add_node(Node, S) ->
    S#st{active=lists:usort([Node|S#st.active])}.

delete_node(Node, S) ->
    S#st{active=lists:delete(Node, S#st.active)}.

in_active_view(Node) ->
    lists:keymember(Node, #peer.id, hypar_node:get_peers()).

in_passive_view(Nodes) when is_list(Nodes) ->
    Active = hypar_node:get_peers(),
    Passive = hypar_node:get_passive_peers(),
    lists:all(fun(B) -> B end, [case lists:keymember(Node, #peer.id, Active) of
                                    true -> true;
                                    false ->lists:member(Node, Passive)
                                end|| Node <- Nodes]).

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

mock_connect() ->
    meck:unload(),
    meck:new(connect),

    Init = fun(_) -> ok end,
    Stop = fun() -> ok end,
    Join = fun(_, Id) -> #peer{id=Id, pid=test} end,
    ForwardJoin = fun(_, _, _, _) -> ok end,
    ForwardJoinReply = fun(_, Id) -> #peer{id=Id, pid=test} end,
    Neighbour = fun(_, Id, Priority) ->
                        case Priority of
                            high ->
                                test ! {neighbour, Id},
                                #peer{id=Id, pid=test};
                            low ->
                                case random:uniform(2) of
                                    1 -> 
                                        test ! {neighbour, Id},
                                        #peer{id=Id, pid=test};
                                    2 ->
                                        decline
                                end
                        end
                end,
    Shuffle = fun(_, _, _, _, _, Ref) ->
                      test ! {shuffle, Ref} 
              end,
    ShuffleReply = fun(_, _, _, _) -> ok  end,
    Disconnect = fun(P) -> test ! {disconnect, P#peer.id} end,    
    Terminate = fun(_) -> ok end,
    
    meck:expect(connect, initialize, Init),
    meck:expect(connect, stop, Stop),
    meck:expect(connect, join, Join),
    meck:expect(connect, forward_join, ForwardJoin),
    meck:expect(connect, forward_join_reply, ForwardJoinReply),
    meck:expect(connect, neighbour, Neighbour),
    meck:expect(connect, shuffle, Shuffle),
    meck:expect(connect, shuffle_reply, ShuffleReply),
    meck:expect(connect, disconnect, Disconnect),
    meck:expect(connect, terminate, Terminate).
