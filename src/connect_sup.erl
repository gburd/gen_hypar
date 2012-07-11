%% @doc Supervisor for the connection handlers

-module(connect_sup).

-behaviour(supervisor).

%% API
-export([start_link/1, start_listener/0, start_connection/2, test/1, test_nodes/0]).

%% Supervisor callbacks
-export([init/1]).

-include("hyparerl.hrl").
-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(Myself) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, Myself).

start_listener() ->
    supervisor:start_child(?MODULE, []).

-spec start_connection(OutNode :: node(), Myself :: node()) ->
                              {ok, pid(), reference()} | {error, any()}.
start_connection(#node{ip=IPAddr, port=Port}, #node{ip=MyIPAddr}) ->
    %% Maybe add a timeout here? The connect might block I think.
    Status = gen_tcp:connect(IPAddr, Port, [{ip, MyIPAddr},
                                            {reuseaddr, true},
                                            binary,
                                            {active, false},
                                            {packet, 2},
                                            {keepalive, true}]),
    case Status of
        {ok, Socket} -> 
            {ok, Pid} = supervisor:start_child(?MODULE, [Socket]),
            gen_tcp:controlling_process(Socket, Pid),
            MRef = monitor(process, Pid),
            {ok, Pid, MRef};
        Err ->
            Err
    end.

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init(#node{ip=IPAddr, port=Port}) ->
    {ok, ListenSocket} = gen_tcp:listen(Port, [{ip, IPAddr},
                                               {reuseaddr, true},
                                               binary,
                                               {active, once},
                                               {packet, 2},
                                               {keepalive, true}]),
    ConnectionWorkers = {connect,
                         {connect, start_link, [ListenSocket]},
                         temporary, 5000, worker, [connect]},
    spawn_link(fun empty_listeners/0),
    {ok, {{simple_one_for_one, 5, 10}, [ConnectionWorkers]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec empty_listeners() -> ok.
%% @doc Start 20 idle listeners
empty_listeners() ->
    [start_listener() || _ <- lists:seq(1,20)],
    ok.


%% TEST CODE
test_nodes() ->
    IP = {127,0,0,1},
    {#node{ip=IP, port=6000}, #node{ip=IP, port=6001}}.

test(Ind) ->
    register(hypar_man, self()),
    {A,B} = test_nodes(),
    {C,D} = case Ind of
                true -> {A,B};
                false -> {B,A}
            end,
    {ok, Pid} = connect_sup:start_link(C),
    {Pid, C, D}.
