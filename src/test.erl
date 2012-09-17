-module(test).

-compile([export_all]).

-behaviour(gen_server).

-define(SERVER, ?MODULE). 

-record(st, {active=[],
             passive=[],
             pending=[],
             messages=[]
            }).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

get_messages() ->
    gen_server:call(test, get_messages).

add_node(Node) ->
    gen_server:cast(test, {add_node, Node}).

remove_node(Node) ->
    gen_server:cast(test, {remove_node, Node}).

send(_Pid,Msg) ->
    gen_server:cast(?SERVER, Msg).

active_view() ->
    gen_server:call(?SERVER, active_view).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    {ok, #st{}}.

handle_call(get_messages, _From, S) ->
    {reply, S#st.messages, S#st{messages=[]}};
handle_call(active_view, _From, S) ->
    {reply, S#st.active, S};
handle_call(passive_view, _From, S) ->
    {reply, S#st.passive, S}.

handle_cast({add_node, Node}, S) ->
    {noreply, S#st{active=[Node|S#st.active]}};
handle_cast({remove_node, Node}, S) ->
    {noreply, S#st{active=lists:delete(Node, S#st.active)}};
handle_cast({disconnect, Node}, S) ->
    {noreply, S#st{active=lists:delete(Node, S#st.active),
                   passive=[Node|S#st.passive]}};
handle_cast({neighbour_request, S, P}, S) ->
    {noreply, S#st{pending=[{S,P}|S#st.pending]}};
handle_cast(Msg, S) ->
    {noreply, S#st{messages=[Msg|S#st.messages]}}.

handle_info(_Info, State) ->
    {stop, not_used, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
