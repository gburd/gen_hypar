-module(hypar_connect_sup).

-behaviour(supervisor).

%% API
-export([start_link/1, start_listener/0, start_connection/2]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link(Myself) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [Myself]).

start_listener() ->
    supervisor:start_child(?MODULE, []).

start_connection(Node, Myself) ->
    {IPAddr, Port} = Node,
    {MyIPAddr, _MyPort} = Myself,
    %% Maybe add a timeout here? The connect might block I think.
    Status = gen_tcp:connect(IPAddr, Port, [{ip, MyIPAddr},
                                            binary,
                                            {active, once},
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
    {ok, {{simple_one_for_one, 5, 10}, [ConnectionWorkers]}}.

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
