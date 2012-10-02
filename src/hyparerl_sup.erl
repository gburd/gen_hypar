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
%% @private
%% @title Top level supervisor
%% @doc Top level supervisor for hyparerl
%% -------------------------------------------------------------------

-module(hyparerl_sup).

-author('Emil Falk <emil.falk.1988@gmail.com>').

-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(Options) ->
    supervisor:start_link(?MODULE, [Options]).

init([Options]) ->
    HyparNode = {hypar_node,
                 {hypar_node, start_link, [Options]},
                 permanent, 5000, worker, [hypar_node]},
    ConnectSup = {connect_sup,
                  {connect_sup, start_link, [Options]},
                  permanent, 5000, supervisor, [connect_sup]},
    {ok, { {one_for_all, 5, 10}, [HyparNode, ConnectSup]}}.
