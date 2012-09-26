%% -------------------------------------------------------------------
%%
%% Application behaivor for the hyparerl application
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

-module(hyparerl_app).

-author('Emil Falk <emil.falk.1988@gmail.com>').

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    application:load(hyparerl),
    Options0 = application:get_all_env(hyparerl),

    %% Ensure that all nessecary parameters are defined, default those who
    %% are not defined.
    Options = lists:foldl(fun({Opt, _}=OptPair, Acc0) ->
                                  case proplists:is_defined(Opt, Acc0)  of
                                      true -> Acc0;
                                      false -> [OptPair|Acc0]
                                  end
                          end, Options0, default_options()),
    connect:initialize(Options),
    hyparerl_sup:start_link(Options).

stop(_State) ->
    ok.

%% @doc Default options for the hyparview-application
default_options() ->
    [{id, {{127,0,0,1}, 6000}},
     {active_size, 5},
     {passive_size, 30},
     {arwl, 6},
     {prwl, 3},
     {k_active, 3},
     {k_passive, 4},
     {shuffle_period, 10000},
     {shuffle_buffer, 5},
     {timeout, 1000},
     {send_timeout, 1000},
     {notify, none},
     {receiver, none}].
