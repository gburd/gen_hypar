%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @private
%% @title Receive peer process
%% @doc This is the receiving peer process. It receives data on the
%%      socket and parses the packets as they come and forwards them
%%      to the control process.
%% -------------------------------------------------------------------
-module(peer_recv).

-behaviour(gen_server).

-export([start_link/4, go_ahead/2, wait_for/2]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2,
         code_change/3]).

-record(state, {peer_ctl,
                socket,
                timeout,
                data}).

start_link(Identifier, Peer, Socket, Timeout) ->
    gen_server:start_link(?MODULE, [Identifier, Peer, Socket, Timeout], []).

go_ahead(RecvPid, Socket) ->
    RecvPid ! {go_ahead, Socket}.

init([Identifier, Peer, Socket, Timeout]) ->
    {ok, CtlPid} = peer_ctl:wait_for(Identifier, Peer),
    yes = register_peer_send(Identifier, Peer),
    {ok, #state{peer_ctl=CtlPid,
                socket=Socket,
                timeout=Timeout,
                data = <<>> }}.

handle_cast(_, S) ->
    {stop, not_used, S}.

handle_call(_, _, S) ->
    {stop, not_used, S}.

handle_info(timeout, S=#state{socket=Socket, timeout=Timeout, data=RestBin}) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Bin} ->
            handle_packet(S, <<RestBin/binary, Bin/binary>>);
        _Err ->
            {stop, normal, S}
    end;
handle_info({go_ahead, Socket}, S=#state{socket=Socket}) ->
    {noreply, S, 0}.

terminate(_, S) ->
    gen_tcp:close(S#state.socket),
    ok.

code_change(_, S, _) ->
    {ok, S}.

register_peer_send(Identifier, Peer) ->
    gen_hypar_util:register_self(name(Identifier, Peer)).

wait_for(Identifier, Peer) ->
    gen_hypar_util:wait_for(name(Identifier, Peer)).

%% @private Name of a receive process
name(Identifier, Peer) ->
    {peer_recv, Identifier, Peer}.

handle_packet(<<>>, S) ->
    {noreply, S, 0};
handle_packet(<<Len:32, Bin/binary>>, S) when byte_size(Bin) >= Len ->
    <<Packet:Len/binary, Rest/binary>> = Bin,
    Msg = proto_wire:decode_msg(Packet),
    peer_ctl:incoming_message(S#state.peer_ctl, Msg),
    handle_packet(Rest, S);
handle_packet(Bin, S) ->
    {noreply, S#state{data=Bin}, 0}.
