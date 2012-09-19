-module(dummy_node).

-behaviour(gen_server).

-compile([export_all]).

%%%===================================================================
%%% API
%%%===================================================================
start_link(Node) ->
    gen_server:start_link({local, Node}, ?MODULE, [], []).


start_dummy_node(Node) ->
    {ok, Pid} = supervisor:start_child(dummy_sup, [Node]),
    Pid.

kill(Node) ->
    Node ! kill.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    {ok, []}.

handle_call(_Req, _From, State) ->
    {stop, not_used, State}.

handle_cast(_Req, State) ->
    {stop, not_used, State}.

handle_info(kill, State) ->
    {stop, kill, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
