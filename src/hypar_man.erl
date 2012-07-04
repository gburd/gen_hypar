%%%-------------------------------------------------------------------
%%% @author Emil Falk <emil.falk.1988@gmail.com>
%%% @copyright (C) 2012, Emil Falk
%%% @doc
%%% This module implements a HyPar-view node
%%% @end
%%%-------------------------------------------------------------------
-module(hypar_man).
-compile([export_all]).
-behaviour(gen_server).

%% Include files
-include("hyparerl.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the hyparview manager in a supervision tree
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Options]) ->
    % Seed the random number generator
    random:seed(now()),
    State = initialize_state(Options),
    {init, Initial} = lists:keyfind(init, 1, Options),
    case Initial of
        first_node -> Active = [];
        ContactNode ->
            {ok, Pid} = hypar_connect_sup:start_connection(ContactNode),
            hypar_connect:join(Pid),
            Active = [{ContactNode, Pid}]
    end,
    {ok, State#state{active=Active}}.

handle_cast({join, NewNode, NewPid},  State0=#state{arwl=ARWL}) ->
    State = add_node_active(NewNode, NewPid, State0),
    ForwardFun = fun({NodeId, Pid}) when NodeId =/= NewNode ->
                         hypar_connect:forward_join(Pid, NewNode, ARWL);
                    (_) -> ok
                 end,
    lists:foreach(ForwardFun, State#state.active),
    {noreply, State};
handle_cast({forward_join, NewNode, TTL, Pid}, State0=#state{active=Active})
  when TTL =:= 0 orelse length(Active) =:= 1 ->
    {ok, NewPid} = hypar_connect_sup:start_connection(NewNode),
    hypar_connect:add_me(NewPid),
    State = add_node_active(NewNode, NewPid, State0),
    {noreply, State};
handle_cast({forward_join, NewNode, TTL, Pid}, State0=#state{prwl=PRWL}) ->
    State =
        if TTL =:= PRWL ->
                add_node_passive(NewNode, State0);
           true ->
                State0
        end,
    Peers = lists:keydelete(Pid, 2, State#state.active),
    {_RandomNode, RandomPid} = random_elem(Peers),
    hypar_connect:forward_join(RandomPid, NewNode, TTL-1),
    {noreply, State};
handle_cast({disconnect, Node}, State0=#state{active=Active,
                                              passive=Passive}) ->
    State = case lists:keymember(Node, 1, Active) of
                true  -> State0#state{active=lists:keydelete(Node, 1, Active),
                                      passive=[Node|Passive]};
                false -> State0
            end,
    {noreply, State};
handle_cast({add_me, Node, Pid}, State) ->
    {noreply, add_node_active(Node, Pid, State)}.

handle_info(_Info, State) ->
    {stop, not_used, State}.

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
add_node_active(Node, Pid, State0=#state{myself=Myself, active=Active,
                                         active_size=ActiveSize}) ->
  case Node =/= Myself andalso not lists:keymember(Node, 1, Active) of
      true -> State = case length(Active) >= ActiveSize of
                          true  -> drop_random_active(State0);
                          false -> State0
                      end,
              State#state{active=[{Node, Pid}|State#state.active]};
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

%% @doc Drop a random node from the active view down to the passive view.
%%      Send a DISCONNECT message to the dropped node.
drop_random_active(State=#state{active=Active0}) ->
    {Active, Dropped} = drop_random(Active0),
    {DNode, DPid} = Dropped,
    hypar_connect:disconnect(DPid),
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
drop_n_random(List, N, 0) ->
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
