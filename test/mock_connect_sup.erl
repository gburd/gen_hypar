%% @doc Mocked version of connect_sup, doesn't use TCP
%%      but instead relies on distributed erlang. Good for testing.

-module(mock_connect_sup).

-export([start_connection/2, start_temp_connection/2, remote_connection/2]).

-export([init/1]).

start_connection(RemoteNode, ThisNode) ->
    {ok, Pid} = supervisor:start_child(?MODULE, [local, ThisNode, RemoteNode]),
    MRef = erlang:monitor(process, Pid),
    {ok, Pid, MRef}.

remote_connection(RemoteNode, ThisNode) ->
    {ok, Pid} = supervisor:start_child({?MODULE, RemoteNode}, [remote, RemoteNode, self()]),
    erlang:link(Pid),
    {ok, Pid}.

start_temp_connection(RemoteNode, ThisNode) ->
    supervisor:start_child(?MODULE, [local, RemoteNode, ThisNode]).


init([Recipient, ThisNode]) ->
    ConnectionWorkers = {mock_connect,
                         {mock_connect, start_link, [Recipient]},
                         transient, 5000, worker, [mock_connect]},
    {ok, {{simple_one_for_one, 5, 10}, [ConnectionWorkers]}}.

start_listener() ->
    ok.
