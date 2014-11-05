-module(hypar_test_eqc).

-ifdef(TEST).
-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("gen_hypar.hrl").

-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) ->
                               io:format(user, Str, Args) end, P)).
-compile(export_all).

%% @doc  QuickCheck tests for the gen_hypar module

%% Test the node logic

-record(st, {id,
             active = [],
             arwl,
             prwl,
             active_size,
             passive_size,
             xlistsize
            }).

%% Shortcut
test() ->
    application:load(gen_hypar),
    application:start(meck),
    timer:sleep(1),
    eqc:quickcheck(prop_hypar_node()).

%% Property
prop_hypar_node() ->
      ?FORALL(Cmds, commands(?MODULE),
              aggregate(command_names(Cmds),
                        begin
                            mock_connect(),
                            register(test, self()),

                            {ok, _} = hypar_node:start_link(options()),
                            {H, S, Res} = run_commands(?MODULE, Cmds),

                            catch hypar_node:stop(),
                            catch unregister(test),
                            ?WHENFAIL(
                               io:format("Hist: ~p~nState: ~p~n Res: ~p~n", [H, S, Res]),
                               Res == ok
                            )
                        end
                       )).

%% Commands
command(S) ->
    oneof([{call, ?MODULE, join, []},
           {call, ?MODULE, join_reply, []},
           {call, hypar_node, shuffle_reply, [xlist(S#st.xlistsize+1)]},
           {call, ?MODULE, neighbour, [oneof([low, high])]}] ++
              [{call, ?MODULE, forward_join, [elements(S#st.active), choose(0,S#st.arwl)]} || S#st.active =/= []] ++
              [{call, hypar_node, shuffle,
                make_shuffle_args(elements(S#st.active), choose(0,S#st.arwl-1), S#st.xlistsize)} || S#st.active =/= []] ++
              [{call, hypar_node, disconnect, [elements(S#st.active)]} || S#st.active =/= []] ++
              [{call, hypar_node, error, [elements(S#st.active), eqc_error]} || S#st.active =/= []]).

%% Next state
next_state(S, Node, {call, _, join, []}) ->
    maybe_disconnect(add_node(Node, S));
next_state(S, Node, {call, _, join_reply, []}) ->
    maybe_disconnect(add_node(Node, S));
next_state(S, ReqNode, {call, _, forward_join, [_, TTL]}) ->
    case length(S#st.active) =:= 1 orelse TTL =:= 0 of
        true  -> maybe_disconnect(add_node(ReqNode, S));
        false -> S
    end;
next_state(S, Node, {call, _, neighbour, [high]}) ->
    maybe_disconnect(add_node(Node, S));
next_state(S, Node, {call, _, neighbour, [low]}) ->
    case length(S#st.active) < S#st.active_size of
        true  -> add_node(Node, S);
        false -> S
    end;
next_state(S, _, {call, _, disconnect, [Node]}) ->
    delete_node(Node, S);
next_state(S, _, {call, _, error, [Node, _]}) ->
    maybe_neighbour(delete_node(Node, S));
next_state(S,_,_) ->
    S.

%% Postconditions
postcondition(S, {call, _, join, []}, Node) ->
    in_active_view(Node) andalso forward_joins_sent(S, Node);
postcondition(_, {call, _, join_reply, []}, Node) ->
    in_active_view(Node);
postcondition(S, {call, _, forward_join, [Node, TTL]}, ReqNode) ->
    case length(S#st.active) =:= 1 orelse TTL =:= 0 of
        true  ->
            in_active_view(ReqNode);
        false ->
            PRWL = case TTL =:= S#st.prwl of
                       true -> in_passive_view([ReqNode]);
                       false -> true
                   end,
            PRWL andalso forward_join_propagated(Node, ReqNode, TTL)
    end;
postcondition(_, {call, _, neighbour, [high]}, Node) ->
    in_active_view(Node);
postcondition(S, {call, _, neighbour, [low]}, Node) ->
    case length(S#st.active) < S#st.active_size of
        true  -> in_active_view(Node);
        false -> Node =:= decline
    end;
postcondition(_, {call, _, disconnect, [Node]}, _) ->
    not in_active_view(Node) andalso in_passive_view([Node]);
postcondition(_, {call, _, error, [Node, _]}, _) ->
    not in_active_view(Node);
postcondition(S, {call, _, shuffle, [Node, Req, TTL, XList]}, _) ->
    case TTL > 0 andalso length(S#st.active) > 1 of
        true  -> shuffle_propagated(Node, Req, TTL, XList);
        false -> in_passive_view(XList) andalso
                     shuffle_reply_received(Req)
    end;
postcondition(_, {call, _, shuffle_reply, [XList]}, _) ->
    in_passive_view(XList).

dynamic_precondition(S, {call, _, shuffle, [Node, _, _, _]}) ->
    lists:member(Node, S#st.active);
dynamic_precondition(S, {call, _, forward_join, [Node, _]}) ->
    lists:member(Node, S#st.active);
dynamic_precondition(S, {call, _, disconnect, [Node]}) ->
    lists:member(Node, S#st.active);
dynamic_precondition(S, {call, _, error, [Node, _]}) ->
    lists:member(Node, S#st.active);
dynamic_precondition(_,_) ->
    true.

precondition(_,_) ->
    true.

invariant(S) ->
    Active = lists:usort([Node || {Node,_} <- hypar_node:get_peers()]),
    Model = lists:usort(S#st.active),
    Active =:= Model andalso
        length(Active) =< S#st.active_size.

%% Do a join
join() ->
    NodeId = make_node_id(),
    ok = hypar_node:join(NodeId),
    NodeId.

%% Do a join-reply
join_reply() ->
    NodeId = make_node_id(),
    ok = hypar_node:join_reply(NodeId),
    NodeId.

%% Do a forward-join
forward_join(Node, TTL) ->
    ReqId = make_ref(),
    ok = hypar_node:forward_join(Node, ReqId, TTL),
    ReqId.

%% Do a neighbour request
neighbour(Priority) ->
    NodeId = make_node_id(),
    case hypar_node:neighbour(NodeId, Priority) of
        accept  -> NodeId;
        decline -> decline
    end.

make_shuffle_args(Node, TTL, Size) ->
    Req = make_node_id(),
    XList = [Req|xlist(Size)],
    [Node, Req, TTL, XList].

%% Check if a disconnect has been sent
maybe_disconnect(S) ->
    receive {disconnect, DiscNode} ->
            delete_node(DiscNode, S)
    after 0 ->
            S
    end.

%% After an error, check if the hypar_node has found a new neighbour
maybe_neighbour(S) ->
    receive {neighbour, Node} ->
            add_node(Node, S)
    after 0 ->
            S
    end.

%% Check if Node is in the current active view
in_active_view(Node) ->
    lists:keymember(Node, 1, hypar_node:get_peers()).

%% Check if Nodes are in the current passive view
in_passive_view(Nodes) ->
    Active = hypar_node:get_peers(),
    Passive = hypar_node:get_passive_peers(),
    all([case lists:keymember(Node, 1, Active) of
             true -> true;
             false ->lists:member(Node, Passive)
         end || Node <- Nodes]).

%% Check that the node send out corrent forward-joins on a join
forward_joins_sent(S, Node) ->
    TTL = S#st.arwl,
    F = fun(To) ->
                receive
                    {forward_join, To, Node, TTL} ->
                        true
                after 0 ->
                        false
                end
        end,
    all(lists:map(F, [To || {To, _} <- hyparerl:get_peers(), To =/= Node])).

%% Check that the forward-join is propagated with correct arguments
forward_join_propagated(Node, Req, TTL0) ->
    TTL = TTL0-1,
    receive
        {forward_join, To, Req, TTL} ->
            To =/= Node andalso in_active_view(To)
    after 0 ->
            false
    end.

shuffle_propagated(Node, Req, TTL, XList) ->
    receive
        {shuffle, To, R, TTL0, XList0} ->
            To =/= Node andalso in_active_view(To) andalso R =:= Req andalso
                TTL0 =:= TTL-1 andalso XList =:= XList0
    after 0 ->
            false
    end.

shuffle_reply_received(Req) ->
    receive
        {shuffle_reply, R, _} ->
            R =:= Req
    after 0 ->
            false
    end.

%% Create a unique node identifier(reference)
make_node_id() -> make_ref().

%% Create a list of Size identifiers.
xlist(Size) -> [make_node_id() || _ <- lists:seq(1, Size)].

%% Add a active node
add_node(Node, S) -> S#st{active=lists:usort([Node|S#st.active])}.

%% Remove an active node
delete_node(Node, S) -> S#st{active=lists:delete(Node, S#st.active)}.

all([]) -> true;
all([H|T]) -> H andalso all(T).

%% Callbacks
deliver(_Sender, _Bin) ->
    ok.

link_up(_To, _) ->
    ok.

link_down(_To) ->
    ok.

initial_state() ->
    Opts = options(),
    KActive = proplists:get_value(k_active, Opts),
    KPassive = proplists:get_value(k_passive, Opts),
    Size = KActive+KPassive,
    #st{id=proplists:get_value(id, Opts),
        arwl=proplists:get_value(arwl, Opts),
        prwl=proplists:get_value(prwl, Opts),
        active_size=proplists:get_value(active_size, Opts),
        passive_size=proplists:get_value(passive_size, Opts),
        xlistsize=Size}.

%% Default test options
options() ->
    [{id, {{127,0,0,1}, 6000}},
     {arwl, 6},
     {prwl, 3},
     {active_size, 5},
     {passive_size, 30},
     {k_active, 3},
     {k_passive, 4},
     {timeout, infinity},
     {send_timeout, infinity},
     {target, eqc_hypar_test}].

-record(peer, {id, conn}).

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

%%====================================================================
%% Helpers
%%====================================================================

test() ->

    test(100).

test(N) ->

    quickcheck(numtests(N, prop_chash_next_index())).

check() ->

    check(prop_chash_next_index(), current_counterexample()).

-include("eqc_helper.hrl").
-endif.
-endif.
