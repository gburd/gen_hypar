-module(test).

-compile([export_all]).

-behaviour(gen_server).

-record(st, {active=[],
             passive=[],
             pending=[],
             messages=[]
            }).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    gen_server:start_link({local, test}, ?MODULE, [], []).

reset() ->
    gen_server:call(test, reset).

messages() ->
    gen_server:call(test, messages).

empty_messages() ->
    gen_server:call(test, empty_messages).

add_node(Node) ->
    gen_server:cast(test, {add_node, Node}).

remove_node(Node) ->
    gen_server:cast(test, {remove_node, Node}).

send(Pid,Msg) ->
    gen_server:cast(test, {Msg, Pid}).

active_view() ->
    gen_server:call(test, active_view).

passive_view() ->
    gen_server:call(test, passive_view).

add_pending(Node) ->
    gen_server:cast(test, {add_pending, Node}).

remove_pending(Node) ->
    gen_server:cast(test, {remove_pending, Node}).

pending() ->
    gen_server:call(test, pending).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    {ok, #st{}}.

handle_call(reset, _From, _) ->
    {reply, ok, #st{}};
handle_call(messages, _From, S) ->
    {reply, S#st.messages, S};
handle_call(empty_messages, _From, S) ->
    {reply, ok, S#st{messages=[]}};
handle_call(active_view, _From, S) ->
    {reply, S#st.active, S};
handle_call(passive_view, _From, S) ->
    {reply, S#st.passive, S};
handle_call(pending, _From, S) ->
    {reply, S#st.pending, S}.

handle_cast({add_node, NodePid}, S) ->
    {noreply, S#st{active=lists:usort([NodePid|S#st.active])}};
handle_cast({remove_node, Pid}, S) ->
    {noreply, S#st{active=lists:keydelete(Pid, 2, S#st.active)}};
handle_cast({add_pending, NodePid}, S) ->
    {noreply, S#st{pending=[NodePid|S#st.pending]}};
handle_cast({remove_pending, Node}, S) ->
    {noreply, S#st{pending=lists:keydelete(Node, 1, S#st.pending)}};
handle_cast(Msg, S) ->
    {noreply, S#st{messages=[Msg|S#st.messages]}}.

handle_info(_, State) ->
    {stop, not_used, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
