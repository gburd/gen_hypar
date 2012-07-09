%% @doc This module implements the node logic for the HyParView
%%      peer-sampling protocol.
-module(hypar_man).

-behaviour(gen_server).

%% Include files
-include("hyparerl.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

%% State record for the manager
-record(state, {this              :: node(),
                active_view  = [] :: list(active_ent()),
                passive_view = [] :: list(node())
               }).

%% Active entry record
-record(active_ent, {id   :: node(),
                     pid  :: pid(),
                     mref :: reference()
                    }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the hyparview manager in a supervision tree
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
        
init([Options]) ->
    %% Seed the random number generator
    random:seed(now()),

    {init, ContactNode} = 
    if ContactNode =/= first_node ->
       gen_server:cast(self(), {init, ContactNode})
    end,
    {ok, #state{this=}}.

handle_cast({{join, NewNode}, NewPid},  State0=#state{arwl=ARWL}) ->
    MRef = monitor(process, NewPid),
    State = add_node_active({NewNode, NewPid, MRef}, State0),
    ForwardFun = fun({NodeId, Pid}) when NodeId =/= NewNode ->
                         forward_join(Pid, NewNode, ARWL);
                    (_) -> ok
                 end,
    lists:foreach(ForwardFun, State#state.active),
    {noreply, State};
handle_cast({{forward_join, NewNode, TTL}, _Pid}, State0=#state{myself=Myself,
                                                                active=Active})
  when TTL =:= 0 orelse length(Active) =:= 1 ->
    case add_me(NewNode, Myself) of
        {_NewNode, _NewPid, _MRef}=Entry ->
            {noreply, add_node_active(Entry, State0)};
        Err ->
            ?DEBUG(Err),
            {noreply, State0}
    end;
handle_cast({{forward_join, NewNode, TTL}, Pid}, State0=#state{prwl=PRWL}) ->
    State =
        if TTL =:= PRWL ->
                add_node_passive(NewNode, State0);
           true ->
                State0
        end,
    Peers = lists:keydelete(Pid, 2, State#state.active),
    {_RNode, RPid, _RMRef} = random_elem(Peers),
    forward_join(RPid, NewNode, TTL-1),
    {noreply, State};
handle_cast({disconnect, Pid}, State0=#state{active=Active,
                                             passive=Passive}) ->
    State = case lists:keyfind(Pid, 2, Active) of
                false -> State0;
                {Node, Pid, _MRef}=Entry  ->
                    kill(Entry),
                    State0#state{active=lists:keydelete(Pid, 2, Active),
                                 passive=[Node|Passive]}
            end,
    {noreply, State};
handle_cast({{add_me, Node}, Pid}, State) ->
    MRef = monitor(process, Pid),
    {noreply, add_node_active({Node, Pid, MRef}, State)};
handle_cast({init, ContactNode}, State=#state{myself=Myself}) ->
    Entry = join(ContactNode, Myself),
    {noreply, State#state{active=[Entry]}}.

handle_info({'DOWN', MRef, process, _Pid, _Reason},
            State0=#state{active=Active}) ->
    case lists:keymember(MRef, 3, Active) of
        true ->
            State1 = State0#state{active=lists:keydelete(MRef, 3, Active)},
            {noreply, find_new_active(State1)};
        false ->
            {noreply, State0}
    end.

handle_call(_Msg, _From, State) ->
    {stop, not_used, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @doc Add a node to an active view, removing a node if necessary.
%%      The new state is returned. If a node has to be dropped, then
%%      it is informed via a DISCONNECT message.
add_node_active({Node, _Pid, _MRef}=Entry,
                State0=#state{myself=Myself, active=Active,
                              active_size=ActiveSize}) ->
    case Node =/= Myself andalso not lists:keymember(Node, 1, Active) of
        true -> State = case length(Active) >= ActiveSize of
                            true  -> drop_random_active(State0);
                            false -> State0
                        end,
                State#state{active=[Entry|State#state.active]};
        false ->
            State0
    end.

%% @doc Add a node to the passive view, removing random entries if needed
add_node_passive(Node, State=#state{myself=Myself, passive_size=PassiveSize,
                                    active=Active, passive=Passive0}) ->
    case Node =:= Myself andalso 
        not lists:keymember(Node, 1, Active) andalso
        not lists:member(Node, Passive0) of
        true ->
            N = length(Passive0),
            Passive = case N >= PassiveSize of
                          true -> drop_n_random(Passive0, N-PassiveSize);
                          false -> Passive0
                      end,
            State#state{passive=Passive};
        false ->
            State
    end.

%% @doc When a node is thought to have died this function is called.
%%      It will recursively try to find a new neighbour from the passive
%%      view until it finds a good one.
find_new_active(State=#state{myself=Myself, active=Active, passive=Passive}) ->
    Priority = get_priority(Active),
    {NewActiveEntry, NewPassive} = find_neighbour(Priority, Passive, Myself),
    State#state{active = [NewActiveEntry|Active], passive=NewPassive}.

find_neighbour(Priority, Passive, Myself) ->
    find_neighbour(Priority, Passive, Myself, []).

find_neighbour(Priority, Passive, Myself, Tried) ->
    {Node, PassiveRest} = drop_random(Passive),
    case hypar_connect_sup:start_connection(Node, Myself) of
        {Node, _Pid, _MRef}=Entry ->
            case try_neighbour(Entry, Priority) of
                ok -> 
                    {Entry, PassiveRest ++ Tried};
                failed ->
                    kill(Entry),
                    find_neighbour(Priority, PassiveRest, Myself, [Node|Tried])
            end;
        _Err ->
            find_neighbour(Priority, PassiveRest, Myself, Tried)
    end.                

try_neighbour(_Entry, _Priority) ->
    undefined.

get_priority([]) -> high;
get_priority(_)  -> low.

%% @doc Send a join message to a connection-handler
join(ContactNode, Myself) ->
    {ok, Pid, MRef} = hypar_connect_sup:start_connection(ContactNode, Myself),
    hypar_connect:send_message(Pid, {join, Myself}),
    {ContactNode, Pid, MRef}.

%% @doc Send a kill message to a connection-handler
kill({_Node, Pid, MRef}) ->
    demonitor(MRef, [flush]),
    hypar_connect:kill(Pid).

%% @doc Send a forward-join message to a connection-handler
forward_join(Pid, NewNode, TTL) ->
    hypar_connect:send_message(Pid, {forward_join, NewNode, TTL}).

%% @doc Send a disconnect message to a connection-handler
disconnect(Pid, MRef) ->
    hypar_connect:send_message(Pid, disconnect),
    demonitor(MRef, [flush]).

%% @doc Response to a forward_join propagation. Tells the node who
%%      initiated the join to setup a connection
add_me(Node, Myself) ->
    case hypar_connect_sup:start_connection(Node, Myself) of
        {ok, Pid, MRef} ->
            hypar_connect:send_message(Pid, {add_me, Myself}),
            {Node, Pid, MRef};
        Err ->
            Err
    end.

-spec drop_random_active(state()) -> state().
%% @doc Drop a random node from the active view down to the passive view.
%%      Send a DISCONNECT message to the dropped node.
drop_random_active(State=#state{active=Active0, passive=Passive}) ->
    {Active, Dropped} = drop_random(Active0),
    disconnect(Dropped),
    State#state{active=Active, passive=[Dropped#node.id|Passive]}.

-spec drop_random(List :: list(T)) -> {T, list(T)}.
%% @doc Removes a random element from the list, returning
%%      a new list and the dropped element.
drop_random(List) ->
    N = random:uniform(length(List)),
    drop_return(N, List, []).

-spec drop_return(N :: pos_integer(), List :: list(T)) -> {T, list(T)}.
%% @pure
%% @doc Drops the N'th element of a List returning both the dropped element
%%      and the resulting list.
drop_return(1, [H|T], Skipped) ->
    {H, lists:reverse(Skipped) ++ T};
drop_return(N, [H|T], Skipped) ->
    drop_random(N-1, T, [H|Skipped]).

-spec drop_n_random(N :: pos_integer(), List :: list(T)) -> list(T).
%% @doc Removes n random elements from the list
drop_n_random(N, List) ->
    drop_n_random(List, N, length(List)).

%% @doc Helper-function for drop_n_random/2
drop_n_random(List, 0, _Length) ->
    List;
drop_n_random(_List, _N, 0) ->
    [];
drop_n_random(List, N, Length) ->
    I = random:uniform(Length),
    drop_n_random(drop_nth(I, List), N-1, Length-1).

-spec drop_nth(N :: pos_integer(), List :: list(T)) -> list(T).
%% @pure
%% @doc Drop the n'th element of a list, return both list and 
%%      dropped element
drop_nth(_N, []) -> [];
drop_nth(1, [_H|Tail]) -> Tail;
drop_nth(N, [H|Tail]) -> [H|drop_nth(N-1, Tail)].

-spec random_elem(List :: list(T)) -> T.
%% @doc Get a random element of a list
random_elem(List) ->
    I = random:uniform(length(List)),
    lists:nth(I, List).

-spec get_option(Option :: atom(), Options :: list(option())) -> option().
%% @pure
%% @doc Wrapper for keyfind.
get_option(Option, Options) ->
    lists:keyfind(Option, 1, Options).

-spec myself(Options :: list(option())) -> node().
%% @pure
%% @doc Construct "this" node from the options
myself(Options) ->
    #node{ip=get_option(ip, Options), port=get_option(port, Options)}.
