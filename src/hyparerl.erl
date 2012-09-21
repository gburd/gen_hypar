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
-export([send/2, multi_send/2]).

start() ->
    lager:start(),
    application:start(ranch),
    application:start(hyparerl).

test_start(Port) ->

    lager:start(),
    application:start(ranch),
    
    timer:sleep(1000),

    lager:set_loglevel(lager_console_backend, debug),

    application:load(hyparerl),
    application:set_env(hyparerl, id, {{127,0,0,1}, Port}),
    application:start(hyparerl).

join_cluster(ContactNode) ->
    hypar_node:join_cluster(ContactNode).

shuffle() ->
    hypar_node:shuffle().

get_peers() ->
    hypar_node:get_peers().

get_passive_peers() ->
    hypar_node:get_passive_peers().

send(Peer, Bin) ->
    hypar_node:send(Peer, Bin).

multi_send(Peers, Bin) ->
    hypar_node:multi_send(Peers, Bin).
