%% -------------------------------------------------------------------
%%
%% Supervisor for the connection handlers in hyparerl
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

%% @doc Supervisor for the connection handlers, support to start new connections
%%      and accept incoming tcp-connections

-module(connect_sup).

-author('Emil Falk <emil.falk.1988@gmail.com>').

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-include("hyparerl.hrl").

%%===================================================================
%% API functions
%%===================================================================

start_link(Recipient) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Recipient]).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

init([Recipient]) ->
    ConnectionWorkers = {connect,
                         {connect, start_link, [Recipient]},
                         temporary, brutal_kill, worker, [connect]},

    {ok, {{simple_one_for_one, 5, 10}, [ConnectionWorkers]}}.
