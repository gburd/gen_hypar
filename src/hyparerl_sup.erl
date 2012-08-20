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

-include("hyparerl.hrl").

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Options) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Options]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Options]) ->
    ThisNode = proplists:get_value(id, Options),
    Recipient = proplists:get_value(recipient, Options),

    Node = {hypar_node,
            {hypar_node, start_link, [Options]},
            permanent, 5000, worker, [hypar_man]},
    ConnectionSup = {connect_sup,
                     {connect_sup, start_link, [Recipient, ThisNode]},
                     permanent, 5000, supervisor, [connect_sup]},
    {ok, { {one_for_one, 5, 10}, [Node, ConnectionSup]} }.
