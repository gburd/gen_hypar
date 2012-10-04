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
%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @title HyParView API
%% @doc Interface module to the HyParView peer samling service
%% -------------------------------------------------------------------
-module(hyparerl).

-include("hyparerl.hrl").

%% Operations
-export([start/0, start/1, join_cluster/1]).

%% Views
-export([get_peers/0, get_passive_peers/0]).

%% Send
-export([send/2]).

%% Auxillary
-export([get_id/0, encode_id/1, decode_id/1]).

%% Type
-export_type([id/0]).

%%%===================================================================
%%% Operations
%%%===================================================================

%% @doc Start the hyparerl application
start() ->
    lager:start(),
    application:start(ranch),
    timer:sleep(100),
    application:start(hyparerl).

%% @doc Start the hyparerl application with <em>Options</em>.
start(Options) ->
    application:load(hyparerl),
    lists:foreach(fun({Par, Val}) ->
                          application:set_env(hyparerl, Par, Val)
                  end, Options),
    start().

%% @doc Join a cluster via <em>ContactNodes</em> in order.
join_cluster(ContactNodes) ->
    hypar_node:join_cluster(ContactNodes).

%%%===================================================================
%%% Views
%%%===================================================================

%% @doc Retrive all current active peers
get_peers() ->
    hypar_node:get_peers().

%% @doc Retrive all current passive peers
get_passive_peers() ->
    hypar_node:get_passive_peers().

%%%===================================================================
%%% Send
%%%===================================================================

%% @doc Send an iolist or binary <em>Message</em> over connection <em>Conn</em>.
send(Peer, Message) ->
    connect:send(Peer#peer.conn, Message).

%%%===================================================================
%%% Auxillary
%%%===================================================================

%% @doc Retrive the identifier of the hypar node. Useful if the node was started
%%      without a given one.
get_id() ->
    hypar_node:get_id().

%% @doc Encode an identifier <em>Id</em> into a binary.
encode_id(Id) ->
    connect:encode_id(Id).

%% @doc Decode a binary <em>BId</em> into an identifier.
decode_id(BId) ->
    connect:decode_id(BId).
