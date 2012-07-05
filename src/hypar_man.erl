-module(hypar_man).
-compile([export_all]).
-behaviour(gen_server).

%% Include files
-include("hyparerl.hrl").

%% API
-export([start_link/0, deliver_msg/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 


%% State record for the manager
-record(state, {myself       :: node_id(),
                active  = [] :: list({node_id(), pid()}),
                passive = [] :: list(node_id()),
                active_size  :: pos_integer(),
                passive_size :: pos_integer(),
                arwl         :: pos_integer(),
                prwl         :: pos_integer(),
                k_active     :: pos_integer(),
                k_passive    :: pos_integer()
               }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Starts the hyparview manager in a supervision tree
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Delivers a message from the connection-handlers to the manager
%%      Piggybacked with the pid.
deliver_msg(Msg) ->
    gen_server:cast(?SERVER, {Msg, self()}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
        
init([Options]) ->
    %% Seed the random number generator
    random:seed(now()),

    {init, ContactNode} = lists:keyfind(init, 1, Options),
    if ContactNode =/= first_node ->
       gen_server:cast(self(), {init, ContactNode})
    end,
    {ok, initialize_state(Options)}.

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
                {Node, Pid, MRef}=Entry  ->
                    kill(Entry),
                    State0#state{active=lists:keydelete(Pid, 2, Active),
                                 passive=[Node|Passive]};
                
            end,
    {noreply, State};
handle_cast({{add_me, Node}, Pid}, State) ->
    MRef = monitor(process, Pid),
    {noreply, add_node_active({Node, Pid, MRef}, State)};
handle_cast({init, ContactNode}, State=#state{myself=Myself}) ->
    Entry = join(ContactNode, Myself),
    {noreply, State#state{active=[Entry]}}.

handle_info({'DOWN', MRef, process, Pid, _Reason},
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
find_new_active(State=#state{active=Active, passive=Passive}) ->
    Priority = get_priority(Active),
    {NewActiveEntry, NewPassive} = find_neighbour(Priority, Passive, Myself),
    State#state{active = [NewActiveEntry|Active], passive=NewPassive}.

find_neighbour(Priority, Passive, Myself) ->
    find_neighbour(Priority, Passive, Myself, []).

find_neighbour(Priority, Passive, Myself, Tried) ->
    {Node, PassiveRest} = drop_random(Passive),
    case hypar_connect_sup:start_connection(Node, Myself) of
        {Node, Pid, MRef}=Entry ->
            case try_neigbour(Entry, Priority) of
                ok -> 
                    {Entry, PassiveRest ++ Tried};
                failed ->
                    kill(Entry),
                    find_neighbour(Priority, PassiveRest, Myself, [Node|Tried])
            end;
        Err ->
            find_neighbour(Priority, PassiveRest, Myself, Tried)
    end.                

try_neighbour

get_priority([]) -> high;
get_priority(_)  -> low.

neighbour_request(Pid, Priority) ->
    

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

%% @doc Drop a random node from the active view down to the passive view.
%%      Send a DISCONNECT message to the dropped node.
drop_random_active(State=#state{active=Active0}) ->
    {Active, Dropped} = drop_random(Active0),
    {DNode, DPid, DMRef} = Dropped,
    disconnect(DPid, DMRef),
    State#state{active=Active, passive=[DNode|State#state.passive]}.

%% @doc Removes a random element from the list, returning
%%      a new list and the dropped element. (Fix, no need to traverse twice)
drop_random(List) ->
    N = random:uniform(length(List)),
    {drop_nth(N, List), lists:nth(N, List)}.

%% @doc Removes n random elements from the list
drop_n_random(List, N) ->
    drop_n_random(List, N, length(List)).

drop_n_random(List, 0, _Length) ->
    List;
drop_n_random(_List, _N, 0) ->
    [];
drop_n_random(List, N, Length) ->
    I = random:uniform(Length),
    drop_n_random(drop_nth(I, List), N-1, Length-1).

%% @doc Drop the n'th element of a list, return both list and 
%%      dropped element
drop_nth(_N, []) -> [];
drop_nth(1, [_H|Tail]) -> Tail;
drop_nth(N, [H|Tail]) -> [H|drop_nth(N-1, Tail)].

%% @doc Get a random element of a list
random_elem(List) ->
    I = random:uniform(length(List)),
    lists:nth(I, List).

%% @doc Initialize the state structure from passed down options
initialize_state(Options) ->
    IPAddr = lists:keyfind(ipaddr, 1, Options),
    Port   = lists:keyfind(port, 1, Options),
    Myself = {IPAddr, Port},
    #state{myself       = Myself,
           active_size  = lists:keyfind(active_size, 1, Options),
           passive_size = lists:keyfind(passive_size, 1, Options),
           arwl         = lists:keyfind(arwl, 1, Options),
           prwl         = lists:keyfind(prwl, 1, Options),
           k_active     = lists:keyfind(k_active, 1, Options),
           k_passive    = lists:keyfind(k_passive, 1, Options)
          }.
