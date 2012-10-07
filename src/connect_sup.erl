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
%% @title Connection supervisor
%% @doc Keeps track of open connections that this node initiated
%% -------------------------------------------------------------------
-module(connect_sup).

-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(Options) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Options).

init(Options) ->
    Connect = {connect, {connect, start_link, [opts:connect_opts(Options)]},
               temporary, brutal_kill, worker, [connect]},
    
    {ok, {{simple_one_for_one, 1000, 3600}, [Connect]}}.
