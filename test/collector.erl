%% Collect all calls from hypar_node
-module(collector).

-behaviour(gen_server).

%% API
-export([start_link/0, get_messages/0, stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link(?MODULE, ?MODULE, [], []).

get_messages() ->
    gen_server:call(?MODULE, get_messages).

stop() ->
    gen_server:call(?MODULE, stop).

init([]) ->
    {ok, []}.

handle_call(get_messages, _, Msgs) ->
    {reply, Msgs, []};
handle_call(stop, _, Msgs) ->
    {stop, normal, ok, Msgs};
handle_call(Msg, _, Msgs) ->
    {reply, ok, [Msg|Msgs]}.

handle_cast(_Msg, State) ->
    {stop, not_used, State}.

handle_info(_Info, State) ->
    {stop, not_used, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
