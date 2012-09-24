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
-export([start/0, test_start/1, join_cluster/1, shuffle/0]).

%% View
-export([get_peers/0, get_passive_peers/0]).

%% Send
-export([send/2]).

%% @doc Start the hyparerl application
start() ->
    lager:start(),
    application:start(ranch),
    application:start(hyparerl).

%% @doc Start a test-server with local ip and given port
test_start(Port) ->

    lager:start(),
    application:start(ranch),
    
    timer:sleep(1000),

    lager:set_loglevel(lager_console_backend, debug),

    application:load(hyparerl),
    application:set_env(hyparerl, id, {{127,0,0,1}, Port}),
    application:start(hyparerl).

%% @doc Join a cluster via <em>ContactNode</em>.
join_cluster(ContactNode) ->
    hypar_node:join_cluster(ContactNode).

%% @doc Initate a shuffle request
shuffle() ->
    hypar_node:shuffle().

%% @doc Retrive all current active peers
get_peers() ->
    hypar_node:get_peers().

%% @doc Retrive all current passive peers
get_passive_peers() ->
    hypar_node:get_passive_peers().

%% @doc Send a binary message to <em>Peer</em>
send(Peer, Bin) ->
    connect:send(Peer, Bin).
