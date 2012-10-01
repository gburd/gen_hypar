%% @todo Could be cool to make a unique-nodes generator. That generates different worlds each test.
%%       Another addition would be a options-generator that tries all different options.
-module(eqc_hypar_test2).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-include_lib("eunit/include/eunit.hrl").

-include("hyparerl.hrl").
-include("connect.hrl").

-compile([export_all, debug_info]).

-define(TIMEOUT, 10000).

-define(link_up(To), {'$gen_cast', {link_up, To, _}}).
-define(link_down(To), {'$gen_cast', {link_down, To}}).

-record(st, {id,
             active = [],
             nodes = [],
             arwl,
             prwl,
             active_size}).

test() ->
    application:start(ranch),
    lager:start(),
    eqc:quickcheck(?MODULE:prop_hypar_test()).

prop_hypar_test() ->
    ?FORALL(Cmds, commands(?MODULE),
            begin
                register(test, self()),
                {ok, _} = hypar_node:start_link(options()),

                timer:sleep(1),
                
                {H,S,Res} = run_commands(?MODULE, Cmds),
                
                catch hypar_node:stop(),
                catch connect:stop(),
                catch unregister(test),
                
                ?WHENFAIL(
                   io:format("Hist: ~p~nState: ~p~n Res: ~p~n", [H, S, Res]),
                   Res == ok
                  )
            end).

precondition(_S,_C) ->
    true.

postcondition(_, {call, _, join, [{Id, _}]}, _) ->
    receive ?link_up(Id) -> true
    after ?TIMEOUT -> false
    end;
postcondition(_S, _C, _R) ->
    true.

invariant(S) ->
    Active = [Node || {Node, _} <- hyparerl:get_peers()],
    lists:usort([Node || {Node,_,_} <- S#st.active]) =:= lists:usort(Active)
        andalso length(Active) =< S#st.active_size.

command(S) when S#neighbour_request =/= undefined ->
    {call, }
command(S) ->
    Cmds =
        [{call, ?MODULE, spawn_node, []}] ++
        [{call, ?MODULE, join, [elements(S#st.nodes)]} || S#st.nodes =/= []] ++
        [{call, ?MODULE, kill_active, [elements(S#st.active), S#st.nodes]} || S#st.active =/= []],
    oneof(Cmds).

next_state(S, Node, {call, _, spawn_node, []}) ->
    add_node(Node, S);
next_state(S, A, {call, _, join, [Node]}) ->
    maybe_disconnect(remove_node(Node, add_active(A, S)));
next_state(S, NewActive, {call, _, kill_active, [Active]}) ->
    add_active(NewActive, add_node(Node, remove_active(Active, S))).

add_active(Active, S) ->
    S#st{active=[Active|S#st.active]}.

remove_active(Active, S) ->
    S#st{active=lists:delete(Active, S#st.active)}.

add_node(Node, S) ->
    S#st{nodes=[Node|S#st.nodes]}.

remove_node(Node, S) ->
    S#st{nodes=lists:delete(Node, S#st.nodes)}.

spawn_node() ->
    Ip = {127,0,0,1},
    {ok, LSock} = gen_tcp:listen(0, [{reuseaddr, true}, binary, {ip, Ip},
                                     {active, false}, {packet, raw}]),
    {ok, Port} = inet:port(LSock),
    {{Ip,Port}, LSock}.

kill_active({Id, Sock, LSock}, Nodes) ->
    gen_tcp:close(Sock),
    {Id, LSock}.

find_neighbour([]) ->
    none

join({Id, LSock}) ->
    BinaryId = hyparerl:encode_id(Id),
    Sock = start_conn(),
    ok = gen_tcp:send(Sock, <<?JOIN, BinaryId:6/binary>>),
    {Id, Sock, LSock}.

start_conn() ->
    {ok, S} = gen_tcp:connect({127,0,0,1}, 6000, [{reuseaddr, true}, binary, {packet, raw}]),
    S.

maybe_disconnect(S) ->
    receive
        ?link_down(Id) ->
            {Id, Sock, LSock} = lists:keyfind(Id, 1, S#st.active),
            gen_tcp:close(Sock),
            S#st{active=lists:keydelete(Id, 1, S#st.active),
                 nodes=[{Id, LSock}|S#st.nodes]}
    after 0 ->
            S
    end.

maybe_neighbour(S) ->
    receive
        ?link_up(Id) ->
            Node = lists:keyfind(Id, 1, 
        ?link_down(Id) ->
            S
    after 0 ->
            S
    end


initial_state() ->
    Opts = options(),
    
    #st{id = proplists:get_value(id, Opts),
        nodes = [],
        arwl = proplists:get_value(arwl, Opts),
        prwl = proplists:get_value(prwl, Opts),
        active_size = proplists:get_value(active_size, Opts)
       }.

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
     {target, test}].

parse_xlist(0, <<>>) ->
    [];
parse_xlist(N, Bin) ->
    <<BId:6/binary, Rest/binary>> = Bin,
    [BId|parse_xlist(N-1,Rest)].
