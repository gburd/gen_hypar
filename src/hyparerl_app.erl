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
%% @title Hyparerl application file
%% @doc Application behaivor for the hyparerl application
%% -------------------------------------------------------------------
-module(hyparerl_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    Opts = application:get_all_env(hyparerl),
    case sanity(Opts) of
        true ->
            hyparerl_sup:start_link(default_undefined(Opts));
        false ->
            throw({error, insane_options})
    end.

stop(_State) ->
    ok.

%% @doc Check so all neccessary options are defined, otherwise default them.
default_undefined(Options) ->
    lists:foldl(fun({Opt, _}=OptPair, Acc0) ->
                        case proplists:is_defined(Opt, Acc0)  of
                            true -> Acc0;
                            false -> [OptPair|Acc0]
                        end
                end, Options, default_options()).

%% @doc Check the santify of the options
%% @todo Maybe also check that some values are in range?
sanity(Options) ->
    Needed = [id, mod], %% The rest can be defaulted
    lists:all(fun(B) -> B end,
              [lists:keymember(Opt, 1, Options) || Opt <- Needed]).
        
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
