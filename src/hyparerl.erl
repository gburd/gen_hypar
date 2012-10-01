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
-export([start/0, join_cluster/1, start_cluster/4, start_cluster/5, stop_cluster/1]).

%% View
-export([get_peers/1, get_passive_peers/1]).

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

%% @doc Start the hyparerl application.
start() ->
    lager:start(),
    application:start(ranch),
    timer:sleep(100),
    application:start(hyparerl).

%% @doc Start an unconnected cluster node with name <em>Name</em>, with callback module
%%      <em>Mod</em> and 
start_cluster(Name, Identifier, Mod, Options) ->
    Opts = [{name, Name}, {id, Identifier}, {target, Mod}
            |options_defined(Options)],
    supervisor:start_child(hyparerl_top_sup, child_spec(Name, Opts)).

%% @doc Start a cluster and try to connect to the contact nodes
start_cluster(Name, Identifier, Mod, Options, ContactNodes) ->
    Opts = [{name, Name}, {id, Identifier}, {target, Mod},
            {contact_nodes, ContactNodes}|options_defined(Options)],
    supervisor:start_child(hyparerl_top_sup, child_spec(Name, Opts)).

%% @doc Stop a cluster <em>Name</em>.
stop_cluster(Name) ->
    supervisor:terminate_child(hyparerl_top_sup, {cluster, Name}),
    ranch:stop_listener(Name).

%% @doc Join a cluster via <em>ContactNodes</em> in order.
join_cluster(ContactNodes) ->
    hypar_node:join_cluster(ContactNodes).

%%%%%%%%%%
%% View %%
%%%%%%%%%%

%% @doc Retrive all current active peers
get_peers(Cluster) ->
    hypar_node:get_peers(Cluster).

%% @doc Retrive all current passive peers
get_passive_peers(Cluster) ->
    hypar_node:get_passive_peers(Cluster).

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

%%%%%%%%%%%%%%%%%%%%%%
%% Cluster-creation %%
%%%%%%%%%%%%%%%%%%%%%%

%% @doc Check so all neccessary options are defined, otherwise default them.
options_defined(Options) ->    
    lists:foldl(fun({Opt, _}=OptPair, Acc0) ->
                        case proplists:is_defined(Opt, Acc0)  of
                            true -> Acc0;
                            false -> [OptPair|Acc0]
                        end
                end, Options, default_options()).

%% @doc Child specification
child_spec(Name, Options) ->
    {Name, {hyparerl_sup, start_link, [Options]}, permanent, 10000,
     supervisor, [hyparerl_sup]}.
    
%% @doc Default options for the hyparview-application
default_options() ->
    [{active_size, 5},
     {passive_size, 30},
     {arwl, 6},
     {prwl, 3},
     {k_active, 3},
     {k_passive, 4},
     {shuffle_period, 10000},
     {timeout, 10000},
     {send_timeout, 1000}].
