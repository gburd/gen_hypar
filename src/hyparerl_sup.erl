%% -------------------------------------------------------------------
%%
%% Top-level supervisor for hyparerl
%%
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
-module(hyparerl_sup).

-author('Emil Falk <emil.falk.1988@gmail.com>').

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Options) ->
    supervisor:start_link(?MODULE, [Options]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Options0]) ->
    Name = proplists:get_value(name, Options0),
    ConnectName = list_to_atom(atom_to_list(Name) ++ "_connect"),
    Options = [{connect_sup, ConnectName}|Options0],
    HyparNode = {hypar_node,
                 {hypar_node, start_link, [Name, Options]},
                 permanent, 5000, worker, [hypar_node]},
    ConnectSup = {connect_sup,
                  {connect_sup, start_link, [ConnectName, Options]},
                  permanent, 5000, supervisor, [connect_sup]},
    {ok, { {one_for_all, 5, 10}, [HyparNode, ConnectSup]}}.
