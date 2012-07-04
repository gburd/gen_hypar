-module(hypar_connect_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_listener/0, start_connection/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_listener() ->
    supervisor:start_child(?MODULE, []).

start_connection(Node) ->
    supervisor:start_child(?MODULE, [Node]).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init([{IPAddr, Port}=Myself]) ->
    {ok, ListenSocket} = gen_tcp:listen(Port, [{ip, IPAddr},
                                               binary,
                                               {active, once},
                                               {packet, 2},
                                               {keepalive, true}]),
    ConnectionWorkers = {hypar_connect,
                         {hypar_connect, start_link, [ListenSocket, Myself]},
                         temporary, 5000, worker, [hypar_connect]},
    spawn_link(fun empty_listeners/0),
    {ok, {simple_one_for_one, 5, 10}, [ConnectionWorkers]}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

empty_listeners() ->
    [start_listener() || _ <- lists:seq(1,20)].

%% TODO
%% Automatically find out which nic to bind to. As for now it's needed to be configured.

%% @doc Try to find local ip-address.
%%      Start by trying to find a wired ("ethX") then try wlan fallback to loopback.
get_ip_addr() -> undefined.

%% @doc Predicate to filter out all wired nic's
is_wired(Ifname) -> lists:prefix("eth", Ifname).

%% @doc Predicate to filter out all wireless nic's
is_wireless(Ifname) -> lists:prefix("wlan", Ifname).
