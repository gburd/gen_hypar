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
-export([start/0, join_cluster/1, shuffle/0]).

%% Notifications
-export([notify_me/0, stop_notifying/0]).

%% Receiving
-export([receiver/0, stop_receiving/0]).

%% Testing
-export([test_start/1, test_join/1]).

%% View
-export([get_peers/0, get_passive_peers/0]).

%% Send
-export([send/2]).

%% Identifier
-export([encode_id/1, decode_id/1]).

%%%%%%%%%
%% API %%
%%%%%%%%%

%%%%%%%%%%%%%%%%
%% Operations %%
%%%%%%%%%%%%%%%%

%% @doc Start the hyparerl application
start() ->
    lager:start(),
    application:start(ranch),
    timer:sleep(100),
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

%%%%%%%%%%%%%%%%%%
%% Notification %%
%%%%%%%%%%%%%%%%%%

%% @doc Add calling process to the notify list, return current active view.
notify_me() ->
    hypar_node:notify_me().

%% @doc Remove calling process from the notify list
stop_notifying() ->
    hypar_node:stop_notifying().

%%%%%%%%%%%%%
%% Sending %%
%%%%%%%%%%%%%

%% @doc Send a binary message <em>Bin</em> over connection <em>Conn</em>.
send(Conn, Bin) ->
    connect:send(Conn, Bin).

%%%%%%%%%%%%%%%
%% Receiving %%
%%%%%%%%%%%%%%%

%% @doc Add calling process to the receivers list
receiver() ->
    hypar_node:receiver().

%% @doc Remove calling process from the receivers list
stop_receiving() ->
    hypar_node:stop_receiving().

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

%% @doc Start a test-server with local ip and given port
test_start(Port) ->
    lager:start(),
    application:start(ranch),    
    timer:sleep(1000),
    lager:set_loglevel(lager_console_backend, debug),
    application:load(hyparerl),
    application:set_env(hyparerl, id, {{127,0,0,1}, Port}),
    
    application:start(hyparerl).

%% @doc Join a local node on given port
test_join(Port) ->
    hypar_node:join_cluster({{127,0,0,1},Port}).
