%% -------------------------------------------------------------------
%% Copyright (c) 2012 Emil Falk  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%%%-------------------------------------------------------------------
%%% @author Emil Falk <emil.falk.1988@gmail.com>
%%% @copyright (C) 2012, Emil Falk
%%% @title HyParView API
%%% @doc Interface module to the HyParView peer samling service
%%%-------------------------------------------------------------------
-module(hyparerl).

%% Operations
-export([start/3, start_local/2, join_cluster/1, shuffle/0]).

%% View
-export([get_peers/0, get_passive_peers/0]).

%% Send
-export([send/2]).

%% Identifier
-export([encode_id/1, decode_id/1]).

%% Testing
-export([local_id/1, join_local/1]).

%%%%%%%%%
%% API %%
%%%%%%%%%

%%%%%%%%%%%%%%%%
%% Operations %%
%%%%%%%%%%%%%%%%

start_local(Port, Target) ->
    start({127,0,0,1}, Port, Target).

%% @doc Start the hyparerl application at <em>IP:Port<em>. All messages received
%%      from the overlay is sent to <em>Target</em>. The target process is also
%%      notified when link changes happen with {link_up, {IP,Port}, Pid} and
%%      {link_down, {IP,Port}}. Use hyparerl:send(Conn, Bin) to send binary data
%%      to a peer.
start(IP, Port, Target) ->
    lager:start(),
    application:start(ranch),
    timer:sleep(100),

    Id = {IP, Port},
    application:load(hyparerl),
    application:set_env(hyparerl, id, Id),
    application:set_env(hyparerl, target, Target),
    application:start(hyparerl).

%% @doc Join a cluster via <em>ContactNode</em>.
join_cluster(ContactNode) ->
    hypar_node:join_cluster(ContactNode).

%% @doc Initate a shuffle request
shuffle() ->
    hypar_node:shuffle().

%%%%%%%%%%
%% View %%
%%%%%%%%%%

%% @doc Retrive all current active peers
get_peers() ->
    hypar_node:get_peers().

%% @doc Retrive all current passive peers
get_passive_peers() ->
    hypar_node:get_passive_peers().

%%%%%%%%%%%%%
%% Sending %%
%%%%%%%%%%%%%

%% @doc Send a binary message <em>Bin</em> over connection <em>Conn</em>.
send(Conn, Bin) ->
    connect:send(Conn, Bin).

%%%%%%%%%%%%%%%%
%% Identifier %%
%%%%%%%%%%%%%%%%

%% @doc Encode an identifier <em>Id</em> into a binary.
encode_id(Id) ->
    connect:encode_id(Id).

%% @doc Decode a binary <em>BId</em> into an identifier.
decode_id(BId) ->
    connect:decode_id(BId).

%%%%%%%%%%%%%
%% Testing %%
%%%%%%%%%%%%%

%% @doc Local identifier
local_id(Port) ->
    {{127,0,0,1}, Port}.

%% @doc Join a local node on given port
join_local(Port) ->
    hypar_node:join_cluster({{127,0,0,1},Port}).
