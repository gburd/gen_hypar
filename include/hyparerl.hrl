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
%%% @author Emil Falk <emil.falk.1988@gmail.com>
%%% @copyright (C) 2012, Emil Falk
%%% @title Include file
%%% @doc Defines records & types used in hyparerl
%%%-------------------------------------------------------------------

%% @doc An <em>identifier</em> is a tuple of an IP address and port number
-type id() :: {inet:ip_address(),
               inet:port_number()}.

%% @doc Type for shuffle history entries
-type shuffle_ent() :: {reference(), list(id()), erlang:timestamp()}.

%% @doc Represent the priority of a neighbour request
-type priority() :: high | low.

%% @doc Type for change in the view
-type view_change() :: {no_disconnect | id(), no_drop | id()}.

%% @doc A view is just a list of identifiers
-type view() :: list(id()).

%% @doc A <em>peer</em> consists of an identifier and a corresponding pid
-record(peer, {id  :: id(),
               pid :: pid()
              }).
