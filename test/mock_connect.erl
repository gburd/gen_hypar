-module(mock_connect).

-behaivour(gen_server).

-export([start_link/2, send_control/2, send_message/2, kill/1]).

-record(conn_st, {to,
                  recipient}).

start_link(Recipient, local, RemoteNode, ThisNode) ->
    Args = [local, RemoteNode, ThisNode, Recipient],
    gen_server:start_link(?MODULE, Args, []).

start_link(Recipient, remote, RemoteNode, ThisNode) ->
    Args = [remote, RemoteNode, ThisNode, Recipient],
    gen_server:start_link(?MODULE, Args, []).

x%% Start a local connection
init([local, ThisNode, RemoteNode, Recipient]) ->
    {ok, Pid} = mock_connect_sup:remote_connection(RemoteNode, ThisNode),
    {ok, #conn_st{to=Pid, recipient=Recipient}};
%% Start a remote connection
init([remote, ThisNode, RemoteEnd, Recipient]) ->
    {ok, #conn_st{to=RemoteEnd, recipient=Recipient}}.

handle_cast({remote, Msg0}, ConnSt) ->
    #conn_st{to=To, recipient=Recipient} = ConnSt,
    
    case Msg0 of
        {control, Msg} ->
            gen_server:cast(hypar_node, {Msg, self()});
        {message, Msg} ->
            gen_server:cast(Recipient, {Msg, self()})
    end;
handle_cast(Msg, ConnSt) ->
    send(ConnSt#conn_st.to, Msg).

send(Pid, Msg) ->
    gen_server:cast(Pid, {remote, Msg}).
